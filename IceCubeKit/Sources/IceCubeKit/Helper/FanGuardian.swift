// FanGuardian.swift — decides when Ice Cube must cool the Mac itself under auto (pure, no hardware).

import Foundation

/// FIELD FINDING (2026-07-23, Mac14,9 / macOS 26.4.1): after any fan app
/// touches the SMC, macOS's own fan management does NOT reliably resume — we
/// observed die temperatures climbing through 78…92 °C with the fans parked and
/// macOS never intervening, mode 3 notwithstanding. "Hand back and hope" is
/// therefore not a safety strategy. Whenever the config is auto and the machine
/// is warm while nothing spins, the daemon drives the fans itself along a
/// built-in curve (the fan floor up to 70 °C, then ramping to maximum by 95 °C)
/// and releases once the die is truly cool.
///
/// The engage floor was lowered 75 -> 68 °C on 2026-07-26: macOS was observed
/// holding BOTH fans at 0 RPM with the die at 69.9 °C, which the old threshold
/// deliberately ignored. See ``Limits/engageCelsius`` for why a lower floor
/// cannot turn this into a second curve.
///
/// There are three rungs, not one, and the newest two are the ones a reader
/// meets first:
///
/// - ``handBack(fans:dieCelsius:)`` — consulted at the *instant* the daemon
///   gives the fans up. On a warm machine it keeps them at their floor rather
///   than letting them stop, because a fan restarted from a standstill needs
///   4.4 s where one already turning needs about one, and no amount of drive
///   shortens that. The tick cannot make this call: the fans reach a standstill
///   in ~2.5 s, faster than a 2 s tick reliably reacts.
/// - The **floor hold** in ``evaluate(fans:dieCelsius:)`` — the backstop for
///   fans that stopped some other way. Deliberately matches any non-forced
///   mode, not just SMC mode 0: our own hand-back writes mode 3, so the old
///   orphan ladder never saw the fans macOS declined to reclaim.
/// - The **built-in curve** — the original rung, for a machine that is getting
///   genuinely hot while nothing cools it.
///
/// Pure decision engine, shaped exactly like ``SafetyMonitor``: readings in, an
/// action out, no I/O and no clock — so every rung of the escalation ladder is
/// unit-testable without a hot Mac. ``DaemonCore`` keeps the hardware writes.
public struct FanGuardian: Sendable {
    /// What the daemon should do this tick. The daemon performs the I/O; every
    /// state decision has already been made here.
    public enum Action: Sendable, Equatable {
        /// Nothing to do.
        case idle
        /// Drive (or re-aim) the fans along the built-in curve.
        case engage(targets: [Int: Double], dieCelsius: Double)
        /// Cooled down: hand the fans back and reset the SMC connection.
        case release(dieCelsius: Double)
        /// Gentle ladder stage 1: re-park these fans and hand control back.
        case reparkOrphans([Fan])
        /// Gentle ladder stage 2: the system never resumed — hold the floor.
        case holdAtFloor(targets: [Int: Double])
    }

