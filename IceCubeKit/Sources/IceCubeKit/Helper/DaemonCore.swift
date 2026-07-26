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
    /// `HelperConstants.logSubsystem`, not the literal: under test this becomes
    /// a separate subsystem so scripted 110 °C and firmware-rejection scenarios
    /// cannot masquerade as things that happened to the user's Mac.
    private let log = Logger(subsystem: HelperConstants.logSubsystem, category: "curve")

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
            status.activeCurve = persisted.sharedCurve
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
            await keepFansSpinning(reason: "app quit")
        }
    }

    /// Immediately after a deliberate hand-back, decides whether the fans may
    /// stop — and if not, takes them straight back at their floor.
    ///
    /// Called *only* from a hand-back that is a choice — in practice the app
    /// quitting — and never from a safety revert, and never from `setAllAuto`
    /// (the "Turn Off Fan Control" path, which must actually let go). When the
    /// daemon reverts because it lost read-back control or tripped the ceiling,
    /// letting go is the point; grabbing the fans again a millisecond later
    /// would defeat it.
    ///
    /// Why here and not in the tick: see ``FanGuardian/handBack(fans:dieCelsius:)``.
    /// A 2 s tick cannot catch a fan that coasts to a stop in 2.5 s, and a fan
    /// that has stopped needs ~9 s to move again no matter what it is commanded.
    private func keepFansSpinning(reason: String) async {
        let generation = revertGeneration
        guard config.mode == .auto, !revertPending else { return }
        // Every exit below says why. The first version of this logged only on
        // the path it took, so when it silently did nothing on real hardware
        // there was no way to tell whether it had decided not to, failed to
        // read, or never run at all — it cost a whole round-trip with the owner
        // to establish that the answer was "the die was 52.9 °C".
        guard let fans = try? await readFans(), !fans.isEmpty else {
            record("\(reason): could not read the fans — leaving them to macOS")
            return
        }
        guard let die = await (try? readTemperatures())?.hottestDieCelsius else {
            record("\(reason): could not read a die sensor — leaving the fans to macOS")
            return
        }
        guard case let .holdAtFloor(targets) = guardian.handBack(fans: fans, dieCelsius: die) else {
            record("\(reason) at \(Int(die)) °C — cold enough to let the fans stop")
            return
        }
        record("\(reason) at \(Int(die)) °C — holding the fans at minimum rather than letting them stop")
        await engage(targets: targets, fans: fans, since: generation)
        status.guardianActive = guardian.isActive
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
        writeIntent &+= 1
        revertGeneration &+= 1
        revertsInFlight += 1
        defer { revertsInFlight -= 1 }
        await body()
    }

    // MARK: - Serializing the write sequences themselves

    /// Bumped by every new "the fans should be X" decision, whoever makes it.
    ///
    /// The lock below stops two sequences INTERLEAVING; this stops a stale one
    /// WINNING. They are different failures: without the counter the floor-hold
    /// engage and the curve engage each write cleanly, and the fans end up
    /// wherever the older sequence finished. Checked inside the lock, so a
    /// decision that queued behind a newer one simply stands down.
    private var writeIntent = 0
    /// True while a write sequence owns the hardware; waiters queue below.
    private var writeInFlight = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` with exclusive use of the SMC write path.
    ///
    /// `DaemonCore` is an actor, which serializes *statements* but not
    /// *sequences*: `engageManual` suspends on every SMC call, so two engages
    /// interleave freely and the fans end up wherever the LAST write landed
    /// rather than wherever the NEWEST intent said. `revertGeneration` and
    /// `revertsInFlight` close revert-vs-engage; nothing closed engage-vs-engage.
    ///
    /// Seen on an ordinary app restart, in the log, with both writers behaving
    /// perfectly on their own: quitting hands back and the guardian starts
    /// writing the fan floor (2317), the app relaunches 250 ms later and the
    /// curve engage writes 3400 straight through the middle of it, and the
    /// floor-hold write lands last. Read-back then legitimately reported
    /// `target 2317 != 3400`. The tick re-asserted a second later, so it
    /// self-corrected — but "the newest intent wins" should not depend on a
    /// retry, and the same interleave with a *manual* engage would leave the
    /// user's slider fighting the guardian for a whole tick.
    ///
    /// SAFETY: nothing that can call `revertEverything` may hold this. Every
    /// caller therefore releases before its error path, and the lock covers
    /// only the sequencer call itself — a revert blocked behind an engage that
    /// is waiting on that revert would be a deadlock in the one code path that
    /// must never stall.
    private func withWriteLock<T>(_ body: () async throws -> T) async rethrows -> T {
        while writeInFlight {
            await withCheckedContinuation { writeWaiters.append($0) }
        }
        writeInFlight = true
        // `defer`, not a paired release: a throwing sequence must hand the lock
        // on before its error propagates, because the caller's catch reverts —
        // and a revert waiting on a lock held by the engage that is waiting on
        // the revert is the one deadlock this daemon cannot survive.
        defer {
            writeInFlight = false
            if !writeWaiters.isEmpty {
                writeWaiters.removeFirst().resume()
            }
        }
        return try await body()
    }

    /// Drops the SMC connection so `thermalmonitord` will take the fans back.
    ///
    /// The sensor-key cache is deliberately KEPT. Which `T***` keys this Mac
    /// has is a property of the machine, not of the connection — an earlier
    /// version cleared them here on the theory that keys resolved against a
    /// closed connection were no longer trustworthy, which is simply not true,
    /// and it made every hand-back to macOS re-probe ~20 keys on the next tick.
    ///
    /// That cost lands on the worst possible path: the user clicks macOS, then
    /// picks a curve, and the curve tick has to re-discover every sensor on a
    /// just-reopened connection before it can compute a single target — and
    /// bails to the NEXT tick if any of that fails. Measured gaps from
    /// "all fans auto" to "curve engaged" were 1s, 2s, 3s and 6s, which is
    /// exactly the "instant sometimes, slow other times" the user reported.
    ///
    /// The case that motivated clearing — an unusable probe being cached
    /// forever — is handled where it belongs: `readTemperatures()` refuses to
    /// cache an empty or die-less result, so a bad probe never becomes state.
    private func resetPort() async {
        await port.reset()
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
            // Defensive since 2026-07-26: no UI can send `.auto` any more (the
            // macOS preset is gone), but an older app build on a newer daemon
            // still can, and the protocol still carries the case. Note this is
            // NOT the path behind "Turn Off Fan Control" — that is `setAllAuto`,
            // which reverts WITHOUT taking the fans back, because turning the
            // feature off has to mean off.
            await revertEverything(reason: "app requested auto")
            await keepFansSpinning(reason: "fans handed back")
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
            status.activeCurve = nil
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
            status.activeCurve = newConfig.sharedCurve
            store.save(newConfig) // persists only when the rules allow
            await runCurveTick()
            record("curve engaged (persists without app: \(newConfig.persistsWithoutApp))")
        }
    }

    // MARK: - Write-path self-test (PLAN.md §4.3.6)

    /// True while a self-test is running, so two cannot overlap.
    private var selfTestInFlight = false
    /// The firmware's own words the last time a write sequence threw. Kept so a
    /// report can quote it rather than paraphrase — "rejected the operation on
    /// key 'F1Md' (result 0x84)" tells a maintainer what to fix; "write failed"
    /// does not.
    private var lastWriteFailure: String?

    /// Checks whether this Mac's fans can actually be driven, and reports what
    /// it learned (see ``WritePathReport``).
    ///
    /// **Writes each fan's CURRENT target back to itself.** That is the whole
    /// trick: it is a real write down the real path — it forces the mode key,
    /// exercises the `Ftst` unlock if the firmware demands it, and verifies by
    /// read-back — while commanding no change at all. Nothing spins up, nothing
    /// gets loud, and a user can press the button without wondering what it is
    /// about to do to their machine.
    ///
    /// SAFETY: goes through ``engage(targets:fans:since:)`` and
    /// ``revertEverything(reason:)`` rather than touching the sequencer
    /// directly, so it inherits every guard already built — the write lock, the
    /// intent counter, the revert-race generation check, and the clamp. A probe
    /// that reached around those would be the one piece of write code in the
    /// daemon that could strand the fans.
    ///
    /// **Restores whatever it interrupted.** The first version of this ended in
    /// `.auto` and assumed the app's next maintenance pass would re-apply the
    /// user's curve. It does not: `autoResumeIfNeeded()` is latched once per
    /// session, so on real hardware the check silently swapped a running
    /// Balanced curve for the guardian's floor hold and left it there until the
    /// user clicked a preset. A diagnostic that changes your fan settings is
    /// not a diagnostic. Caught on the Mac14,9 the moment it first ran.
    public func selfTestWritePath() async -> WritePathReport {
        guard !selfTestInFlight else {
            return WritePathReport(verdict: .unavailable, detail: "A check is already running.")
        }
        selfTestInFlight = true
        lastWriteFailure = nil // never attribute an old failure to this run
        // Captured before anything is touched and re-applied at every exit,
        // including the early returns below.
        let interrupted = config
        defer {
            selfTestInFlight = false
            if interrupted.mode != .auto {
                Task { try? await self.apply(interrupted) }
            }
        }

        guard let fans = try? await readFans() else {
            record("self-test: could not read the fans")
            return WritePathReport(
                verdict: .unavailable, detail: "The SMC could not be read just now."
            )
        }
        let ranges = Dictionary(
            fans.lazy.map { ($0.id, [$0.minRPM, $0.maxRPM]) },
            uniquingKeysWith: { first, _ in first }
        )
        let hasFtst = await port.hasKey("Ftst")

        // Fans with no usable [Mn, Mx] are skipped everywhere else in the
        // daemon, and skipping them here too is what keeps a fanless Mac from
        // being reported as a failure.
        let drivable = fans.filter(\.hasUsableRange)
        guard !drivable.isEmpty else {
            record("self-test: no fan reports a usable range — nothing to drive")
            return WritePathReport(
                verdict: .noUsableFans, fanCount: fans.count, fanRanges: ranges,
                hasFtstKey: hasFtst,
                detail: fans.isEmpty ? "This Mac reports no fans." : nil
            )
        }

        // Each fan's own current target, so the command is a no-op on the
        // hardware. Falling back to the floor when the firmware reports 0
        // (auto mode parks it there) keeps us from ever writing 0 RPM, which is
        // forbidden everywhere in Ice Cube.
        let targets = Dictionary(
            drivable.lazy.map { ($0.id, $0.targetRPM > 0 ? $0.targetRPM : $0.minRPM) },
            uniquingKeysWith: { first, _ in first }
        )

        record("self-test: checking the fan write path")
        let generation = revertGeneration
        let outcome = await engage(targets: targets, fans: drivable, since: generation)
        let suffix = await sequencer.resolvedModeKeySuffix
        let branch = await sequencer.knownBranch?.rawValue

        // Always hand back, whatever happened. `engage` already reverts on its
        // own failure paths; this covers the success path, where the fans would
        // otherwise be left forced by a diagnostic.
        await revertEverything(reason: "write-path self-test finished")

        guard let outcome else {
            record("self-test: the firmware refused the fan write")
            return WritePathReport(
                verdict: .rejected, modeKeySuffix: suffix, unlockBranch: branch,
                fanCount: fans.count, fanRanges: ranges, hasFtstKey: hasFtst,
                detail: lastWriteFailure ?? "The firmware rejected the mode write."
            )
        }
        let verdict: WritePathReport.Verdict = outcome.verified ? .verified : .notVerified
        record("self-test: \(verdict.rawValue) (\(outcome.branch.rawValue) path)")
        return WritePathReport(
            verdict: verdict, modeKeySuffix: suffix,
            unlockBranch: outcome.branch.rawValue, fanCount: fans.count,
            fanRanges: ranges, hasFtstKey: hasFtst,
            detail: outcome.verified
                ? nil
                : "Writes were accepted but read-back disagreed."
        )
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
        // Never `uniqueKeysWithValues` here: it traps on a duplicate fan id,
        // and this is the 95 °C emergency-cooling path — the very last place
        // that may crash.
        let maxTargets = Dictionary(
            fans.map { ($0.id, $0.maxRPM) }, uniquingKeysWith: { first, _ in first }
        )
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
        // Exclusive for the whole sequence: `engageManual` writes a mode and a
        // target PER FAN, so a second engage slipping between those writes
        // leaves the fans split between two intents. Released before the error
        // path below, which reverts.
        writeIntent &+= 1
        let myIntent = writeIntent
        let outcome: FanWriteOutcome?
        do {
            outcome = try await withWriteLock {
                // Re-checked INSIDE the lock, which is the only place it means
                // anything: a newer intent may have arrived while this one
                // queued, and writing now would hand the fans to the older of
                // two live decisions.
                guard myIntent == self.writeIntent else {
                    self.record("stale fan write superseded by a newer one — standing down")
                    return nil
                }
                return try await self.sequencer.engageManual(targets: targets, fans: fans)
            }
        } catch {
            // SAFETY: `engageManual` forces fans one at a time, so a throw can
            // land AFTER earlier fans are already `.forced`. Swallowing it with
            // `try?` left those fans pinned at a fixed RPM while the caller
            // walked away — and with `config` still `.auto` neither the
            // watchdog, the ceiling, nor the guardian would ever look at them
            // again. Unwind before returning.
            lastWriteFailure = error.localizedDescription
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
        writeIntent &+= 1
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
                try await withWriteLock { try await self.sequencer.revertAllAuto(fans: fans) }
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
        status.activeCurve = nil
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
        // failed ticks). A single missing reading used to skip this tick
        // outright — a 2 second wait for a millisecond problem, and it landed
        // precisely when the user was watching: `apply(.curve)` calls this
        // immediately, on a connection that `resetPort()` just closed, so the
        // first read after handing back to macOS is the one most likely to
        // miss. Retrying in place turns that into an imperceptible pause.
        guard let dieHot = await hottestDieRetrying() else { return }

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
            // Names the offender. "Mismatch" on its own was unactionable: it
            // could not distinguish a fan the firmware had genuinely taken back
            // from a read that simply failed, which is what it actually was.
            let offenders = fans.compactMap { fan -> String? in
                guard let target = expected[fan.id] else { return nil }
                guard fan.mode != .forced || abs(fan.targetRPM - target) > 1 else { return nil }
                return "fan \(fan.id) mode \(fan.mode) target \(Int(fan.targetRPM)) != \(Int(target))"
            }
            record("curve read-back mismatch (\(offenders.joined(separator: "; "))) — re-asserting")
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
                try? await self.withWriteLock { try await self.sequencer.revertAllAuto(fans: fans) }
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

    /// Reads a key that this Mac may or may not have, retrying transient
    /// failures — the distinction the fan reads used to collapse.
    ///
    /// Returns nil ONLY when the firmware itself says the key does not exist
    /// (`SMCResult.keyNotFound`), which is a real per-machine difference worth
    /// tolerating. Every other failure is transport-level and gets retried, and
    /// if it still fails it is THROWN rather than turned into a number.
    ///
    /// That last part is the whole point. `readFans` used to swallow every
    /// failure with `(try? …) ?? 0`, so a fan whose mode read missed came back
    /// as `.system` with `targetRPM` 0 — which is bit-for-bit what "macOS took
    /// the fans off us" looks like. `verifyCurveHeld` believed it, logged a
    /// read-back mismatch and re-asserted; twice in a row and it would have
    /// reverted a perfectly healthy curve to auto and told the user it had lost
    /// control. Observed on a normal app restart, because `resetPort()` closes
    /// the connection and the first read after it is the one most likely to
    /// miss — the same hazard `hottestDieRetrying()` already exists to absorb
    /// for temperatures, which the fan path never got.
    private func readOptional(_ key: String) async throws -> Double? {
        for attempt in 0 ..< Self.readRetries {
            do {
                return try await port.readDouble(key)
            } catch IceCubeError.smcKeyNotFound {
                return nil // genuinely absent on this Mac — not a failure
            } catch {
                guard attempt < Self.readRetries - 1 else { throw error }
                await sleep(.milliseconds(60))
            }
        }
        return nil
    }

    /// Matches `hottestDieRetrying()`: enough to ride out a connection reopen,
    /// short enough that a genuinely dead SMC still fails within one tick.
    private static let readRetries = 3

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
            // Only an ABSENT mode key means `.system`. A mode key that exists
            // but would not read now throws, so the caller skips this tick
            // rather than concluding we have lost the fans.
            let mode: FanMode = if let raw = try await readOptional("F\(i)Md") {
                FanMode(smcValue: raw)
            } else if let raw = try await readOptional("F\(i)md") {
                FanMode(smcValue: raw)
            } else {
                .system
            }
            try await fans.append(Fan(
                id: i,
                name: "Fan \(i)",
                mode: mode,
                actualRPM: readOptional("F\(i)Ac") ?? 0,
                targetRPM: readOptional("F\(i)Tg") ?? 0,
                minRPM: readOptional("F\(i)Mn") ?? 0,
                maxRPM: readOptional("F\(i)Mx") ?? 0
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
            // Admission requires a plausible first READ, not mere existence —
            // the same rule SystemSMCProvider.sensorDescriptors() uses, and for
            // the same reason. A curated map is per *generation*, but a given
            // machine populates only part of it (an M2 Pro has fewer P-cores
            // than an M2 Max, most laptops have one battery). Those keys exist,
            // so `hasKey` admits them, but they never return a real temperature.
            //
            // Admitting them was harmless while nothing counted them. Once the
            // partial-failure check below started treating an unreadable member
            // as a health signal, 8 of 20 permanently-dead keys tripped it on
            // every tick: re-probe, re-admit the same dead keys, trip again —
            // a loop that re-ran discovery ~40 SMC calls a tick, forever.
            // Each candidate gets a SECOND chance before being written off.
            // Admission-by-read makes the resolved set depend on *when* the
            // probe runs, and it often runs at the worst moment — right after
            // `port.reset()` closes the connection, or on wake. Observed in the
            // field: probes resolving 20, then 16, then 12, then 2 sensors on
            // the same Mac. A transient miss must not permanently disown a
            // working sensor.
            var present: [String] = []
            for sensor in candidates {
                var value = try? await port.readDouble(sensor.key)
                if value == nil || !SMCKeyMaps.isPlausibleTemperature(value ?? 0) {
                    value = try? await port.readDouble(sensor.key)
                }
                guard let value, SMCKeyMaps.isPlausibleTemperature(value) else { continue }
                present.append(sensor.key)
            }
            // SAFETY: an EMPTY probe is "unresolved", not "this Mac has no
            // sensors". Caching [] is non-nil, so the old code never retried —
            // and the very first probe runs right after `start()`'s
            // `port.reset()` closed the connection, so one failed lazy reopen
            // blinded the daemon for its whole lifetime, silently, even on
            // supported hardware. Leaving it nil makes the next tick retry.
            // SAFETY: a probe that resolved nothing — or resolved no DIE sensor
            // — is "unresolved", not an answer. Caching [] is non-nil, so the
            // old code never retried, and the very first probe runs right after
            // `start()`'s `port.reset()` closed the connection: one failed lazy
            // reopen blinded the daemon for its whole lifetime.
            //
            // The die requirement is the safety-relevant half. `hottestDieCelsius`
            // is what BOTH the curve and the guardian run on, so a set of only
            // battery and airflow sensors leaves the daemon unable to control or
            // protect anything while looking healthy. Observed for real: one
            // probe resolved 2 sensors on a machine that normally reports 12.
            let hasDie = present.contains(where: SMCKeyMaps.isDieKey)
            guard !present.isEmpty, hasDie else {
                record(
                    "SAFETY: sensor probe unusable (\(present.count) found, die: \(hasDie), "
                        + "model \(model)) — retrying next tick"
                )
                throw IceCubeError.smcKeyNotFound(key: "T***")
            }
            sensorKeys = present
            record("resolved \(present.count) temperature sensors (model \(model))")
        }
        var readings: [SensorReading] = []
        var missing: [String] = []
        for key in sensorKeys ?? [] {
            // Only a genuine READ FAILURE counts as missing. A member that
            // reads an implausible value has glitched for this tick, not gone
            // away: it stays in the set and is picked up again when it
            // recovers. Re-probing would not fix a glitch and, before the
            // admission rule above, guaranteed an infinite re-probe loop.
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
            }
            // else: a one-tick glitch on an admitted sensor. Skipped for this
            // evaluation, kept in the set — NOT counted as missing, or a single
            // flapping sensor would re-probe the whole map every couple of ticks.
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

    /// The hottest die reading, retrying briefly rather than skipping a tick.
    ///
    /// Bounded deliberately: three quick attempts, not a loop. If the SMC is
    /// genuinely unreachable the SafetyMonitor's sensor-failure rule must still
    /// see failed ticks and revert — this exists to absorb a cold connection,
    /// not to paper over a broken one.
    private func hottestDieRetrying() async -> Double? {
        for attempt in 0 ..< 3 {
            if let die = await (try? readTemperatures())?.hottestDieCelsius {
                return die
            }
            if attempt < 2 {
                await sleep(.milliseconds(60))
            }
        }
        return nil
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
