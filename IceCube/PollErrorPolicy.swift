// PollErrorPolicy.swift — whether a failed sensor read is worth telling the user about yet.

import Foundation
import IceCubeKit

/// Decides what a polling failure says on screen, if anything.
///
/// Extracted from `AppState`'s polling loop on 2026-08-08. The rule was sound
/// and entirely untested: `AppState` sat at 0 % coverage because one reference
/// to `StatusItemController` kept the whole file out of the test bundle, so
/// this — the thing that decides whether a user sees an error at all — had
/// never been exercised.
///
/// Pure, so it can be. The counter stays in `AppState`, which owns the tick.
enum PollErrorPolicy {
    /// Consecutive failures tolerated before a transient fault is worth
    /// mentioning.
    ///
    /// The SMC misses a read occasionally on healthy hardware — flashing an
    /// error caption in and out of the layout for one dropped tick is worse
    /// than saying nothing, because it trains the user to ignore the caption.
    static let transientTolerance = 3

    /// Appended to the two faults a user can actually act on: both mean this
    /// Mac's key map is wrong or absent, and a diagnostics report is the only
    /// thing that fixes it.
    static let diagnosticsHint = " Export Diagnostics to help map this Mac."

    /// The message to show, or `nil` to stay quiet.
    ///
    /// Three classes, and the split is about **what the user can do**:
    ///
    /// - `.smcKeyNotFound` / `.smcDecodingFailed` speak immediately. They are
    ///   not transient — this Mac's sensor map is wrong, it will be wrong on
    ///   every subsequent tick, and waiting three of them only delays a message
    ///   that is already certain. They carry the diagnostics hint because a
    ///   report is the fix.
    /// - `.smcNotPrivileged` speaks immediately with no hint. Documented as
    ///   something the app should never see, since reads need no privilege; if
    ///   it happens, the hint would be misleading advice.
    /// - Everything else waits for ``transientTolerance`` consecutive failures.
    ///
    /// - Parameter consecutiveFailures: how many polls have failed in a row,
    ///   **including this one** — so the first failure passes 1.
    static func message(for error: IceCubeError, consecutiveFailures: Int) -> String? {
        switch error {
        case .smcKeyNotFound, .smcDecodingFailed:
            error.localizedDescription + diagnosticsHint
        case .smcNotPrivileged:
            error.localizedDescription
        default:
            consecutiveFailures >= transientTolerance ? error.localizedDescription : nil
        }
    }
}