    /// Tunables, overridable in tests only — release code uses the defaults.
    public struct Limits: Sendable {
        /// Guardian considers engaging at this die temperature…
        ///
        /// Lowered from 75 on 2026-07-26 after observing the exact failure this
        /// exists to catch, just under the old line: macOS holding BOTH fans at
        /// 0 RPM with the die at 69.9 °C. The guardian sat it out by design and
        /// the machine simply stayed hot.
        ///
        /// Safe to lower because temperature is only half the test. Engaging
        /// also needs `nobodyCooling`, which requires a fan to trail demand by
        /// `coolingSlackRPM`; demand below 70 °C is just the fan floor, so this
        /// can only fire when the fans are essentially STOPPED. A macOS that is
        /// genuinely cooling — at any speed within 400 RPM of the floor — is
        /// never overridden. This is a floor for "nobody is cooling a warm
        /// machine", not a second curve.
        public var engageCelsius: Double = 68
        /// …and releases below this one (wide hysteresis, no flapping).
        ///
        /// Kept 10 °C below engage, as before. The gap is what stops the
        /// guardian handing back the moment it has helped and then immediately
        /// re-engaging.
        public var releaseCelsius: Double = 58
        /// Above this die temperature the fans are never left fully stopped.
        ///
        /// Measured on a Mac14,9: a STOPPED fan given a target reads 0 RPM for
        /// 1.5 s and needs 4.4 s to reach speed, and that ramp is
        /// firmware-paced — commanding 6800 instead of 4250 produces an
        /// identical curve, so it cannot be hurried. A fan already turning at
        /// its floor covers the same ground in about a second.
        ///
        /// So the fix is not to make the ramp faster; it is not to start from
        /// rest. Which matters wherever the daemon lands in `.auto` — the app
        /// quitting, or a safety revert — because the next thing to happen is
        /// usually the app reconnecting and asking for a curve again, and that
        /// request should not be paying for a standing start.
        ///
        /// (This was originally written about a user-facing "macOS" preset that
        /// handed the fans back on demand. That preset was removed on
        /// 2026-07-26 — nobody installs a fan-control app to stop controlling
        /// their fans — but every path that reaches `.auto` still benefits, and
        /// the measurement above is unchanged.)
        ///
        /// Holding the floor on a warm machine is also simply what the guardian
        /// is for: macOS parking the fans while the die sits in the sixties is
        /// the behaviour this app exists to correct.
        public var keepSpinningCelsius: Double = 55
        /// …and the fans may stop again below this (wide hysteresis).
        public var keepSpinningReleaseCelsius: Double = 45
        /// How hard a *stopped* fan is driven to get it turning, as a fraction
        /// of its range, before it settles back to the floor on the next tick.
        ///
        /// Not a repeat of the v7 "breakaway" that v8 removed. That one pushed
        /// 6800 instead of 4250 and measured an identical ramp — both are firm
        /// drive, so of course it changed nothing. This is the *other* end of
        /// the scale, and there the difference is not subtle: commanded 2317
        /// from a standstill, the fan sat still for 6.5 s; commanded ~4550 it
        /// was turning in 1.5 s. Asking a stopped fan for its own minimum is
        /// asking for barely enough torque to overcome stiction.
        ///
        /// It never gets loud: a tick or two later the fan is most of the way to
        /// its floor, the guardian sees that and re-aims at the floor itself.
        public var breakawayFraction: Double = 0.5
        /// Below this fraction of its own minimum, a fan gets the breakaway
        /// drive rather than the floor; at or above it, the floor is enough.
        ///
        /// Not "stopped", which is what the first version of this tested, and
        /// it was wrong on hardware. Catching a fan mid-coast at 293 RPM and
        /// commanding 2317 — its own minimum — the fan did not recover: it
        /// carried on decaying to a standstill and then sat there 9.4 s before
        /// the firmware got it moving again. A fan far below its minimum needs
        /// more than its minimum, whether or not it has actually stopped yet.
        public var breakawayBelowFractionOfMin: Double = 0.75
        /// Consecutive warm-and-nobody-cooling ticks required to engage.
        public var engageDebounceTicks = 2
        /// Ticks below the floor before the guardian holds the fans itself.
        ///
        /// One, i.e. no debounce, unlike every other ladder here — and that is
        /// the whole point. Handing 4400 RPM back to macOS, the fans reach a
        /// standstill in about four seconds; a two-tick debounce spent all of
        /// it, so the guardian arrived after the stop it exists to prevent.
        /// There is nothing to debounce anyway: a fan nobody is forcing, below
        /// the minimum its own firmware reports, is not a noisy reading.
        public var floorDebounceTicks = 1
        /// Consecutive ticks with a cool orphaned fan before the ladder starts.
        public var orphanDebounceTicks = 3
        /// A fan counts as "not cooling" when it trails demand by this much.
        public var coolingSlackRPM: Double = 400
        /// Below this RPM a fan is considered stopped.
        public var stoppedRPM: Double = 100

        public init() {}
    }

    private let limits: Limits

