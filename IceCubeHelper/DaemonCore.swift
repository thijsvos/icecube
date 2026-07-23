// DaemonCore.swift — the daemon's brain: config state, 2 s safety tick, write sequencing, status.

import Foundation
import IceCubeKit
import os

/// Owns everything the daemon does between XPC calls: the enforced config,
/// the write sequencer, the SafetyMonitor, and the 2-second tick that keeps
/// the safety invariants true no matter what the app does (or fails to do).
actor DaemonCore {
    private let port: SMCWritePort
    private let sequencer: FanWriteSequencer
    private var monitor = SafetyMonitor()
    private let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "curve")

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
        if let persisted = ConfigStore.load() {
            // The Phase 4 boot promise: a persisted curve is live before the
            // app ever launches. Anything else starts from clean auto.
            config = persisted
            status.mode = .curve
            record("boot: resuming persisted curve config")
            await runCurveTick()
        } else {
            await revertEverything(reason: "daemon start")
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(HelperConstants.tickInterval))
            }
        }
        log
            .notice(
                "IceCubeHelper started (protocol v\(HelperConstants.protocolVersion, privacy: .public)); all fans auto"
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
            guard newConfig.isUsableCurveConfig else {
                throw IceCubeError.smcDecodingFailed(key: "sharedCurve", type: "FanCurve", bytes: [])
            }
            config = newConfig
            followers = [:]
            curveTargets = [:]
            verifyFailures = 0
            coolingOverride = false
            guardianActive = false
            guardianTargets = [:]
            status.mode = .curve
            ConfigStore.save(newConfig) // persists only when the rules allow
            await runCurveTick()
            record("curve engaged (persists without app: \(newConfig.persistsWithoutApp))")
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
            switch config.mode {
            case .manual: await verifyManualState()
            case .curve: await runCurveTick()
            case .auto: await autoSafetyNet()
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
        case .curve:
            record("wake detected — re-asserting curve control")
            curveTargets = [:] // force a fresh engage on the next curve tick
            await runCurveTick()
        case .auto:
            break
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
        followers = [:]
        curveTargets = [:]
        ConfigStore.clear() // a revert always cancels the boot promise
        status.mode = .auto
        status.appliedTargets = [:]
        record("all fans auto (\(reason))")
    }

    // MARK: - Curve control loop (Phase 4)

    /// Per-fan follower state (hysteresis + ramp), reset on config changes.
    private var followers: [Int: CurveFollower] = [:]
    /// The targets currently commanded by the curve (quantized to 50 RPM).
    private var curveTargets: [Int: Double] = [:]

    /// One curve tick: hottest die temp → per-fan follower → quantized
    /// targets → write when changed, read-back-verify when not.
    private func runCurveTick() async {
        guard let fans = try? await readFans(), !fans.isEmpty else { return }
        // Sensor blindness is handled by the SafetyMonitor (revert after 3
        // failed ticks) — a single missing reading just skips this tick.
        guard let dieHot = await (try? readTemperatures())?
            .filter({ r in ["Tp", "Tg", "Te", "Tf", "Tc"].contains(where: r.key.hasPrefix) })
            .map(\.celsius).max() else { return }

        var targets: [Int: Double] = [:]
        for fan in fans {
            guard let curve = config.curve(for: fan.id) else { continue }
            var follower = followers[fan.id] ?? CurveFollower(
                hysteresisCelsius: config.hysteresisCelsius, rampPerTick: config.rampPerTick
            )
            let fraction = follower.step(dieCelsius: dieHot, curve: curve)
            followers[fan.id] = follower
            let raw = fan.minRPM + fraction * (fan.maxRPM - fan.minRPM)
            targets[fan.id] = (raw / 50).rounded() * 50
        }
        guard !targets.isEmpty else { return }

        if targets != curveTargets {
            curveTargets = targets
            if let outcome = try? await sequencer.engageManual(targets: targets, fans: fans) {
                status.appliedTargets = outcome.clampedTargets
                status.unlockBranch = outcome.branch.rawValue
                status.lastWriteVerified = outcome.verified
            }
        } else {
            await verifyCurveHeld(expected: targets, fans: fans)
        }
    }

    /// Same read-back discipline as manual mode: one re-assert, then revert.
    private func verifyCurveHeld(expected: [Int: Double], fans: [Fan]) async {
        let held = fans.allSatisfy { fan in
            guard let target = expected[fan.id] else { return true }
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
            record("curve read-back mismatch — re-asserting")
            _ = try? await sequencer.engageManual(targets: expected, fans: fans)
        } else {
            record("SAFETY: curve control lost (read-back failed twice) — reverting to auto")
            await revertEverything(reason: "curve read-back verification failed")
        }
    }

    // MARK: - Guardian: Ice Cube cools when macOS won't

    /// Consecutive ticks with a cool orphaned fan (gentle ladder debounce).
    private var deadFanTicks = 0
    /// Escalation stage of the gentle ladder.
    private var recoveryStage = 0
    /// Consecutive ticks of warm-and-nobody-cooling (guardian debounce).
    private var guardianTicks = 0
    /// True while the guardian curve is driving the fans.
    private var guardianActive = false
    /// Last targets the guardian wrote (quantized), to avoid write churn.
    private var guardianTargets: [Int: Double] = [:]
    /// Guardian considers engaging at this die temperature…
    private static let guardianEngageCelsius = 75.0
    /// …and releases below this one (wide hysteresis, no flapping).
    private static let guardianReleaseCelsius = 65.0

    /// FIELD FINDING (2026-07-23, Mac14,9 / macOS 26.4.1): after any fan app
    /// touches the SMC, macOS's own fan management does NOT reliably resume —
    /// we observed die temperatures climbing through 78…92 °C with the fans
    /// parked and macOS never intervening, mode 3 notwithstanding. "Hand back
    /// and hope" is therefore not a safety strategy. The guardian: whenever
    /// the config is auto and the machine is warm while nothing spins, the
    /// daemon drives the fans itself along a built-in curve (gentle at 70 °C,
    /// maximum by 95 °C) and releases once the die is truly cool. This is the
    /// seed of Phase 4's control loop, pulled forward for safety.
    private func autoSafetyNet() async {
        guard let fans = try? await readFans() else { return }
        let dieHot = await (try? readTemperatures())?
            .filter { r in ["Tp", "Tg", "Te", "Tf", "Tc"].contains(where: r.key.hasPrefix) }
            .map(\.celsius).max() ?? 0

        if guardianActive {
            if dieHot < Self.guardianReleaseCelsius {
                guardianActive = false
                guardianTargets = [:]
                record("guardian: cooled to \(Int(dieHot)) °C — releasing the fans")
                try? await sequencer.revertAllAuto(fans: fans)
                await port.reset()
            } else {
                let targets = Self.guardianCurveTargets(for: fans, dieHot: dieHot)
                if targets != guardianTargets {
                    guardianTargets = targets
                    _ = try? await sequencer.engageManual(targets: targets, fans: fans)
                }
            }
            return
        }

        // Engage when warm and nothing is effectively cooling.
        let demand = Self.guardianCurveTargets(for: fans, dieHot: dieHot)
        let nobodyCooling = fans.contains { fan in
            fan.mode != .forced && fan.actualRPM + 400 < (demand[fan.id] ?? 0)
        }
        if dieHot >= Self.guardianEngageCelsius, nobodyCooling {
            guardianTicks += 1
            if guardianTicks >= 2 {
                guardianTicks = 0
                guardianActive = true
                guardianTargets = demand
                record("guardian: die \(Int(dieHot)) °C and nothing cooling — driving the fans (built-in curve)")
                _ = try? await sequencer.engageManual(targets: demand, fans: fans)
            }
            return
        }
        guardianTicks = 0

        // Cool orphan: mode 0 with stopped fans — always wrong, never urgent.
        let orphaned = fans.filter { $0.actualRPM < 100 && $0.minRPM > 0 && $0.mode == .auto }
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

    /// The built-in guardian curve: 0 below 70 °C, then 20 %…100 % of each
    /// fan's range linearly from 70 to 95 °C. Quantized to 100 RPM steps so
    /// small temperature wiggles don't cause write churn.
    static func guardianCurveTargets(for fans: [Fan], dieHot: Double) -> [Int: Double] {
        let fraction: Double = if dieHot <= 70 {
            0
        } else {
            min(1.0, 0.2 + 0.8 * (dieHot - 70.0) / 25.0)
        }
        return Dictionary(uniqueKeysWithValues: fans.map { fan in
            let raw = fan.minRPM + fraction * (fan.maxRPM - fan.minRPM)
            return (fan.id, (raw / 100).rounded() * 100)
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
            throw IceCubeError.smcKeyNotFound(key: "T***")
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
