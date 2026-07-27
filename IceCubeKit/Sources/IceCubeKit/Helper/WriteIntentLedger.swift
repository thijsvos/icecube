// WriteIntentLedger.swift — "the newest decision wins", extracted so the rule can be tested without a race.

import Foundation

/// Decides which of several competing fan-write decisions is still the current
/// one (PLAN.md §4.3, the write-race guards).
///
/// Two mechanisms keep the daemon's writes from fighting each other, and they
/// protect against different failures:
///
/// - ``DaemonCore``'s write lock stops two sequences **interleaving**, so the
///   fans can never be split between two intents mid-sequence.
/// - This ledger stops a stale sequence **winning**. Non-interleaving alone does
///   not prevent an older *complete* sequence landing after a newer one — which
///   is the bug seen on a Mac14,9: the guardian's floor-hold engage (2317 RPM)
///   landing after a curve engage (3400), leaving the fans at the floor while
///   the daemon believed the curve.
///
/// **Why this is a separate type.** The behaviour it encodes is a race, and a
/// race is exactly what a test cannot reliably stage: three attempts to arrange
/// the interleave from outside `DaemonCore` produced a test that passed and
/// failed on alternate runs, which is worse than no test at all. Pulling the
/// *rule* out leaves something with no concurrency in it, testable exhaustively
/// and instantly, and reduces the part that still cannot be tested to three
/// obvious lines at the call site.
struct WriteIntentLedger: Sendable, Equatable {
    private var latest = 0

    /// Records a new decision and returns its ticket. Every would-be writer
    /// takes one *before* queuing for the lock.
    mutating func issue() -> Int {
        // Wrapping on purpose. A non-wrapping `+=` would trap, and a daemon
        // that crashes on its 2^63rd fan write is worse than one that reuses a
        // ticket after more writes than a Mac will perform in its lifetime.
        latest &+= 1
        return latest
    }

    /// Whether `ticket` is still the newest decision — checked *inside* the
    /// lock, which is the only place the answer means anything. A writer that
    /// queued while a newer decision arrived must stand down rather than
    /// commit an intent the daemon has already moved on from.
    func isCurrent(_ ticket: Int) -> Bool {
        ticket == latest
    }
}
