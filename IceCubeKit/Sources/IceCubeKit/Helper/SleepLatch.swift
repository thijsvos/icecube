// SleepLatch.swift — the sleep half of the power contract as a pure state machine: park, stay parked, release.

import Foundation

/// Tracks whether the machine is parked for sleep as far as the daemon knows,
/// and decides what a tick may do while it is.
///
/// Pure on purpose, exactly like ``SafetyMonitor`` and ``FanGuardian``: the
/// missed-wake failsafe and the dark-wake accounting are the two rules most
/// likely to rot, and neither can be exercised against a real sleep in CI.
/// ``DaemonCore`` keeps all the I/O.
///
/// Deliberately holds **no `FanConfig`**. `DaemonCore.config` survives a park
/// untouched — that is the whole design — so there is nothing to remember and
/// nothing to restore.
public struct SleepLatch: Sendable, Equatable {
    /// Tunables, overridable in tests only — release code uses the defaults.
    public struct Limits: Sendable, Equatable {
        /// Uninterrupted awake time while latched before we conclude the wake
        /// notification never arrived and release ourselves.
        ///
        /// Measured, not counted in ticks, so it cannot silently rescale if
        /// `HelperConstants.tickInterval` changes. The counter RESETS on every
        /// observed nap, so it really measures "longest single awake run since
        /// the lid closed".
        ///
        /// Five minutes, and generous on purpose: with the temperature ceiling
        /// still armed while parked (see ``DaemonCore``), this failsafe no
        /// longer doubles as thermal protection — it only has to catch a lost
        /// `kIOMessageSystemHasPoweredOn`. Sized against the owner's real
        /// `pmset -g log`, which contains 2 s SleepService dark wakes AND a 45 s
        /// `wifibt` Maintenance dark wake; a Time Machine dark wake runs longer
        /// still, and a false release there costs one audible spin-up that the
        /// next `systemWillSleep` undoes.
        public var missedWakeBudget: Duration = .seconds(300)
        public init() {}
    }

    /// What the tick may do this time round.
    public enum TickAction: Sendable, Equatable {
        /// Not latched: run the tick normally.
        case proceed
        /// Parked, and the hand-back landed: do nothing to the fans.
        case stayParked
        /// Parked, but the pre-sleep hand-back never reached the hardware.
        /// A dark wake is the first chance to fix it — and the fans are
        /// audibly still running until we do.
        case retryPark
        /// Awake far too long with no wake notification. Release and proceed.
        case missedWake
    }

    private struct State: Sendable, Equatable {
        var parkLanded = false
        /// True once a tick has measured a real nap since the lid closed.
        var sawNap = false
        /// Uninterrupted awake time since the last observed nap.
        var awakeSoFar: Duration = .zero
    }

    private var state: State?
    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var isAsleep: Bool {
        state != nil
    }

    public var parkLanded: Bool {
        state?.parkLanded ?? false
    }

    /// True once the machine has demonstrably slept since the latch was set.
    ///
    /// The gate on treating an app heartbeat as evidence of a real wake: a
    /// heartbeat arriving in the window between the lid closing and the power
    /// dropping must NOT unpark us, because no second `systemWillSleep` would
    /// arrive to park us again — that would reproduce the exact bug.
    public var sawNap: Bool {
        state?.sawNap ?? false
    }

    /// - Returns: true when this is a NEW sleep and the fans must be parked now;
    ///   false when already latched (dark wake → sleep again fires
    ///   `systemWillSleep` repeatedly, and re-running a hand-back that already
    ///   landed is pure write churn into a sleeping Mac).
    public mutating func willSleep() -> Bool {
        guard state == nil else { return false }
        state = State()
        return true
    }

    public mutating func noteParkLanded(_ landed: Bool) {
        state?.parkLanded = landed
    }

    /// - Parameters:
    ///   - slept: the tick's ContinuousClock − SuspendingClock diff.
    ///   - tickInterval: the daemon's nominal tick period.
    public mutating func tick(slept: Duration, tickInterval: Duration) -> TickAction {
        guard var current = state else { return .proceed }
        if slept > tickInterval {
            current.sawNap = true
            current.awakeSoFar = .zero
        } else {
            current.awakeSoFar += tickInterval
        }
        state = current
        // NOT released here: ``DaemonCore``'s `unpark(reason:)` is the single
        // place the latch drops, because dropping it also has to clear the
        // sequencer's abandon flag and arm the pending wake.
        if current.awakeSoFar >= limits.missedWakeBudget {
            return .missedWake
        }
        return current.parkLanded ? .stayParked : .retryPark
    }

    /// Releases the latch. - Returns: whether it was actually latched.
    @discardableResult
    public mutating func release() -> Bool {
        defer { state = nil }
        return state != nil
    }
}
