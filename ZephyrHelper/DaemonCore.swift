// DaemonCore.swift — the daemon's brain: config state, 2 s safety tick, write sequencing, status.

import Foundation
import os
import ZephyrKit

/// Owns everything the daemon does between XPC calls: the enforced config,
/// the write sequencer, the SafetyMonitor, and the 2-second tick that keeps
/// the safety invariants true no matter what the app does (or fails to do).
actor DaemonCore {
    private let port: SMCWritePort
    private let sequencer: FanWriteSequencer
    private var monitor = SafetyMonitor()
    private let log = Logger(subsystem: "io.github.thijsvos.zephyr", category: "curve")

    /// What the daemon is currently enforcing. Fresh start = `.auto`
    /// (PLAN.md §4.3: config persistence arrives in Phase 4).
    private var config: FanConfig = .auto
    private var lastHeartbeat: Date?
    private var status = HelperStatus()
    private var tickTask: Task<Void, Never>?
    /// Clock of the previous tick — a large jump means the machine slept.
    private var lastTickAt: Date?
    /// Read-back mismatches since the last good verification.
    private var verifyFailures = 0
    /// Resolved sensor keys for safety monitoring (curated ∩ present).
    private var sensorKeys: [String]?
    /// True while the SafetyMonitor is forcing maximum cooling.
    private var coolingOverride = false

    init() throws {
        port = try SMCWritePort()
        sequencer = FanWriteSequencer(port: port)
    }

    // MARK: - Lifecycle

    /// SAFETY (§4.3): the daemon starts by reverting everything to auto —
    /// whatever a crash or power loss left behind is wiped clean — then runs
    /// the tick forever.
    func start() async {
        await revertEverything(reason: "daemon start")
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(HelperConstants.tickInterval))
            }
        }
        log
            .notice(
                "ZephyrHelper started (protocol v\(HelperConstants.protocolVersion, privacy: .public)); all fans auto"
            )
    }

    /// SIGTERM / shutdown: leave the hardware in macOS's hands.
    func shutdown() async {
        tickTask?.cancel()
        await revertEverything(reason: "daemon shutdown")
    }

    /// XPC connection dropped. Manual mode reverts immediately (faster than
    /// waiting out the watchdog); persistent curve mode would keep running.
    func connectionInvalidated() async {
        if config.mode == .manual || (config.mode == .curve && !config.persistsWithoutApp) {
            await revertEverything(reason: "app connection invalidated")
        }
    }

    // MARK: - XPC entry points

    func heartbeat() {
        lastHeartbeat = Date()
    }

    func apply(_ newConfig: FanConfig) async throws {
        switch newConfig.mode {
        case .auto:
            await revertEverything(reason: "app requested auto")
        case .manual:
            let fans = try await readFans()
            let outcome = try await sequencer.engageManual(targets: newConfig.manualTargets, fans: fans)
            config = newConfig
            config.manualTargets = outcome.clampedTargets
            verifyFailures = 0
            coolingOverride = false
            status.mode = .manual
            status.appliedTargets = outcome.clampedTargets
            status.unlockBranch = outcome.branch.rawValue
            status.lastWriteVerified = outcome.verified
            record(
                "manual engaged (\(outcome.branch.rawValue) branch, verified: \(outcome.verified)) targets \(outcome.clampedTargets)"
            )
        case .curve:
            throw ZephyrError.smcFirmwareRejected(key: "curve", result: 0) // Phase 4
        }
    }

    func setAllAuto() async {
        await revertEverything(reason: "app requested revert")
    }

    func currentStatus() -> HelperStatus {
        status
    }

    // MARK: - The safety tick

    private func tick() async {
        let now = Date()
        // Wake detection: a gap ≫ tick interval means the machine slept and
        // firmware silently reset manual control (§3.4) — re-assert or revert.
        if let last = lastTickAt, now.timeIntervalSince(last) > HelperConstants.tickInterval * 5 {
            await handleWake()
        }
        lastTickAt = now

        let temps = try? await readTemperatures()
        let verdict = monitor.evaluate(
            now: now, lastHeartbeat: lastHeartbeat, config: config, temperatures: temps
        )
        switch verdict {
        case .ok:
            coolingOverride = false
            if config.mode == .manual {
                await verifyManualState()
            } else {
                await autoSafetyNet()
            }
        case let .forceMaxCooling(offender):
            if !coolingOverride {
                record("SAFETY: forcing maximum cooling — \(offender)")
            }
            coolingOverride = true
            await forceMaximumCooling()
        case let .revertToAuto(reason):
            record("SAFETY: reverting to auto — \(reason)")
            await revertEverything(reason: reason)
        }
    }

    /// Read-back + re-assert: firmware or thermalmonitord can silently take
    /// control back. One re-apply is attempted; a second consecutive failure
    /// means we are not actually in control → revert and say so.
    private func verifyManualState() async {
        guard let fans = try? await readFans() else { return }
        let held = fans.allSatisfy { fan in
            guard let target = config.manualTargets[fan.id] else { return true }
            return fan.mode == .forced && abs(fan.targetRPM - target) <= 1
        }
        if held {
            verifyFailures = 0
            status.lastWriteVerified = true
            return
        }
        verifyFailures += 1
        status.lastWriteVerified = false
        if verifyFailures == 1 {
            record("read-back mismatch — re-asserting manual state")
            _ = try? await sequencer.engageManual(targets: config.manualTargets, fans: fans)
        } else {
            record("SAFETY: control lost (read-back failed twice) — reverting to auto")
            await revertEverything(reason: "read-back verification failed")
        }
    }

    private func forceMaximumCooling() async {
        guard let fans = try? await readFans() else { return }
        let maxTargets = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.maxRPM) })
        _ = try? await sequencer.engageManual(targets: maxTargets, fans: fans)
    }

    private func handleWake() async {
        switch config.mode {
        case .manual:
            record("wake detected — re-asserting manual state")
            if let fans = try? await readFans(),
               await (try? sequencer.engageManual(targets: config.manualTargets, fans: fans)) != nil
            {
                return
            }
            record("SAFETY: wake re-assert failed — reverting to auto")
            await revertEverything(reason: "wake re-assert failed")
        case .auto, .curve:
            break // nothing held across sleep in Phase 3
        }
    }

    private func revertEverything(reason: String) async {
        let fans = await (try? readFans()) ?? []
        try? await sequencer.revertAllAuto(fans: fans)
        // Release the SMC connection: thermalmonitord reliably resumes fan
        // control only once the writer's connection is gone (field-observed).
        await port.reset()
        config = .auto
        coolingOverride = false
        verifyFailures = 0
        status.mode = .auto
        status.appliedTargets = [:]
        record("all fans auto (\(reason))")
    }

    // MARK: - Auto-mode safety net

    /// Consecutive ticks with a cool orphaned fan (gentle ladder debounce).
    private var deadFanTicks = 0
    /// Escalation stage of the gentle ladder.
    private var recoveryStage = 0
    /// Consecutive ticks of hot-and-stopped (emergency debounce).
    private var deadHotTicks = 0
    /// True while the daemon has seized the fans because macOS was not cooling.
    private var emergencyCooling = false
    /// Stopped fans at/above this die temperature = nobody is cooling.
    private static let emergencyDieCelsius = 92.0
    /// Emergency ends (hand-back retried) below this die temperature.
    private static let emergencyReleaseCelsius = 80.0

    /// FIELD CORRECTION (2026-07-23, hardened the same day after the die
    /// reached ~100 °C with stopped fans and macOS never intervened):
    /// defense in depth for "fans stopped when they must not be".
    /// - EMERGENCY: die ≥ 92 °C with stopped fans (any mode we don't hold) →
    ///   after 2 confirming ticks (~4 s) the daemon seizes the fans at a
    ///   heat-scaled speed (92 °C → ~60 %, 97 °C+ → maximum) and keeps
    ///   cooling until the die is back under 80 °C, then hands back — and
    ///   re-triggers if macOS drops the ball again.
    /// - Cool orphan (mode 0, stopped, any temperature): the gentle ladder —
    ///   re-park at minimum + hand back + connection reset, then hold the
    ///   floor ourselves.
    private func autoSafetyNet() async {
        guard let fans = try? await readFans() else { return }
        let dieHot = await (try? readTemperatures())?
            .filter { r in ["Tp", "Tg", "Te", "Tf", "Tc"].contains(where: r.key.hasPrefix) }
            .map(\.celsius).max() ?? 0

        // Maintain or end an active emergency takeover.
        if emergencyCooling {
            if dieHot < Self.emergencyReleaseCelsius {
                emergencyCooling = false
                record("SAFETY: emergency cooling done (die \(Int(dieHot)) °C) — handing fans back to the system")
                try? await sequencer.revertAllAuto(fans: fans)
                await port.reset()
            } else {
                _ = try? await sequencer.engageManual(
                    targets: emergencyTargets(for: fans, dieHot: dieHot), fans: fans
                )
            }
            return
        }

        let stopped = fans.filter { $0.actualRPM < 100 && $0.minRPM > 0 && $0.mode != .forced }

        // EMERGENCY: hot machine, nothing spinning, nobody cooling.
        if !stopped.isEmpty, dieHot >= Self.emergencyDieCelsius {
            deadHotTicks += 1
            if deadHotTicks >= 2 {
                deadHotTicks = 0
                emergencyCooling = true
                record("SAFETY: EMERGENCY — die \(Int(dieHot)) °C with fans stopped; daemon is taking over cooling")
                _ = try? await sequencer.engageManual(
                    targets: emergencyTargets(for: fans, dieHot: dieHot), fans: fans
                )
            }
            return
        }
        deadHotTicks = 0

        // Cool orphan: mode 0 with stopped fans — always wrong, never urgent.
        let orphaned = stopped.filter { $0.mode == .auto }
        guard !orphaned.isEmpty else {
            deadFanTicks = 0
            recoveryStage = 0
            return
        }
        deadFanTicks += 1
        guard deadFanTicks >= 3 else { return }
        deadFanTicks = 0
        recoveryStage += 1
        if recoveryStage == 1 {
            record("SAFETY: fan(s) orphaned in mode 0 — re-parking, handing back, resetting SMC connection")
            for fan in orphaned {
                try? await port.writeDouble("F\(fan.id)Tg", value: fan.minRPM, as: .float)
                for suffix in ["Md", "md"] where await port.hasKey("F\(fan.id)\(suffix)") {
                    try? await port.writeDouble("F\(fan.id)\(suffix)", value: 3, as: .uint8)
                    break
                }
            }
            await port.reset()
        } else {
            record("SAFETY: system did not resume control — holding fans at minimum RPM ourselves")
            let floors = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.minRPM) })
            _ = try? await sequencer.engageManual(targets: floors, fans: fans)
        }
    }

    /// Heat-scaled emergency speed: ~60 % of each fan's range at 92 °C,
    /// maximum from 97 °C up. Monotone in temperature, never below minimum.
    private func emergencyTargets(for fans: [Fan], dieHot: Double) -> [Int: Double] {
        let fraction = min(1.0, max(0.5, (dieHot - 85.0) / 12.0))
        return Dictionary(uniqueKeysWithValues: fans.map { fan in
            (fan.id, fan.minRPM + fraction * (fan.maxRPM - fan.minRPM))
        })
    }

    // MARK: - Hardware reads (the daemon trusts only its own readings)

    private func readFans() async throws -> [Fan] {
        let count = try await Int(port.readDouble("FNum"))
        var fans: [Fan] = []
        for i in 0 ..< count {
            let mode: FanMode = if let raw = try? await port.readDouble("F\(i)Md") {
                FanMode(rawValue: UInt8(raw)) ?? .system
            } else if let raw = try? await port.readDouble("F\(i)md") {
                FanMode(rawValue: UInt8(raw)) ?? .system
            } else {
                .system
            }
            await fans.append(Fan(
                id: i,
                name: "Fan \(i)",
                mode: mode,
                actualRPM: (try? port.readDouble("F\(i)Ac")) ?? 0,
                targetRPM: (try? port.readDouble("F\(i)Tg")) ?? 0,
                minRPM: (try? port.readDouble("F\(i)Mn")) ?? 0,
                maxRPM: (try? port.readDouble("F\(i)Mx")) ?? 0
            ))
        }
        return fans
    }

    private func readTemperatures() async throws -> [SensorReading] {
        if sensorKeys == nil {
            let curated = SMCKeyMaps.curatedSensors(forModel: HostInfo.modelIdentifier()) ?? []
            var present: [String] = []
            for sensor in curated where await port.hasKey(sensor.key) {
                present.append(sensor.key)
            }
            sensorKeys = present
        }
        var readings: [SensorReading] = []
        for key in sensorKeys ?? [] {
            if let value = try? await port.readDouble(key), SMCKeyMaps.isPlausibleTemperature(value) {
                readings.append(SensorReading(key: key, label: key, celsius: value))
            }
        }
        guard !readings.isEmpty else {
            throw ZephyrError.smcKeyNotFound(key: "T***")
        }
        return readings
    }

    /// Logs and appends to the bounded status event list.
    private func record(_ event: String) {
        log.notice("\(event, privacy: .public)")
        status.recentEvents.append(event)
        if status.recentEvents.count > 20 {
            status.recentEvents.removeFirst(status.recentEvents.count - 20)
        }
    }
}