    /// Everything the guardian remembers, in one value.
    ///
    /// Grouped deliberately: these counters used to be five loose properties on
    /// ``DaemonCore``, and each mode transition reset a different subset — a
    /// revert cleared the engage debounce but left the orphan-ladder counters
    /// stale, so the next orphaned tick could skip the gentle "re-park and hand
    /// back" stage and jump straight to holding the fans. One value means one
    /// reset that cannot be partial.
    private struct State: Sendable, Equatable {
        var isActive = false
        /// Holding the fans at their floor so they are never at a standstill.
        var isHoldingFloor = false
        /// Consecutive warm-and-stopped ticks before the floor hold starts.
        var floorTicks = 0
        var targets: [Int: Double] = [:]
        /// Consecutive warm-and-nobody-cooling ticks (engage debounce).
        var warmTicks = 0
        /// Consecutive ticks with a cool orphaned fan (ladder debounce).
        var orphanTicks = 0
        /// Escalation stage of the gentle ladder.
        var recoveryStage = 0
    }

    private var state = State()

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// True while the guardian is driving the fans — mirrored into
    /// `HelperStatus.guardianActive` so the UI can say "Automatic · cooling".
    ///
    /// Covers the floor hold as well as the curve. Both mean the same thing to
    /// the person reading the popover — Ice Cube, not macOS, is the reason the
    /// fans are turning — and the alternative was a panel that said "macOS is
    /// controlling the fans" while the daemon held them at their minimum.
    public var isActive: Bool {
        state.isActive || state.isHoldingFloor
    }

    /// Forgets every counter. Called on any mode transition, so a stale
    /// debounce can never leak across a revert or a new config.
    public mutating func reset() {
        state = State()
    }

    /// Decides what to do with the fans at the *instant* control is handed back
    /// to macOS, before they have had any time to slow down.
    ///
    /// Separate from ``evaluate(fans:dieCelsius:)`` because timing is the entire
    /// point, and two hardware traces say the tick cannot do this job:
    ///
    /// - Handed back from ~4650 RPM the fans reach a standstill in about 2.5 s.
    ///   The next 2 s tick landed 1.7 s and 3.0 s later on two runs — catching
    ///   the fans at 293 RPM and at 0.
    /// - Neither catch saved them. Commanded its own minimum at 293 RPM the fan
    ///   decayed to a stop anyway; commanded 4600 from a stop it sat still for
    ///   **9.4 s** before moving, exactly as long as the 2317 command did. Once
    ///   a fan has stopped, drive does not buy speed — which is the same lesson
    ///   v8 learned at the other end of the scale.
    ///
    /// So there is no observing this and reacting in time. Either the fans are
    /// never allowed to stop, or the user waits. On a warm machine they are
    /// never allowed to stop — which is also what the guardian is for.
    ///
    /// The threshold here is ``Limits/keepSpinningReleaseCelsius``, NOT the
    /// higher ``Limits/keepSpinningCelsius`` the tick uses, and the difference
    /// is the whole reason the first version of this never fired once in
    /// practice. Leaving a working curve, the die read 52.9 °C — under the
    /// 55 °C bar — with the fans at 3226 RPM holding it there. **The machine is
    /// cool because it is being cooled**, so gating on the temperature at the
    /// moment of hand-back gates on the number you are about to destroy: stop
    /// those fans and the die is in the high sixties within a minute, which is
    /// the exact condition the guardian then engages on anyway.
    ///
    /// The tick keeps the higher bar on purpose. It catches fans that have
    /// *already* stopped, where starting them costs a whole stop-start cycle;
    /// this path catches fans that are still turning, where keeping them costs
    /// nothing. Hold at or above the release line, let go below it — one number
    /// for both directions, so it cannot flap.
    public mutating func handBack(fans: [Fan], dieCelsius: Double) -> Action {
        reset()
        guard dieCelsius >= limits.keepSpinningReleaseCelsius else {
            return .release(dieCelsius: dieCelsius)
        }
        let targets = Self.keepSpinningTargets(for: fans, limits: limits)
        guard !targets.isEmpty else { return .release(dieCelsius: dieCelsius) }
        state.isHoldingFloor = true
        state.targets = targets
        return .holdAtFloor(targets: targets)
    }

