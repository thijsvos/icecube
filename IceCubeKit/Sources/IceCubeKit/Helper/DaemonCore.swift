// DaemonCore.swift — the daemon's brain: config state, 2 s safety tick, write sequencing, status.

import Foundation
import os

/// Owns everything the daemon does between XPC calls: the enforced config,
/// the write sequencer, the SafetyMonitor, and the 2-second tick that keeps
/// the safety invariants true no matter what the app does (or fails to do).
///
/// **A deliberate exception to the ~300-line file guideline — and it is now
/// roughly 1,400 lines, so the exception deserves the real number.** Splitting
/// this into `DaemonCore+Safety/+Curve/+Guardian/+Hardware` extensions has been
/// tried and reverted TWICE (most recently 2026-07-26, with the split written
/// and building before it was thrown away). Swift's `private` is file-scoped,
/// so the split forces the safety-critical members to module-internal
/// visibility, reachable from every other file in IceCubeKit: `config`,
/// `revertGeneration`, `revertsInFlight`, `revertPending`, `status`, the
/// sequencer, the port — and since then also `writeInFlight`/`writeWaiters`
/// (the write lock), `writeIntent` (the ledger deciding which decision wins)
/// and `selfTestInFlight`.
///
/// These are not separable features. They are one control loop sharing one set
/// of race guards, and the guards only work because nothing outside can touch
/// them. Trading that encapsulation for a line count would make the file
/// shorter and the daemon less safe. Navigate by the MARK sections instead.
public actor DaemonCore {
    private let port: any SMCControlPort
    private let store: any FanConfigStoring
    private let sequencer: FanWriteSequencer
    private var monitor = SafetyMonitor()
    /// `HelperConstants.logSubsystem`, not the literal: under test this becomes
    /// a separate subsystem so scripted 110 °C and firmware-rejection scenarios
    /// cannot masquerade as things that happened to the user's Mac.
    private let log = Logger(subsystem: HelperConstants.logSubsystem, category: "curve")

    /// What the daemon is currently enforcing.
    ///
    /// A fresh start is `.auto` unless a valid persisted curve loads (PLAN.md
    /// §4.3.3, the boot promise). `internal`, not `private`, purely so `@testable
    /// import` can assert on it: the daemon's whole safety contract is "what is
    /// `config` vs what the fans are physically doing", and that is exactly what
    /// needs pinning by tests.
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
    /// fan list would not read).
    ///
    /// The tick retries it until it lands; until then the daemon deliberately
    /// keeps `config` — and therefore every safety net — exactly as it was,
    /// because the fans may still be physically forced. `internal` for the same
    /// reason as ``config`` — a deferred revert is a safety state that must be
    /// observable in tests.
    var revertPending = false
    private var revertPendingReason: String?
    /// Consecutive failed revert attempts, used only to throttle logging.
    private var failedRevertAttempts = 0
    /// Reverts currently mid-flight.
    ///
    /// A revert suspends on every SMC write, so an engage can begin *after* the
    /// generation was bumped but *before* the revert's writes land — that engage
    /// would pass the generation check and still leave the fans forced. Counting
    /// in-flight reverts closes it.
    private var revertsInFlight = 0

    /// Whether the machine is parked for sleep as far as we know. See
    /// ``SleepLatch``. `internal` for the same reason as ``config`` — a parked
    /// daemon is a safety state that must be assertable in tests.
    var sleepLatch = SleepLatch()
    /// A `kIOMessageSystemHasPoweredOn` that arrived before any display was up.
    ///
    /// The message and the capability bits are not guaranteed to change in the
    /// same instant, and the message is the only edge we get — a
    /// DarkWake→FullWake promotion does not send a second one. Remembering the
    /// edge and completing it from the tick is what makes the gate safe in both
    /// directions: a message that races the video bit still unparks within one
    /// tick, and a message genuinely delivered on a dark wake never unparks at
    /// all.
    private var pendingPowerOn = false
    /// Throttles the "staying parked" line to one per dark wake.
    private var darkWakeHoldRecorded = false
    /// True while a hand-back is running, so N racing engages that all discover
    /// the park produce ONE `revertAllAuto`, not N.
    private var parkInFlight = false
    /// Set whenever the latch releases, consumed by the next tick.
    ///
    /// NOT a direct call to ``handleWake()``: protocol v19 deliberately moved
    /// the wake re-assert BEHIND the safety verdict, and calling it from the
    /// power callback would put it back in front. It also closes the race that
    /// makes a naive latch silently break the wake half — at the instant of
    /// wake, the tick loop's long-expired `Task.sleep(until:clock: continuous)`
    /// fires with `slept` = the whole nap, and a latched tick that returns early
    /// CONSUMES that diff. No later tick would ever see `wokeUp`, so manual
    /// would never be re-asserted and `curveTargets` never cleared.
    private var pendingWake = false
    /// Read by ``FanWriteSequencer``'s abandon hook from its own actor.
    private let abandonWrites = AbandonFlag()
    private static let tickDuration = Duration.seconds(HelperConstants.tickInterval)

    /// A `Bool` the write sequencer can read without hopping onto this actor.
    ///
    /// ``sleepLatch`` is actor-isolated and the sequencer's abandon hook is a
    /// synchronous `@Sendable` closure with no way back in. One lock-guarded box
    /// is the whole bridge.
    private final class AbandonFlag: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        var isSet: Bool {
            lock.withLock { $0 }
        }

        func set(_ new: Bool) {
            lock.withLock { $0 = new }
        }
    }

    /// - Parameters:
    ///   - port: the SMC surface. The real daemon passes `SMCWritePort` (the
    ///     only IOKit writer in the system, which lives in the helper target);
    ///     tests pass a scripted fake firmware.
    ///   - store: persistence for the boot promise. Injected for the same reason.
    ///   - sleep: injected so tests do not actually wait out revert retries.
    /// - Parameter capabilities: reads the live system power capability bits.
    ///   Deliberately has NO default: a default is a value some future caller
    ///   forgets to override, and the value it would have to be is "full wake",
    ///   which is precisely the bug this parameter exists to prevent.
    public init(
        port: any SMCControlPort,
        store: any FanConfigStoring,
        capabilities: @escaping @Sendable () -> PowerCapabilities?,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.port = port
        self.store = store
        self.capabilities = capabilities
        self.sleep = sleep
        // The injected `sleep` reaches the sequencer for the first time here.
        // Production behaviour is identical (both defaults are `Task.sleep`); it
        // exists so a future ftst-branch `DaemonCoreTests` case is instant.
        let flag = abandonWrites
        sequencer = FanWriteSequencer(port: port, sleep: sleep, shouldAbandon: { flag.isSet })
    }

    private let sleep: @Sendable (Duration) async -> Void
    /// Reads the live system power capabilities, or nil when neither source
    /// answers. Injected for the same reason `port` is: IceCubeKit must not
    /// import IOKit, and the rule that consumes this is the rule that has to be
    /// exercised against the exact values the owner's machine produced —
    /// `0x79 [CDNPB]` for the dark wake that spun the fans, `0x1F [CDNVA]` for
    /// the lid-open wake 69 seconds later.
    private let capabilities: @Sendable () -> PowerCapabilities?

    // MARK: - Lifecycle

    /// SAFETY (§4.3): the daemon starts by reverting everything to auto —
    /// whatever a crash or power loss left behind is wiped clean — then runs
    /// the tick forever.
    public func start() async {
        let caps = capabilities()
        // One line, every start: if a future macOS moves the symbol AND renames
        // the registry property, the whole dark-wake gate degrades to "cannot
        // tell", and that should be discoverable on day one rather than on the
        // first night the fans stay quiet when they should not have.
        record("power capabilities at start: \(PowerCapabilities.describe(caps))")
        if let persisted = store.load() {
            // The Phase 4 boot promise: a persisted curve is live before the
            // app ever launches. Anything else starts from clean auto.
            config = persisted
            status.mode = .curve
            status.activeCurve = persisted.sharedCurve
            // The promise is "the persisted curve is live before the app
            // launches" — not "the fans move the instant launchd starts us".
            // launchd KeepAlive, a crash restart and `softwareupdate` all start
            // this daemon, and a maintenance dark wake is exactly when
            // softwareupdate runs, with no willSleep/hasPoweredOn pair for this
            // process to gate on. The intent is loaded and reported either way;
            // only the first write waits for a display.
            //
            // Only a CONFIRMED dark wake holds. An unreadable capability keeps
            // the previous behaviour on purpose: on a Mac whose display bit we
            // cannot read, "hold until proven awake" could mean "never".
            if WakeClassifier.classify(caps) == .darkWake {
                sleepLatch.startParkedInDarkWake()
                record("boot: the persisted curve is loaded, but this is a dark wake — the fans stay with the firmware")
            } else {
                record("boot: resuming persisted curve config")
                await runCurveTick()
            }
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
        // Parked: the fans are already with macOS — the strongest form of what
        // this invariant asks for — and `keepFansSpinning` would take them
        // straight back, into the sleep this exists to prevent. The watchdog
        // re-evaluates on the first tick after the wake, which is the real
        // backstop. Recorded in PLAN.md §4.3.6 as an explicit part of the
        // contract, not left as an emergent property of a guard.
        guard !sleepLatch.isAsleep else {
            record("the app went away while the Mac is parked for sleep — the fans stay with macOS")
            return
        }
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

    // MARK: - The sleep half of the power contract (PLAN.md §4.3.6)

    /// `kIOMessageSystemWillSleep`: hand the fans back to the firmware before
    /// the machine loses the ability to be told anything.
    ///
    /// On Apple Silicon the SMC keeps honouring `F{i}Md = 1` with `F{i}Tg` at
    /// whatever we last commanded, and nothing of ours runs while the machine
    /// sleeps — so the watchdog, the ceiling and the tick are all inert. The
    /// owner's own log: `curve engaged` 18:16:39, `Clamshell Sleep` 18:21:47,
    /// then not one daemon line until 18:38:20, when an unrelated 2-second
    /// Power Nap dark wake finally ran a tick. 994 seconds of forced fans.
    ///
    /// PLAN.md §3.4 assumed the firmware would drop control for us by resetting
    /// `Ftst` across sleep. `Ftst` **does not exist on Mac14,9** (2169 keys,
    /// dumped with `icecube-diag --json`), and clearing an unlock flag would not
    /// clear an already-set mode latch in any case.
    ///
    /// Must return promptly: the caller acknowledges IOKit on completion or on
    /// ``SleepPolicy/acknowledgementBudget``, whichever comes first.
    public func prepareForSleep() async {
        // Latched and flagged BEFORE the first suspension, so no new engage can
        // start behind us and any sequence already inside the sequencer
        // abandons at its next checkpoint.
        let isNewSleep = sleepLatch.willSleep()
        abandonWrites.set(true)
        // Cleared on EVERY will-sleep, including the repeats a dark-wake cycle
        // fires, so a power-on edge observed during one dark wake can never be
        // spent on the next one. Before the `parkLanded` early return below,
        // which is the path a dark wake → sleep actually takes.
        pendingPowerOn = false
        darkWakeHoldRecorded = false
        if isNewSleep {
            record("the Mac is going to sleep — handing the fans back (keeping the \(config.mode.rawValue) config)")
            if coolingOverride {
                // Honest, and deliberately not a veto: a fan daemon must never
                // stop the user's Mac going to sleep. The SoC stops producing
                // heat in a moment and the firmware owns cooling from here,
                // which is what happens on every Mac with no fan app installed.
                record(
                    "SAFETY: parking for sleep while the temperature ceiling is active — the firmware owns cooling now"
                )
            }
        } else if sleepLatch.parkLanded {
            // Dark wake → sleep again fires this repeatedly. The hardware is
            // already parked; re-running `revertAllAuto` would push a `Tg`
            // command at fans that are already stopped, ten times a night.
            return
        }
        await sleepLatch.noteParkLanded(parkHardware())
    }

    /// `kIOMessageSystemHasPoweredOn` — the wake EDGE, not the wake CLASS.
    ///
    /// See ``SystemPowerMessage/systemHasPoweredOn`` for the log evidence that
    /// this is suppressed on a pure dark wake and delivered on a
    /// DarkWake→FullWake promotion. The daemon no longer depends on either
    /// fact: the capability read decides, and this only says when to ask.
    public func systemDidPowerOn() {
        guard sleepLatch.isAsleep else { return }
        pendingPowerOn = true
        unparkIfProvenAwake(reason: "the system powered on", capabilities: capabilities())
    }

    /// The one gate the whole dark-wake fix hangs on: the latch may drop only
    /// when a display is actually powered.
    ///
    /// A necessary condition, never a sufficient one. Every caller still brings
    /// its own evidence that a wake happened — the power-on edge, a heartbeat
    /// after a measured nap, the missed-wake failsafe — because "video is up"
    /// on its own is also true in the window between the lid closing and the
    /// power dropping, and unparking THERE is the original 994-second bug: no
    /// second `systemWillSleep` would arrive to park us again.
    ///
    /// - Returns: whether the latch actually dropped.
    @discardableResult
    private func unparkIfProvenAwake(reason: String, capabilities caps: PowerCapabilities?) -> Bool {
        guard sleepLatch.isAsleep else { return false }
        guard WakeClassifier.classify(caps) == .fullWake else {
            recordDarkWakeHold(refused: reason, capabilities: caps)
            return false
        }
        // The capability value goes in the log line so it can be lined up
        // against `pmset -g log`'s own bracket for the same second.
        unpark(reason: "\(reason) — \(PowerCapabilities.describe(caps))")
        return true
    }

    /// One line per dark wake, not one per tick: a maintenance dark wake runs
    /// for minutes, and this is the line to grep for to see the fix working.
    private func recordDarkWakeHold(refused reason: String, capabilities caps: PowerCapabilities?) {
        guard !darkWakeHoldRecorded else { return }
        darkWakeHoldRecorded = true
        record(
            "dark wake (\(PowerCapabilities.describe(caps))) — \(reason), but no display is powered, so the fans stay with the firmware"
        )
    }

    /// Hands the FANS back to the firmware without touching a single piece of
    /// daemon state.
    ///
    /// The deliberate opposite of ``revertEverything(reason:clearsPersistence:)``,
    /// and the distinction is the whole fix. A revert means "the user's intent
    /// is over": `config = .auto`, followers and curveTargets dropped, guardian
    /// and monitor reset, and — on its default `clearsPersistence: true` — the
    /// persisted curve DELETED. A pre-sleep `revertEverything` would therefore
    /// make every lid close silently uninstall the user's fan control, with
    /// nothing to put it back (``handleWake()``'s `.auto` case is `break`,
    /// `store.load()` runs only in ``start()``, and the app's
    /// `autoResumeIfNeeded()` latches once per session). Worse, `config == .auto`
    /// immediately arms ``autoSafetyNet()``, whose keep-spinning rung has
    /// `floorDebounceTicks = 1` — no debounce at all — so the fans would be
    /// re-forced within one 2 s tick, at up to 50 % of range. The machine would
    /// go to sleep LOUDER.
    ///
    /// A park means "the hardware is about to lose power". `config`, the
    /// followers, the persisted curve and the SafetyMonitor's ceiling
    /// hysteresis all survive it, so the ordinary wake path re-establishes
    /// control with no new machinery.
    ///
    /// - Returns: whether the hand-back actually reached the hardware.
    private func parkHardware() async -> Bool {
        // N engages can all discover the park at once (`revertUnlessParked`);
        // one hand-back is enough, and the actor guarantees this check and set
        // are not interleaved.
        guard !parkInFlight else { return sleepLatch.parkLanded }
        parkInFlight = true
        defer { parkInFlight = false }

        let started = ContinuousClock().now
        guard let fans = try? await readFans() else {
            record("SAFETY: could not read the fans to park them for sleep — they may still be forced")
            return false
        }
        // Read-based, NOT config-based. ``FanGuardian`` forces the fans while
        // `config.mode == .auto` (autoSafetyNet's `.engage`/`.holdAtFloor`, and
        // `keepFansSpinning` on app quit), so a park gated on the config would
        // miss a user who never picked a preset at all.
        let believesInControl = config.mode != .auto || guardian.isActive || revertPending
        let toPark = believesInControl ? fans : fans.filter { $0.mode == .forced }
        // Its remembered `targets` describe hardware that no longer exists, and
        // `isActive` would otherwise make the popover claim "Automatic · cooling"
        // about a sleeping Mac.
        guardian.reset()
        status.guardianActive = false
        guard !toPark.isEmpty else {
            // Do NOT write. `revertAllAuto` parks `F{i}Tg` at `F{i}Mn` first,
            // which is a SPIN command, and its justification ("if the firmware
            // keeps honoring it, the floor spins — never silence") is a
            // waking-machine argument that inverts on a sleeping one.
            record("sleep: nothing of ours is on the fans — leaving them to the firmware")
            return true
        }
        let parked = await asRevert { () async -> Bool in
            do {
                try await self.withWriteLock { try await self.sequencer.revertAllAuto(fans: toPark) }
                return true
            } catch {
                self.record(
                    "SAFETY: parking the fans for sleep failed (\(error.localizedDescription)) — they may still be forced"
                )
                return false
            }
        }
        // Kept from `revertEverything`: thermalmonitord reliably resumes only
        // once the writer's connection is gone (field-observed on Mac14,9).
        await resetPort()
        if parked {
            record("fans parked for sleep in \(ContinuousClock().now - started) (config kept: \(config.mode.rawValue))")
        }
        return parked
    }

    /// Releases the latch and forgets everything that described the pre-sleep
    /// hardware. The single place the latch ever drops.
    private func unpark(reason: String) {
        guard sleepLatch.release() else { return }
        abandonWrites.set(false)
        pendingWake = true
        // The hardware is on macOS auto. Remembered curve targets would make
        // `runCurveTick` take the verify branch and read our OWN hand-back as a
        // read-back mismatch, burning a `verifyFailures` strike toward a
        // spurious revert; a `CurveFollower` would carry hysteresis and ramp
        // state across an eight-hour gap. Cleared as a pair, like every other
        // transition in this file.
        followers = [:]
        curveTargets = [:]
        verifyFailures = 0
        pendingPowerOn = false
        darkWakeHoldRecorded = false
        guardian.reset()
        status.guardianActive = false
        record("wake: resuming \(config.mode.rawValue) control (\(reason))")
    }

    /// ``revertEverything(reason:clearsPersistence:)``, unless we are parked —
    /// in which case the hardware is what needs handing back, and only the
    /// hardware.
    ///
    /// SAFETY, and this is the single most important guard in the change:
    /// ``engage(targets:fans:since:)`` reaches `revertEverything` from TWO
    /// places its own pre-checks cannot cover — the mid-sequence `catch` and the
    /// post-write race guard — both of which run AFTER the writes have started.
    /// An SMC write failing as the machine quiesces at lid close is not exotic;
    /// it is the single most likely moment for one. Without this, a lid close
    /// that races a curve tick would delete the user's persisted curve from
    /// `/Library/Application Support/IceCube`, breaking the Phase 4 boot promise
    /// across the next reboot too.
    private func revertUnlessParked(reason: String) async {
        guard sleepLatch.isAsleep else {
            await revertEverything(reason: reason)
            return
        }
        record("\(reason) — but the Mac is parked for sleep, so the config is kept and the fans stay with macOS")
        await sleepLatch.noteParkLanded(parkHardware())
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
    private func asRevert<T>(_ body: () async -> T) async -> T {
        _ = writeIntent.issue()
        revertGeneration &+= 1
        revertsInFlight += 1
        defer { revertsInFlight -= 1 }
        return await body()
    }

    // MARK: - Serializing the write sequences themselves

    /// Which fan-write decision is current. See ``WriteIntentLedger`` — the
    /// rule lives there so it can be tested without staging a race.
    private var writeIntent = WriteIntentLedger()
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

    /// Puts the daemon into `newConfig` — the app's main entry point, and the
    /// only way a user-chosen mode reaches the hardware.
    ///
    /// - Throws: when the config is unusable (a curve with no usable points) or
    ///   the firmware refuses the write sequence. On a throw the fans are left
    ///   reverted, never half-applied.
    public func apply(_ newConfig: FanConfig) async throws {
        // Not a silent success: `HelperService.apply` would reply `nil` and the
        // popover would show a config the hardware is not in, indefinitely.
        guard !sleepLatch.isAsleep else { throw IceCubeError.systemAsleep }
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
    /// The firmware's own words the last time a write sequence threw.
    ///
    /// Kept so a report can quote it rather than paraphrase — "rejected the
    /// operation on key 'F1Md' (result 0x84)" tells a maintainer what to fix;
    /// "write failed" does not.
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
        guard !sleepLatch.isAsleep else {
            return WritePathReport(verdict: .unavailable, detail: "The Mac is going to sleep.")
        }
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

    /// Releases the fans and stops driving them — the daemon side of Settings →
    /// "Turn Off Fan Control".
    ///
    /// Deliberately does NOT call `keepFansSpinning`, unlike `apply(.auto)`.
    /// That distinction is the whole point: a hand-back the user *chose* while
    /// still wanting the app around should not leave the fans at a standstill,
    /// but turning the feature **off** has to mean off. Since the macOS preset
    /// was removed this is a user's only way to release the fans, so quietly
    /// re-taking them here would make the setting a lie. Pinned by
    /// `DaemonCoreTests.turningOffReleasesEvenWhenWarm`.
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
        // Parked for sleep: nothing but the temperature ceiling may touch a fan,
        // and even a deferred revert waits until the machine is genuinely awake.
        // Must come before everything else in the tick.
        if sleepLatch.isAsleep, await !parkedTick(slept: slept) {
            return
        }

        // A revert that could not be written earlier outranks everything else:
        // until it lands, the fans may still be physically forced.
        if revertPending {
            await revertEverything(reason: revertPendingReason ?? "retrying deferred revert")
            if revertPending {
                return // still cannot reach the hardware; try again next tick
            }
        }

        // Manual control does NOT survive sleep, so any real nap means re-assert
        // or revert. Measured, not inferred: a slow tick is no longer mistaken
        // for a wake. `pendingWake` carries the edge when the power notification
        // beat the tick to it — a parked tick consumes the whole
        // ContinuousClock−SuspendingClock diff, so without it no later tick
        // would ever see `wokeUp`.
        //
        // Consumed HERE, after the deferred-revert retry, so an early return
        // above cannot swallow the wake edge — and acted on BELOW, inside the
        // `.ok` branch. The app's 5 s heartbeat does not run while the machine
        // sleeps, so on waking the watchdog is *always* about to revert a
        // non-persisting curve — and re-asserting first meant every single wake
        // logged "wake detected — re-asserting curve control" immediately before
        // reverting the thing it had just re-asserted. Wasted SMC writes, and a
        // log that described the opposite of what happened.
        let wokeUp = pendingWake || slept > Self.tickDuration
        pendingWake = false

        let temps = try? await readTemperatures()
        let verdict = monitor.evaluate(
            heartbeatAge: heartbeatAge(), config: config, temperatures: temps
        )
        switch verdict {
        case .ok:
            coolingOverride = false
            if wokeUp {
                await handleWake()
            }
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
            await revertUnlessParked(reason: reason)
        }
        // Mirror the guardian's live state into the reported status so the app
        // can explain "Automatic, but Ice Cube is cooling."
        status.guardianActive = guardian.isActive
    }

    /// One tick while parked for sleep.
    ///
    /// SAFETY: nothing here may write a fan except the temperature ceiling —
    /// every branch of the normal tick ends in a fan write, and a fan write on a
    /// machine that is asleep or dark-waking is the bug the sleep half exists to
    /// prevent. The watchdog, the curve, the guardian and a deferred revert are
    /// all DEFERRED, not disabled: `config` is untouched, so the first tick
    /// after the latch releases still reverts a stale non-persisting curve, with
    /// the real reason in the log.
    ///
    /// - Returns: true when the latch was released and the caller should carry
    ///   on with a normal tick.
    private func parkedTick(slept: Duration) async -> Bool {
        // INVARIANT 3, kept rather than narrowed: the ceiling stays armed.
        // A tick only executes while the CPU is running, so the ticks that reach
        // here are dark wakes and any missed-wake window — precisely when the
        // SoC is live and the fans are in the hands of a thermalmonitord that
        // ``FanGuardian`` documents does not reliably resume.
        let temperatures = try? await readTemperatures()
        if case let .forceMaxCooling(offender) = monitor.evaluateCeiling(temperatures: temperatures) {
            record("SAFETY: over the temperature ceiling while parked for sleep (\(offender)) — taking the fans back")
            // Deliberately NOT gated on the wake class. This is the one release
            // allowed to spin fans inside a closed laptop, because it only
            // fires after the ceiling's debounce — a dark wake that is
            // genuinely cooking the machine is exactly when noise is the cheap
            // option.
            unpark(reason: "the temperature ceiling tripped")
            return true
        }

        // One read per tick, shared by every rule below, so a wake landing
        // mid-tick cannot be classified two different ways within one tick.
        let caps = capabilities()
        let action = sleepLatch.tick(slept: slept, tickInterval: Self.tickDuration)

        // The edge arrived earlier and the display was not up yet — or the
        // message really was delivered on a dark wake, in which case this never
        // fires and the next `systemWillSleep` forgets it.
        if pendingPowerOn, unparkIfProvenAwake(reason: "the system powered on", capabilities: caps) {
            return true
        }
        // A daemon that started inside a dark wake has no edge to wait for and
        // no pre-sleep window to fear: it was never told to park, so a lit
        // display is the whole of the evidence it needs.
        if sleepLatch.origin == .startedInDarkWake,
           unparkIfProvenAwake(reason: "a display came up", capabilities: caps)
        {
            return true
        }
        // FIELD EVIDENCE, 2026-07-31: this is the rule that actually drove both
        // fans to maximum inside a closed laptop for 69 seconds. The comment
        // here used to claim "a heartbeat can only come from the user session,
        // which is not scheduled during a dark wake". It is: the menu-bar app's
        // 5 s timer fires inside any dark wake long enough to reach it, and did,
        // three times in 26 hours (17:02:40 `[CDNP]`, 15:56:05 `[CDNP]`,
        // 00:31:53 `[CDNPB]` — the incident).
        //
        // The nap gate is kept — it still guards the window between the lid
        // closing and the power dropping, where no second `systemWillSleep`
        // would arrive to park us again — but it is no longer the outer wall.
        if sleepLatch.sawNap, let age = heartbeatAge(),
           age <= .seconds(HelperConstants.watchdogTimeout),
           unparkIfProvenAwake(reason: "the app checked in after a nap", capabilities: caps)
        {
            return true
        }

        switch action {
        case .stayParked:
            // Drop the connection the ceiling read above reopened:
            // thermalmonitord reliably resumes only once the writer's connection
            // is gone (see `resetPort()`).
            await resetPort()
            return false
        case .retryPark:
            // A park still IN FLIGHT is not a park that failed. `parkLanded`
            // only turns true when `parkHardware` returns, and the first tick
            // after `prepareForSleep` can easily land inside its suspensions —
            // 9 ms into it on the owner's Mac14,9, between the `F0Tg` and
            // `F0Md` writes of the very hand-back it then declared missing.
            //
            // The hardware was never at risk: `parkInFlight` already collapses
            // concurrent parks to one `revertAllAuto`, and the field log shows
            // a single write sequence. Only the log lied — and a daemon whose
            // every write must be auditable cannot afford a line that says the
            // opposite of what happened. Protocol v19 exists for this class of
            // bug; this was the same mistake in the new sleep path.
            guard !parkInFlight else { return false }
            record("the pre-sleep hand-back never landed — trying again")
            await sleepLatch.noteParkLanded(parkHardware())
            return false
        case .missedWake:
            // The second route to the reported bug: a Time Machine or Spotlight
            // dark wake that simply runs longer than the budget used to unpark
            // and re-engage the curve on a machine in a bag. A confirmed dark
            // wake refuses it outright.
            //
            // The sleep latch is held indefinitely; the boot latch is not. The
            // difference is what we know: a `systemWillSleep` arrived for one
            // and not the other, so a boot latch still ticking five minutes
            // later is more likely a machine whose display bit we are
            // misreading than a laptop in a bag. Bounded beats permanent when
            // the evidence is thin.
            if sleepLatch.origin == .willSleep, WakeClassifier.classify(caps) == .darkWake {
                sleepLatch.deferMissedWake()
                record(
                    "still a dark wake after \(SleepLatch.Limits().missedWakeBudget) (\(PowerCapabilities.describe(caps))) — the missed-wake failsafe stands down"
                )
                await resetPort()
                return false
            }
            record(
                "SAFETY: awake \(SleepLatch.Limits().missedWakeBudget) with no wake notification (\(PowerCapabilities.describe(caps))) — releasing the sleep latch"
            )
            unpark(reason: "no wake notification arrived")
            return true
        case .proceed:
            return true // not latched; unreachable from here
        }
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
            await revertUnlessParked(reason: "read-back verification failed")
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
            await revertUnlessParked(reason: "wake re-assert failed")
        case .curve:
            record("wake detected — re-establishing curve control")
            // Just forget the remembered targets; the curve tick immediately
            // below this call does the fresh engage. Running it here as well
            // meant two full curve evaluations per wake, the first of them
            // against an SMC connection that `resetPort()` had just closed.
            curveTargets = [:]
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
        // SAFETY: never force a fan into, or during, sleep.
        guard !sleepLatch.isAsleep else {
            record("fan write stood down — the Mac is parked for sleep")
            return nil
        }
        // Exclusive for the whole sequence: `engageManual` writes a mode and a
        // target PER FAN, so a second engage slipping between those writes
        // leaves the fans split between two intents. Released before the error
        // path below, which reverts.
        let myIntent = writeIntent.issue()
        let outcome: FanWriteOutcome?
        do {
            outcome = try await withWriteLock {
                // Re-checked INSIDE the lock, which is the only place it means
                // anything: a newer intent may have arrived while this one
                // queued, and writing now would hand the fans to the older of
                // two live decisions.
                guard self.writeIntent.isCurrent(myIntent) else {
                    self.record("stale fan write superseded by a newer one — standing down")
                    return nil
                }
                // …and so is the sleep latch, because this is the only place the
                // ordering is airtight: `parkHardware` queues on this same lock,
                // so whichever sequence goes second owns the hardware — and the
                // hand-back must always be able to be that one.
                guard !self.sleepLatch.isAsleep else {
                    self.record("fan write stood down at the write lock — the Mac is going to sleep")
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
            await revertUnlessParked(reason: "fan write failed mid-sequence")
            return nil
        }
        // Two conditions, covering both orderings: a revert that STARTED after
        // this engage captured its generation, and a revert that was already
        // running when it did (whose writes may still be landing).
        guard generation == revertGeneration, revertsInFlight == 0 else {
            record("SAFETY: fan write raced a revert — reverting again")
            await revertUnlessParked(reason: "write raced a revert")
            return nil
        }
        return outcome
    }

    /// - Parameter clearsPersistence: whether this revert also cancels the boot
    ///   promise. True for every user- or safety-driven revert (the user asked
    ///   for auto, or we lost control); false only for daemon shutdown, where
    ///   the intent should survive the restart.
    private func revertEverything(reason: String, clearsPersistence: Bool = true) async {
        _ = writeIntent.issue()
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
            await revertUnlessParked(reason: "curve read-back verification failed")
        }
    }

    // MARK: - Guardian: Ice Cube cools when macOS won't

    /// True while temperature reads are failing, so a run of blind ticks is
    /// reported as one episode rather than one line each.
    private var guardianIsBlind = false

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
            // Reported once per blind SPELL, not once per blind tick. These
            // failures come in runs — `resetPort()` closes the connection on
            // every hand-back and on wake, and everything that reads then
            // misses until it reopens. One wake produced six identical lines
            // describing a single 40-second reconnect, which reads as six
            // separate faults. The recovery below is what says it ended.
            if !guardianIsBlind {
                guardianIsBlind = true
                record("guardian: temperature read failed — holding previous decision")
            }
            return
        }

        if guardianIsBlind {
            guardianIsBlind = false
            record("guardian: temperatures readable again")
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
    /// Whether this Mac HAS `key` — the daemon's half of ``SensorAdmission``.
    ///
    /// Deliberately NOT `port.hasKey`: that is `(try? keyInfo) != nil`, which
    /// collapses "the firmware says there is no such key" into the same `false`
    /// as "the call failed", and the empty-probe rule below exists precisely
    /// because those two are different facts — one is a property of the model,
    /// the other is a connection that `start()`'s `port.reset()` just closed.
    /// `hasKey` also reports no wire type, so it cannot refuse a key that
    /// exists but decodes to nothing; such a key would throw on every tick,
    /// count as missing on every tick, and re-trip the partial-failure re-probe
    /// forever. That is where the old dead-key loop hazard would have moved.
    ///
    /// One read answers both, in its error. **The value is discarded.** Looking
    /// at it is what made discovery a lottery.
    private func probeExists(_ key: String, retryBudget: inout Int) async -> Bool {
        while true {
            do {
                _ = try await port.readDouble(key)
                return true // it answered with a number; that is all we asked
            } catch IceCubeError.smcKeyNotFound {
                return false // a stable property of this model
            } catch IceCubeError.smcDecodingFailed {
                return false // exists, but carries no temperature we can decode
            } catch {
                // Transport failure: not an answer about the hardware. Retry —
                // the one thing a retry was ever good for here — and once the
                // budget is gone leave the key out and let the empty-probe and
                // die-sensor rules judge the truncated set. The next probe
                // reconsiders it.
                guard retryBudget > 0 else { return false }
                retryBudget -= 1
                await sleep(.milliseconds(60))
            }
        }
    }

    /// Transport retries shared by one whole discovery pass. Three, matching
    /// ``readRetries``; bounded so probing the fallback superset on a dead
    /// connection costs milliseconds rather than most of a tick.
    private static let probeRetryBudget = 3

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
            // Membership comes from key EXISTENCE, never from a reading — the
            // same rule the app side uses (`SensorAdmission`), for the same
            // measured reason. On Apple Silicon a power-gated CPU cluster
            // returns a frozen firmware sentinel (Mac14,9: exactly 6.70 °C and
            // 4.63 °C, a whole cluster at a time, P-cluster gated at 66.9 % of
            // idle instants), so admitting on a plausible read disowned every
            // P-core for the life of the daemon. The owner's daemon logged
            // `resolved 8 temperature sensors` — 8 of 20, its only silicon
            // input the two GPU dies, while the 104 °C die ceiling is the one
            // release allowed to spin fans inside a closed lid. Retrying cannot
            // fix it: an immediate retry recovered 0 of 18 misses, and so did
            // +5 ms and +50 ms, because the key is not failing — it is
            // answering with a lie. Gate episodes last 1.1–84.8 s; a 2 s tick
            // cannot wait one out.
            //
            // The probe is a READ WHOSE VALUE IS DISCARDED. `SMCControlPort`
            // has no key-info call and must not grow one, but `readDouble`
            // already answers the only two questions membership turns on, in
            // its error rather than its result — see `probeExists`.
            var existing: Set<String> = []
            existing.reserveCapacity(candidates.count)
            // ONE retry budget for the whole probe, not one per candidate: a
            // reopen after `port.reset()` is retried once, not forty times, and
            // a dead connection cannot spend the whole 2 s tick sleeping.
            var retryBudget = Self.probeRetryBudget
            for sensor in candidates where await probeExists(sensor.key, retryBudget: &retryBudget) {
                existing.insert(sensor.key)
            }
            let present = SensorAdmission
                .admit(candidates: candidates, presentKeys: existing)
                .map(\.key)
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
