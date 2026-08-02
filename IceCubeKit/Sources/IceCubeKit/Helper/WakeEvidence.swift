// WakeEvidence.swift — what the daemon has been told about a wake, as opposed to what it has proven.

import Foundation

/// The two things `DaemonCore` remembers between ticks while it is parked for
/// sleep: that a power-on message arrived, and that it has already said once
/// that it is holding.
///
/// **It only remembers. It never decides and never acts.** The rule that
/// actually drops the sleep latch lives in `DaemonCore.unparkIfProvenAwake`,
/// and the three predicates that call it keep their order and their call sites
/// — that order is behaviourally load-bearing, because all three lead to the
/// same `unpark` with different `reason` strings, and the first refusal is the
/// one that spends the hold throttle. This type exists to make one thing
/// impossible, not to be clever.
///
/// **The one thing.** Both flags must be cleared together, on every
/// `systemWillSleep` — including the repeats a dark-wake cycle fires — and
/// again whenever the latch drops. They were two independent `Bool`s cleared
/// by two adjacent assignments in two different methods, which is a
/// forget-one-of-them waiting to happen: a `pendingPowerOn` surviving into the
/// next dark wake would spend an edge observed during the previous one, and
/// that is precisely how the fans came on inside a closed laptop for 69
/// seconds on 2026-07-31. ``forgetAcrossSleep()`` is one call that cannot
/// clear half of it.
struct WakeEvidence: Sendable, Equatable {
    /// A `kIOMessageSystemHasPoweredOn` that arrived before any display was up.
    ///
    /// The message and the capability bits are not guaranteed to change in the
    /// same instant, and the message is the only edge there is — a
    /// DarkWake→FullWake promotion does not send a second one. Remembering it
    /// and completing it from the tick is what makes the gate safe in both
    /// directions: a message that races the video bit still unparks within one
    /// tick, and a message genuinely delivered on a dark wake never unparks.
    private(set) var powerOnPending = false

    /// Whether the "staying parked" line has already been logged this spell.
    private var holdRecorded = false

    /// Records the power-on edge. Deliberately not "the machine is awake".
    mutating func notePowerOnEdge() {
        powerOnPending = true
    }

    /// Whether to log the dark-wake hold, and marks it logged.
    ///
    /// One line per dark wake, not one per tick: a maintenance dark wake runs
    /// for minutes at a 2 s tick, and this is the line the owner greps for to
    /// see the gate working. Drowning it in 150 copies of itself would defeat
    /// the purpose it was added for.
    mutating func shouldLogHold() -> Bool {
        defer { holdRecorded = true }
        return !holdRecorded
    }

    /// Forgets everything, as one operation.
    ///
    /// Called on every will-sleep and again when the latch drops. There is
    /// deliberately no way to clear one flag without the other.
    mutating func forgetAcrossSleep() {
        self = WakeEvidence()
    }
}
