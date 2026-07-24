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
    /// Bumped by every revert. See ``engage(targets:fans:since:)``.
    private var revertGeneration = 0

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
            let generation = revertGeneration
            let fans = try await readFans()
            let outcome = try await sequencer.engageManual(targets: newConfig.manualTargets, fans: fans)
            guard generation == revertGeneration else {
                // A revert landed mid-engage; honour it rather than letting
                // `config = newConfig` below silently undo it.
                record("SAFETY: manual engage raced a revert — reverting again")
                await revertEverything(reason: "manual engage raced a revert")
                return
            }
            config = newConfig
            config.manualTargets = outcome.clampedTargets
            verifyFailures = 0
            coolingOverride = false
            guardian.reset()
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
            guardian.reset()
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
        // Mirror the guardian's live state into the reported status so the app
        // can explain "Automatic, but Ice Cube is cooling."
        status.guardianActive = guardian.isActive
    }

    /// Read-back + re-assert: firmware or thermalmonitord can silently take
    /// control back. One re-apply is attempted; a second consecutive failure
    /// means we are not actually in control → revert and say so.
    private func verifyManualState() async {
        let generation = revertGeneration
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
            await engage(targets: config.manualTargets, fans: fans, since: generation)
        } else {
            record("SAFETY: control lost (read-back failed twice) — reverting to auto")
            await revertEverything(reason: "read-back verification failed")
        }
    }

    private func forceMaximumCooling() async {
        let generation = revertGeneration
        guard let fans = try? await readFans() else { return }
        let maxTargets = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, $0.maxRPM) })
        await engage(targets: maxTargets, fans: fans, since: generation)
    }

    private func handleWake() async {
        switch config.mode {
        case .manual:
            record("wake detected — re-asserting manual state")
            let generation = revertGeneration
            if let fans = try? await readFans(),
               await engage(targets: config.manualTargets, fans: fans, since: generation) != nil
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

    /// Runs one engage and undoes it if a revert landed while it was in flight.
    ///
    /// SAFETY: `DaemonCore` is an actor, but `engageManual` suspends on every
    /// SMC write, and `HelperService` spawns an independent `Task` per XPC
    /// message — so `revertEverything` can run to completion *between* two of
    /// this sequence's writes. The engage then finishes and re-forces the fans,
    /// leaving them physically `.forced` while `config == .auto`.
    ///
    /// Nothing recovers that state on its own: `SafetyMonitor` only acts while
    /// `config.mode != .auto`, so the 95 °C ceiling cannot fire; and the
    /// guardian's `nobodyCooling` / `orphaned` filters both read forced fans as
    /// "somebody is already cooling" and stand down. The fans would hold a
    /// fixed RPM that no longer tracks load.
    ///
    /// The generation check can only ever *add* a revert, never suppress one.
    @discardableResult
    private func engage(
        targets: [Int: Double], fans: [Fan], since generation: Int
    ) async -> FanWriteOutcome? {
        let outcome = try? await sequencer.engageManual(targets: targets, fans: fans)
        guard generation == revertGeneration else {
            record("SAFETY: fan write raced a revert — reverting again")
            await revertEverything(reason: "write raced a revert")
            return nil
        }
        return outcome
    }

    private func revertEverything(reason: String) async {
        revertGeneration &+= 1
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
        // One reset, not a hand-picked subset: the old code cleared the engage
        // debounce here but left the orphan-ladder counters stale, so the next
        // orphaned tick could skip the gentle re-park stage.
        guardian.reset()
        ConfigStore.clear() // a revert always cancels the boot promise
        status.mode = .auto
        status.appliedTargets = [:]
        status.guardianActive = false
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
        let generation = revertGeneration
        guard let fans = try? await readFans(), !fans.isEmpty else { return }
        // Sensor blindness is handled by the SafetyMonitor (revert after 3
        // failed ticks) — a single missing reading just skips this tick.
        guard let dieHot = await (try? readTemperatures())?
            .filter(\.isDieSensor)
            .map(\.celsius).max() else { return }

        var targets: [Int: Double] = [:]
        for fan in fans {
            guard let curve = config.curve(for: fan.id) else { continue }
            // SAFETY: a fan whose [Mn,Mx] range didn't read (both 0) must be
            // skipped, never driven — mapping fraction into a 0…0 range would
            // command 0 RPM, which is forbidden everywhere in Ice Cube.
            guard fan.maxRPM > fan.minRPM else { continue }
            var follower = followers[fan.id] ?? CurveFollower(
                hysteresisCelsius: config.hysteresisCelsius,
                rampUpPerTick: config.rampPerTick
            )
            let fraction = follower.step(dieCelsius: dieHot, curve: curve)
            followers[fan.id] = follower
            // Quantize AND clamp to what the write path will actually send, so
            // verifyCurveHeld compares read-back against the real command. A raw
            // target at/just above Mn can quantize below Mn and get clamped up on
            // write; the un-clamped value would then never verify (Quiet reverted
            // to auto for exactly this reason).
            targets[fan.id] = FanWriteSequencer.quantizedTarget(fraction: fraction, fan: fan)
        }
        guard !targets.isEmpty else { return }

        if targets != curveTargets {
            curveTargets = targets
            if let outcome = await engage(targets: targets, fans: fans, since: generation) {
                status.appliedTargets = outcome.clampedTargets
                status.unlockBranch = outcome.branch.rawValue
                status.lastWriteVerified = outcome.verified
            }
        } else {
            await verifyCurveHeld(expected: targets, fans: fans, since: generation)
        }
    }

    /// Same read-back discipline as manual mode: one re-assert, then revert.
    private func verifyCurveHeld(expected: [Int: Double], fans: [Fan], since generation: Int) async {
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
            await engage(targets: expected, fans: fans, since: generation)
        } else {
            record("SAFETY: curve control lost (read-back failed twice) — reverting to auto")
            await revertEverything(reason: "curve read-back verification failed")
        }
    }

    // MARK: - Guardian: Ice Cube cools when macOS won't

    /// The decision engine; see ``FanGuardian`` for the field finding behind it.
    /// All policy lives there — this actor only performs the resulting I/O.
    private var guardian = FanGuardian()

    private func autoSafetyNet() async {
        let generation = revertGeneration
        guard let fans = try? await readFans() else { return }
        let dieHot = await (try? readTemperatures())?
            .filter(\.isDieSensor)
            .map(\.celsius).max() ?? 0

        switch guardian.evaluate(fans: fans, dieCelsius: dieHot) {
        case .idle:
            break
        case let .engage(targets, die):
            record("guardian: die \(Int(die)) °C and nothing cooling — driving the fans (built-in curve)")
            await engage(targets: targets, fans: fans, since: generation)
        case let .release(die):
            record("guardian: cooled to \(Int(die)) °C — releasing the fans")
            try? await sequencer.revertAllAuto(fans: fans)
            await port.reset()
        case let .reparkOrphans(orphaned):
            record("SAFETY: fan(s) orphaned in mode 0 — re-parking, handing back, resetting SMC connection")
            for fan in orphaned {
                try? await port.writeDouble("F\(fan.id)Tg", value: fan.minRPM, as: .float)
                for suffix in ["Md", "md"] where await port.hasKey("F\(fan.id)\(suffix)") {
                    try? await port.writeDouble("F\(fan.id)\(suffix)", value: 3, as: .uint8)
                    break
                }
            }
            await port.reset()
        case let .holdAtFloor(floors):
            record("SAFETY: system did not resume control — holding fans at minimum RPM ourselves")
            await engage(targets: floors, fans: fans, since: generation)
        }
    }

    // MARK: - Hardware reads (the daemon trusts only its own readings)

    private func readFans() async throws -> [Fan] {
        // `Int(someDouble)` traps on NaN/±inf and on anything past Int.max;
        // a garbage fan count must yield no fans, not a dead daemon.
        let rawCount = try await port.readDouble("FNum")
        let count = Int(exactly: rawCount.rounded(.towardZero)) ?? 0
        guard (0 ... 64).contains(count) else {
            throw IceCubeError.smcDecodingFailed(
                key: "FNum", type: "fan count", bytes: []
            )
        }
        var fans: [Fan] = []
        for i in 0 ..< count {
            let mode: FanMode = if let raw = try? await port.readDouble("F\(i)Md") {
                FanMode(smcValue: raw)
            } else if let raw = try? await port.readDouble("F\(i)md") {
                FanMode(smcValue: raw)
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
