// DaemonCore.swift — the daemon's brain: config state, 2 s safety tick, write sequencing, status.

import Foundation
import os

/// Owns everything the daemon does between XPC calls: the enforced config,
/// the write sequencer, the SafetyMonitor, and the 2-second tick that keeps
/// the safety invariants true no matter what the app does (or fails to do).
///
/// **A deliberate exception to the ~300-line file guideline.** Splitting this
/// into `DaemonCore+Safety/+Curve/+Guardian/+Hardware` extensions was tried and
/// reverted: Swift's `private` is file-scoped, so the split forces ~15
/// safety-critical members (`config`, `revertGeneration`, `revertsInFlight`,
/// `revertPending`, `status`, the sequencer, the port…) to module-internal
/// visibility, reachable from every other file in IceCubeKit. These are not
/// separable features — they are one control loop sharing one set of race
/// guards, and the guards only work because nothing outside can touch them.
/// Trading that encapsulation for a line count would make the file shorter and
/// the daemon less safe. Navigate by the MARK sections instead.
public actor DaemonCore {
    private let port: any SMCControlPort
    private let store: any FanConfigStoring
    private let sequencer: FanWriteSequencer
    private var monitor = SafetyMonitor()
    private let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "curve")

    /// What the daemon is currently enforcing. A fresh start is `.auto` unless
    /// a valid persisted curve loads (PLAN.md §4.3.3, the boot promise).
    /// `internal`, not `private`, purely so `@testable import` can assert on it:
    /// the daemon's whole safety contract is "what is `config` vs what the fans
    /// are physically doing", and that is exactly what needs pinning by tests.
    var config: FanConfig = .auto
    /// Monotonic instant of the app's last heartbeat; see ``heartbeatAge()``.
    private var lastHeartbeatAt: ContinuousClock.Instant?
    private var status = HelperStatus()
    private var tickTask: Task<Void, Never>?
    /// Read-back mismatches since the last good verification.
    private var verifyFailures = 0
    /// Resolved sensor keys for safety monitoring (curated ∩ present).
    private var sensorKeys: [String]?
    /// True while the SafetyMonitor is forcing maximum cooling.
    private var coolingOverride = false
    /// Bumped by every revert. See ``engage(targets:fans:since:)``.
    private var revertGeneration = 0
    /// Bumped by every `apply`. Closes engage-vs-engage the way
    /// ``revertGeneration`` closes engage-vs-revert: an apply that suspends and
    /// finds this changed has been superseded and must not commit its config.
    private var applyGeneration = 0
    /// How many times one `revertEverything` re-reads the fan list before giving
    /// up on that pass. The tick then keeps retrying via ``revertPending``.
    private static let revertReadAttempts = 3
    /// True when a revert was requested but could not actually be written (the
    /// fan list would not read). The tick retries it until it lands; until then
    /// the daemon deliberately keeps `config` — and therefore every safety net —
    /// exactly as it was, because the fans may still be physically forced.
    /// `internal` for the same reason as ``config`` — a deferred revert is a
    /// safety state that must be observable in tests.
    var revertPending = false
    private var revertPendingReason: String?
    /// Consecutive failed revert attempts, used only to throttle logging.
    private var failedRevertAttempts = 0
    /// Reverts currently mid-flight. A revert suspends on every SMC write, so
    /// an engage can begin *after* the generation was bumped but *before* the
    /// revert's writes land — that engage would pass the generation check and
    /// still leave the fans forced. Counting in-flight reverts closes it.
    private var revertsInFlight = 0

    /// - Parameters:
    ///   - port: the SMC surface. The real daemon passes `SMCWritePort` (the
    ///     only IOKit writer in the system, which lives in the helper target);
    ///     tests pass a scripted fake firmware.
    ///   - store: persistence for the boot promise. Injected for the same reason.
    ///   - sleep: injected so tests do not actually wait out revert retries.
    public init(
        port: any SMCControlPort,
        store: any FanConfigStoring,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.port = port
        self.store = store
        self.sleep = sleep
        sequencer = FanWriteSequencer(port: port)
    }

    private let sleep: @Sendable (Duration) async -> Void

    // MARK: - Lifecycle

    /// SAFETY (§4.3): the daemon starts by reverting everything to auto —
    /// whatever a crash or power loss left behind is wiped clean — then runs
    /// the tick forever.
    public func start() async {
        if let persisted = store.load() {
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
            // Two clocks, because they disagree in exactly the useful way:
            // ContinuousClock keeps counting while the Mac is asleep,
            // SuspendingClock does not — so their difference IS the time spent
            // asleep. That replaces inferring sleep from a gap between tick
            // starts, which could not tell a genuinely slow tick from a nap.
            // The ftst unlock path alone can legitimately take ~10 s (3 s
            // settle + 70 × 100 ms retries), which the old 5×-interval
            // heuristic would have misread as a wake and re-asserted on.
            let continuous = ContinuousClock()
            let suspending = SuspendingClock()
            var lastReal = continuous.now
            var lastAwake = suspending.now
            // Absolute deadlines, so the period stays ~2 s instead of drifting
            // out to (tick duration + 2 s) the way `work then sleep(2s)` does.
            var deadline = continuous.now
            while !Task.isCancelled {
                let realNow = continuous.now
                let awakeNow = suspending.now
                let slept = (realNow - lastReal) - (awakeNow - lastAwake)
                lastReal = realNow
                lastAwake = awakeNow

                await self?.tick(sleptFor: slept)

                deadline = deadline.advanced(by: .seconds(HelperConstants.tickInterval))
                // A tick that overran its budget resyncs rather than firing a
                // burst of catch-up ticks at the hardware.
                if deadline < continuous.now {
                    deadline = continuous.now.advanced(by: .seconds(HelperConstants.tickInterval))
                }
                try? await Task.sleep(until: deadline, clock: continuous)
            }
        }
        log
            .notice(
                "IceCubeHelper started (protocol v\(HelperConstants.protocolVersion, privacy: .public)); all fans auto"
            )
    }

    /// SIGTERM / shutdown: leave the hardware in macOS's hands.
    ///
    /// The persisted curve is deliberately KEPT. launchd SIGTERMs us on every
    /// orderly restart, so clearing it here destroyed the Phase 4 boot promise
    /// ("keep the curve running when Ice Cube quits") on exactly the event it
    /// exists to survive — a reboot. Reverting the *hardware* is still
    /// unconditional; only the on-disk intent survives.
    public func shutdown() async {
        tickTask?.cancel()
        await revertEverything(reason: "daemon shutdown", clearsPersistence: false)
    }

    /// XPC connection dropped. Manual mode reverts immediately (faster than
    /// waiting out the watchdog); persistent curve mode would keep running.
    public func connectionInvalidated() async {
        if config.mode == .manual || (config.mode == .curve && !config.persistsWithoutApp) {
            await revertEverything(reason: "app connection invalidated")
        }
    }

    // MARK: - XPC entry points

    public func heartbeat() {
        lastHeartbeatAt = ContinuousClock().now
    }

    /// How long since the app last fed the watchdog, or `nil` if it never has.
    ///
    /// Monotonic: measured with `ContinuousClock`, not `Date`. A backwards
    /// wall-clock step (an NTP correction) used to yield a *negative* age,
    /// which is never greater than the timeout — silently deferring a revert
    /// the watchdog exists to guarantee. ContinuousClock still counts time
    /// spent asleep, so the across-sleep behaviour is unchanged.
    private func heartbeatAge() -> Duration? {
        lastHeartbeatAt.map { ContinuousClock().now - $0 }
    }

    /// Runs `body` as a revert: bumps ``revertGeneration`` and holds
    /// ``revertsInFlight`` for its entire duration, so an engage racing it can
    /// never commit.
    ///
    /// A scoped helper rather than hand-paired increments, because the pairing
    /// is a safety property: a leaked `revertsInFlight` makes every future
    /// `engage` believe a revert is in flight and undo itself, which would make
    /// fan control permanently impossible until the daemon restarts. `defer`
    /// here means no future early return inside a revert body can break it.
    private func asRevert(_ body: () async -> Void) async {
        revertGeneration &+= 1
        revertsInFlight += 1
        defer { revertsInFlight -= 1 }
        await body()
    }

    /// Drops the SMC connection **and** the sensor-key cache together.
    ///
    /// These two must always move as a pair: `port.reset()` empties the port's
    /// key-info cache and closes the connection, so keys resolved against the
    /// old connection are no longer known-good. Resetting the port alone let a
    /// stale (or empty) `sensorKeys` outlive the connection it was probed on.
    private func resetPort() async {
        await port.reset()
        sensorKeys = nil
    }

    public func apply(_ newConfig: FanConfig) async throws {
        // SERIALIZATION: `HelperService` spawns an independent Task per XPC
        // message, and this method suspends repeatedly (`readFans`, then
        // `engageManual`, which on the ftst branch can sleep 3 s + 7 s of
        // retries PER FAN). `DaemonCore` is an actor, so those suspensions are
        // reentrancy points and two applies interleave freely — the last value
        // on the wire was whichever write happened to land last, and whichever
        // apply's tail ran last won `config`/`status`. Two quick slider
        // releases could therefore leave the fans at the OLDER target while the
        // UI reported the newer one.
        //
        // The revertGeneration guard does not cover this: it closes
        // engage-vs-revert, not engage-vs-engage.
        applyGeneration &+= 1
        let myGeneration = applyGeneration

        switch newConfig.mode {
        case .auto:
            await revertEverything(reason: "app requested auto")
        case .manual:
            let generation = revertGeneration
            let fans = try await readFans()
            guard myGeneration == applyGeneration else {
                record("a newer config superseded this manual apply — discarding it")
                return
            }
            // Goes through `engage(...)`, NOT the raw sequencer: it carries both
            // halves of the revert-race guard (generation AND revertsInFlight),
            // and it reverts on a partially-applied sequence. Calling the
            // sequencer directly here checked only the generation and left a
            // throw mid-sequence to strand already-forced fans while `config`
            // stayed `.auto` — the unrecoverable state `engage`'s own doc
            // comment says must never be reachable.
            guard let outcome = await engage(
                targets: newConfig.manualTargets, fans: fans, since: generation
            ) else {
                // `engage` already reverted and logged the reason.
                return
            }
            // Re-checked after the engage's suspensions: a newer apply may have
            // landed its writes while this one was inside the ftst retry loop,
            // and committing this config now would report the older target.
            guard myGeneration == applyGeneration else {
                record("a newer config superseded this manual apply after its writes — not committing")
                return
            }
            config = newConfig
            config.manualTargets = outcome.clampedTargets
            verifyFailures = 0
            coolingOverride = false
            guardian.reset()
            monitor = SafetyMonitor()
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
            monitor = SafetyMonitor()
            status.mode = .curve
            store.save(newConfig) // persists only when the rules allow
            await runCurveTick()
            record("curve engaged (persists without app: \(newConfig.persistsWithoutApp))")
        }
    }

    public func setAllAuto() async {
        await revertEverything(reason: "app requested revert")
    }

    public func currentStatus() -> HelperStatus {
        status
    }

    // MARK: - The safety tick

    /// - Parameter sleptFor: how long the machine was actually asleep since the
    ///   previous tick, measured as ContinuousClock − SuspendingClock.
    /// `internal` so tests can drive single ticks deterministically instead of
    /// racing the 2 s loop that `start()` spawns.
    func tick(sleptFor slept: Duration) async {
        // Firmware silently resets manual control across sleep (§3.4), so any
        // real nap means re-assert or revert. Measured, not inferred: a slow
        // tick is no longer mistaken for a wake.
        if slept > .seconds(HelperConstants.tickInterval) {
            await handleWake()
        }

        // A revert that could not be written earlier outranks everything else:
        // until it lands, the fans may still be physically forced.
        if revertPending {
            await revertEverything(reason: revertPendingReason ?? "retrying deferred revert")
            if revertPending {
                return // still cannot reach the hardware; try again next tick
            }
        }

        let temps = try? await readTemperatures()
        let verdict = monitor.evaluate(
            heartbeatAge: heartbeatAge(), config: config, temperatures: temps
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
        let outcome: FanWriteOutcome?
        do {
            outcome = try await sequencer.engageManual(targets: targets, fans: fans)
        } catch {
            // SAFETY: `engageManual` forces fans one at a time, so a throw can
            // land AFTER earlier fans are already `.forced`. Swallowing it with
            // `try?` left those fans pinned at a fixed RPM while the caller
            // walked away — and with `config` still `.auto` neither the
            // watchdog, the ceiling, nor the guardian would ever look at them
            // again. Unwind before returning.
            record("SAFETY: fan write failed mid-sequence — reverting (\(error.localizedDescription))")
            await revertEverything(reason: "fan write failed mid-sequence")
            return nil
        }
        // Two conditions, covering both orderings: a revert that STARTED after
        // this engage captured its generation, and a revert that was already
        // running when it did (whose writes may still be landing).
        guard generation == revertGeneration, revertsInFlight == 0 else {
            record("SAFETY: fan write raced a revert — reverting again")
            await revertEverything(reason: "write raced a revert")
            return nil
        }
        return outcome
    }

    /// - Parameter clearsPersistence: whether this revert also cancels the boot
    ///   promise. True for every user- or safety-driven revert (the user asked
    ///   for auto, or we lost control); false only for daemon shutdown, where
    ///   the intent should survive the restart.
    private func revertEverything(reason: String, clearsPersistence: Bool = true) async {
        revertGeneration &+= 1
        revertsInFlight += 1
        defer { revertsInFlight -= 1 }

        // SAFETY: a revert that wrote NOTHING must never be recorded as done.
        // `(try? readFans()) ?? []` used to hand an empty array to
        // `revertAllAuto`, whose `fanIDs.min()` is nil → throws → the caller's
        // `try?` returns immediately. Zero SMC writes — yet the state below
        // still declared `.auto`, which silently disarms the watchdog, the
        // ceiling AND the guardian for fans that are physically still forced.
        // Nothing in the tick recovers that, so we must keep control instead.
        var reverted = false
        for attempt in 1 ... Self.revertReadAttempts {
            // Only a *failed read* is worth retrying. An empty list is a real
            // answer on a fanless Mac (the M2 Air is in the curated model set),
            // and treating that as a failure would pin the daemon in
            // `revertPending` forever, re-reverting nothing on every tick.
            guard let fans = try? await readFans() else {
                if attempt < Self.revertReadAttempts {
                    await sleep(.milliseconds(200))
                }
                continue
            }
            guard !fans.isEmpty else {
                reverted = true // nothing to hand back
                break
            }
            do {
                try await sequencer.revertAllAuto(fans: fans)
                reverted = true
            } catch {
                record("revert attempt \(attempt) failed: \(error.localizedDescription)")
            }
            break
        }
        // Release the SMC connection: thermalmonitord reliably resumes fan
        // control only once the writer's connection is gone (field-observed).
        await resetPort()

        guard reverted else {
            // Hold every safety net armed and retry on the next tick, rather
            // than claiming an auto state we did not actually reach.
            revertPending = true
            revertPendingReason = reason
            status.lastWriteVerified = false
            // Throttled: the tick retries every 2 s, and an SMC that stays
            // broken would otherwise write ~1800 lines an hour into a log whose
            // whole job is making each write auditable. First failure and every
            // 30th (~1 min) is enough to see it is still stuck.
            if failedRevertAttempts % 30 == 0 {
                record("SAFETY: revert could not be applied (\(reason)) — retrying every tick, control retained")
            }
            failedRevertAttempts &+= 1
            return
        }
        if failedRevertAttempts > 0 {
            record("revert succeeded after \(failedRevertAttempts) failed attempt(s)")
        }
        failedRevertAttempts = 0
        revertPending = false
        revertPendingReason = nil
        config = .auto
        coolingOverride = false
        verifyFailures = 0
        followers = [:]
        curveTargets = [:]
        // One reset, not a hand-picked subset: the old code cleared the engage
        // debounce here but left the orphan-ladder counters stale, so the next
        // orphaned tick could skip the gentle re-park stage.
        guardian.reset()
        monitor = SafetyMonitor()
        if clearsPersistence {
            store.clear() // a user/safety revert cancels the boot promise
        }
        status.mode = .auto
        status.appliedTargets = [:]
        status.guardianActive = false
        record("all fans auto (\(reason))")
    }

    // MARK: - Curve control loop (Phase 4)

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
        guard let dieHot = await (try? readTemperatures())?.hottestDieCelsius else { return }

        var targets: [Int: Double] = [:]
        for fan in fans {
            guard let curve = config.curve(for: fan.id) else { continue }
            // SAFETY: a fan whose [Mn,Mx] range didn't read cleanly must be
            // skipped, never driven — mapping a fraction into a range with no
            // positive floor would command 0 RPM, which is forbidden everywhere
            // in Ice Cube. See `Fan.hasUsableRange`.
            guard fan.hasUsableRange else { continue }
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
        // SAFETY: a failed temperature read must NOT read as 0 °C. That is the
        // fail-unsafe direction: a guardian actively cooling a 90 °C machine saw
        // 0 °C on the next blind tick, took the release branch, and handed a hot
        // Mac back to a thermalmonitord that (per FanGuardian's own field note)
        // does not reliably resume. Skipping the tick holds the last decision.
        guard let dieHot = await (try? readTemperatures())?.hottestDieCelsius else {
            record("guardian: temperature read failed — holding previous decision")
            return
        }

        // The guardian only ever acts while the daemon holds nothing itself.
        // `readFans()` and `readTemperatures()` above are both suspension points,
        // and `HelperService` spawns a Task per XPC message — so an `apply` can
        // land in between and put us in manual/curve. Writing then would fight
        // the user's own config, and the two branches below bypass `engage()`
        // (no generation bump, no revertsInFlight), so nothing else catches it.
        guard config.mode == .auto, !revertPending else {
            return
        }

        switch guardian.evaluate(fans: fans, dieCelsius: dieHot) {
        case .idle:
            break
        case let .engage(targets, die):
            record("guardian: die \(Int(die)) °C and nothing cooling — driving the fans (built-in curve)")
            await engage(targets: targets, fans: fans, since: generation)
        case let .release(die):
            record("guardian: cooled to \(Int(die)) °C — releasing the fans")
            await asRevert {
                try? await self.sequencer.revertAllAuto(fans: fans)
            }
            await resetPort()
        case let .reparkOrphans(orphaned):
            record("SAFETY: fan(s) orphaned in mode 0 — re-parking, handing back, resetting SMC connection")
            await asRevert {
                for fan in orphaned {
                    try? await self.port.writeDouble("F\(fan.id)Tg", value: fan.minRPM, as: .float)
                    for suffix in ["Md", "md"] where await self.port.hasKey("F\(fan.id)\(suffix)") {
                        try? await self.port.writeDouble("F\(fan.id)\(suffix)", value: 3, as: .uint8)
                        break
                    }
                }
            }
            await resetPort()
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
            // Unmapped models fall back to probing the candidate superset
            // instead of resolving to nothing — an unknown Mac used to leave
            // the daemon permanently blind, which disables the ceiling and the
            // guardian while the app's UI still shows correct temperatures.
            let model = HostInfo.modelIdentifier()
            let candidates = SMCKeyMaps.curatedSensors(forModel: model)
                ?? SMCKeyMaps.fallbackCandidateSensors
            var present: [String] = []
            for sensor in candidates where await port.hasKey(sensor.key) {
                present.append(sensor.key)
            }
            // SAFETY: an EMPTY probe is "unresolved", not "this Mac has no
            // sensors". Caching [] is non-nil, so the old code never retried —
            // and the very first probe runs right after `start()`'s
            // `port.reset()` closed the connection, so one failed lazy reopen
            // blinded the daemon for its whole lifetime, silently, even on
            // supported hardware. Leaving it nil makes the next tick retry.
            guard !present.isEmpty else {
                record("SAFETY: no temperature sensors resolved (model \(model)) — retrying next tick")
                throw IceCubeError.smcKeyNotFound(key: "T***")
            }
            sensorKeys = present
            record("resolved \(present.count) temperature sensors (model \(model))")
        }
        var readings: [SensorReading] = []
        var missing: [String] = []
        for key in sensorKeys ?? [] {
            guard let value = try? await port.readDouble(key) else {
                missing.append(key)
                continue
            }
            // SAFETY: an over-range reading is CLAMPED, never discarded. The
            // plausibility filter caps at 120 °C, so a sensor reporting 121 °C
            // used to vanish from the array entirely — i.e. the single hottest
            // point in the machine silently stopped counting toward the ceiling
            // at exactly the moment it mattered most. Below 10 °C still reads as
            // a dead/unpopulated sensor and is dropped.
            if value >= 120 {
                readings.append(SensorReading(key: key, label: key, celsius: 120))
                continue
            }
            if SMCKeyMaps.isPlausibleTemperature(value) {
                readings.append(SensorReading(key: key, label: key, celsius: value))
            } else {
                missing.append(key)
            }
        }
        guard !readings.isEmpty else {
            throw IceCubeError.smcKeyNotFound(key: "T***")
        }
        // Partial blindness is a health event too. `readTemperatures` only threw
        // when EVERY sensor failed, so losing just the hottest one left the
        // ceiling evaluating a set that no longer contained it — with no
        // counter, no log line and no change in HelperStatus. Re-probe once the
        // set shrinks, and say so.
        // Surfaced via `record` (and therefore `HelperStatus.recentEvents`)
        // rather than a new status field: HelperStatus crosses XPC with a
        // synthesized decoder, so a new non-optional key would fail to decode
        // against a mismatched helper for no gain here.
        if missing.count > partialSensorFailureTolerance {
            record("SAFETY: \(missing.count) of \(readings.count + missing.count) sensors unreadable — re-probing")
            sensorKeys = nil
        }
        return readings
    }

    /// How many sensors may drop out before we re-probe the whole set. One
    /// flaky key is normal; a third of them vanishing is a connection problem.
    private var partialSensorFailureTolerance: Int {
        max(1, (sensorKeys?.count ?? 0) / 3)
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
