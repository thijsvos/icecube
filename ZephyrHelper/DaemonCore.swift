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

    /// Consecutive ticks with a wrongly-stopped fan.
    private var deadFanTicks = 0
    /// Escalation stage: 0 = none, 1 = hand-back retried, 2 = holding floor.
    private var recoveryStage = 0
    /// Die temps at or above this with stopped fans = nobody is cooling.
    private static let deadFanDieCeiling = 92.0

    /// FIELD CORRECTION (2026-07-23): defense in depth for "fans stopped when
    /// they must not be". Two wrong states, learned on Mac14,9:
    /// - mode 0 ("auto") with fans stopped: nobody is driving — always wrong
    ///   on a fan with a non-zero minimum.
    /// - mode 3 ("system") with fans stopped is NORMAL while cool (14" MBPs
    ///   run fanless at idle) but wrong once die temps reach ~92 °C — the
    ///   system should be cooling by then; if it isn't, it never got control
    ///   back properly.
    /// Escalation after 3 confirming ticks: (1) re-park targets, re-hand-back,
    /// reset the SMC connection; (2) hold the fans at their minimum ourselves
    /// — spinning at the floor beats silence, and the 104 °C ceiling override
    /// still escalates to maximum above that.
    private func autoSafetyNet() async {
        guard let fans = try? await readFans() else { return }
        let dieHot = await (try? readTemperatures())?
            .filter { r in ["Tp", "Tg", "Te", "Tf", "Tc"].contains(where: r.key.hasPrefix) }
            .map(\.celsius).max() ?? 0
        let dead = fans.filter { fan in
            guard fan.actualRPM < 100, fan.minRPM > 0 else { return false }
            return fan.mode == .auto || (fan.mode == .system && dieHot >= Self.deadFanDieCeiling)
        }
        guard !dead.isEmpty else {
            deadFanTicks = 0
            recoveryStage = 0
            return
        }
        deadFanTicks += 1
        guard deadFanTicks >= 3 else { return }
        deadFanTicks = 0
        recoveryStage += 1
        if recoveryStage == 1 {
            record(
                "SAFETY: fan(s) wrongly stopped (die \(Int(dieHot)) °C) — re-parking, handing back, resetting SMC connection"
            )
            for fan in dead {
                try? await port.writeDouble("F\(fan.id)Tg", value: fan.minRPM, as: .float)
                for suffix in ["Md", "md"] where await port.hasKey("F\(fan.id)\(suffix)") {
                    try? await port.writeDouble("F\(fan.id)\(suffix)", value: 3, as: .uint8)
                    break
                }
            }
            await port.reset()
        } else {
            record("SAFETY: system did not resume cooling — holding fans at minimum RPM ourselves")
            let floors = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.minRPM) })
            _ = try? await sequencer.engageManual(targets: floors, fans: fans)
        }
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