    /// Evaluates one auto-mode tick.
    ///
    /// - Parameters:
    ///   - fans: this tick's fan readings.
    ///   - dieCelsius: the hottest die-class reading, in °C. **Never a stand-in
    ///     for a failed read.** 0 is below every threshold here, so a blind tick
    ///     passed as 0 takes the release branch and hands a hot Mac back to the
    ///     `thermalmonitord` this type exists because it does not reliably
    ///     resume — which happened, at 90 °C. `DaemonCore`'s auto tick therefore
    ///     skips this call entirely when the sensors do not answer, and holds the
    ///     previous decision instead. This doc said "or 0 if none could be read"
    ///     until 2026-08-16, which invited exactly that bug back.
    public mutating func evaluate(fans: [Fan], dieCelsius: Double) -> Action {
        if state.isActive {
            guard dieCelsius >= limits.releaseCelsius else {
                state.isActive = false
                state.targets = [:]
                return .release(dieCelsius: dieCelsius)
            }
            let targets = Self.curveTargets(for: fans, dieCelsius: dieCelsius)
            guard targets != state.targets else { return .idle }
            state.targets = targets
            return .engage(targets: targets, dieCelsius: dieCelsius)
        }

        let demand = Self.curveTargets(for: fans, dieCelsius: dieCelsius)

        // Already holding the floor: escalate if it gets hot, let go once cool.
        if state.isHoldingFloor {
            if dieCelsius >= limits.engageCelsius {
                state.isHoldingFloor = false
                state.isActive = true
                state.targets = demand
                return .engage(targets: demand, dieCelsius: dieCelsius)
            }
            if dieCelsius < limits.keepSpinningReleaseCelsius {
                state.isHoldingFloor = false
                state.targets = [:]
                return .release(dieCelsius: dieCelsius)
            }
            // Re-aim only when the answer changed — same no-churn rule as the
            // curve above. In practice this fires exactly once, to drop a fan
            // from its breakaway target to the floor now that it is turning.
            let targets = Self.keepSpinningTargets(for: fans, limits: limits)
            guard targets != state.targets else { return .idle }
            state.targets = targets
            return .holdAtFloor(targets: targets)
        }

        // Engage when warm and nothing is effectively cooling.
        let nobodyCooling = fans.contains { fan in
            fan.mode != .forced && fan.actualRPM + limits.coolingSlackRPM < (demand[fan.id] ?? 0)
        }
        if dieCelsius >= limits.engageCelsius, nobodyCooling {
            state.warmTicks += 1
            guard state.warmTicks >= limits.engageDebounceTicks else { return .idle }
            state.warmTicks = 0
            state.isActive = true
            state.targets = demand
            return .engage(targets: demand, dieCelsius: dieCelsius)
        }
        state.warmTicks = 0

        // KEEP SPINNING: a warm machine never has fully stopped fans.
        //
        // Deliberately matches any non-forced mode, not just mode 0. The
        // hand-back writes mode 0 and then mode 3, so when macOS parks the fans
        // they read `.system` — which the orphan ladder below does not match,
        // which is why they were left at a standstill indefinitely.
        //
        // Holding the floor here is what makes leaving macOS instant: the fan
        // is already turning, so a curve change is a ~1 s adjustment instead of
        // a 4.4 s start from rest that no amount of drive can shorten.
        //
        // The test is "below its own firmware minimum", NOT `stoppedRPM`. A fan
        // handed back at 4300 RPM takes something like fifteen seconds to coast
        // down, and waiting for it to actually reach zero would (a) hand the
        // user the exact standing start this exists to avoid, if they switch
        // back inside that window, and (b) make the fans stop and immediately
        // restart, which is both audible and pointless. Below `Mn` nobody is
        // driving the fan any more — catch it on the way down and hold.
        let coasting = fans.filter {
            $0.minRPM > 0 && $0.mode != .forced && $0.actualRPM < $0.minRPM
        }
        if dieCelsius >= limits.keepSpinningCelsius, !coasting.isEmpty {
            state.floorTicks += 1
            if state.floorTicks >= limits.floorDebounceTicks {
                state.floorTicks = 0
                state.isHoldingFloor = true
                let targets = Self.keepSpinningTargets(for: fans, limits: limits)
                state.targets = targets
                return .holdAtFloor(targets: targets)
            }
            return .idle
        }
        state.floorTicks = 0

        // Cool orphan: mode 0 with stopped fans — always wrong, never urgent.
        let orphaned = fans.filter {
            $0.actualRPM < limits.stoppedRPM && $0.minRPM > 0 && $0.mode == .auto
        }
        guard !orphaned.isEmpty else {
            state.orphanTicks = 0
            state.recoveryStage = 0
            return .idle
        }
        state.orphanTicks += 1
        guard state.orphanTicks >= limits.orphanDebounceTicks else { return .idle }
        state.orphanTicks = 0
        state.recoveryStage += 1
        if state.recoveryStage == 1 {
            return .reparkOrphans(orphaned)
        }
        // Deliberately the plain floor, and deliberately not entering the
        // keep-spinning state: this rung fires on a *cold* machine, where the
        // hold's own release rule would hand the fans straight back and restart
        // the ladder in a loop. Mode-0 orphans are a firmware-refused hand-back,
        // not the everyday macOS path, and they stay handled exactly as before.
        return .holdAtFloor(targets: Self.floorTargets(for: fans))
    }

    /// Every fan's minimum, for holding the floor.
    ///
    /// `uniquingKeysWith` rather than `uniqueKeysWithValues`: the latter TRAPS
    /// on a duplicate fan id. Ids come from `0..<FNum` so a duplicate is not
    /// reachable today, but a trap is a crash, and daemon code paths must never
    /// crash on unexpected firmware data.
    static func floorTargets(for fans: [Fan]) -> [Int: Double] {
        Dictionary(
            fans.lazy.filter { $0.minRPM > 0 }.map { ($0.id, $0.minRPM) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// What to command to keep each fan turning: its own minimum if it is still
    /// turning fast enough to keep itself going, or ``Limits/breakawayFraction``
    /// of its range once it has fallen below
    /// ``Limits/breakawayBelowFractionOfMin`` of that minimum.
    ///
    /// Deliberately NOT "if it is stopped" — that is what the first version
    /// tested, and on hardware a fan caught mid-coast at 293 RPM against a
    /// 2317 RPM floor was handed its own minimum and carried on decaying to a
    /// standstill anyway. The constant's own doc says so; this summary claimed
    /// the repudiated test until 2026-08-16.
    ///
    /// SAFETY: fans without a usable `[Mn, Mx]` are skipped rather than clamped
    /// — the same rule as ``curveTargets``. A 0…0 range maps every fraction to
    /// 0 RPM, the one value Ice Cube must never write.
    static func keepSpinningTargets(for fans: [Fan], limits: Limits) -> [Int: Double] {
        Dictionary(
            fans.lazy.filter(\.hasUsableRange).map { fan in
                let needsHelp = fan.actualRPM < fan.minRPM * limits.breakawayBelowFractionOfMin
                guard needsHelp else { return (fan.id, fan.minRPM) }
                return (fan.id, FanWriteSequencer.quantizedTarget(
                    fraction: limits.breakawayFraction, fan: fan, step: 100
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The built-in guardian curve: 0 below 70 °C, then 20 %…100 % of each
    /// fan's range linearly from 70 to 95 °C. Quantized to 100 RPM steps so
    /// small temperature wiggles don't cause write churn.
    ///
    /// Routed through ``FanWriteSequencer/quantizedTarget(fraction:fan:step:)``
    /// rather than repeating the arithmetic: that helper also clamps back into
    /// `[Mn, Mx]`, which matters because quantizing can round a target *below*
    /// the SMC-reported minimum (on Mac14,9, `Mn` 2317 → 2300). Without the
    /// clamp the guardian would remember a target it never actually wrote.
    /// SAFETY: a fan whose `[Mn, Mx]` range didn't read (both 0) is skipped, not
    /// driven — mapping any fraction into a 0…0 range commands 0 RPM, which is
    /// forbidden everywhere in Ice Cube. ``DaemonCore``'s curve loop has always
    /// guarded this; the guardian's hand-rolled copy of the mapping did not.
    public static func curveTargets(for fans: [Fan], dieCelsius: Double) -> [Int: Double] {
        let fraction: Double = if dieCelsius <= 70 {
            0
        } else {
            min(1.0, 0.2 + 0.8 * (dieCelsius - 70.0) / 25.0)
        }
        return Dictionary(
            fans.lazy.filter(\.hasUsableRange).map { fan in
                (fan.id, FanWriteSequencer.quantizedTarget(fraction: fraction, fan: fan, step: 100))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
