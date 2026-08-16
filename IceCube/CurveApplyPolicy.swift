// CurveApplyPolicy.swift — what the curve editor window does with itself once the daemon answers an Apply.

/// Whether pressing Apply Curve closes the editor, and what it says if it
/// doesn't.
///
/// Closing on success is the point: the window is a workbench, and once the
/// curve is running there is nothing left on it to look at. The disappearance
/// is also the only receipt the editor has — it shows no status of its own, and
/// the daemon's is a menu-bar click away.
///
/// Which is exactly why it must not close on the other two answers. A window
/// that vanishes means "done"; vanishing after a refusal would report success
/// for a curve that is not running, and take the hand-drawn points with it —
/// the same loss `WindowOpener.closableFromMenuBar` keeps ``WindowOpener/ID/curves``
/// out of that set to avoid. So a failure and a sleep-deferral both keep the
/// window, and say which one happened.
///
/// A pure mapping, separate from the view, so all three answers can be pinned
/// by a test: applying a curve needs real hardware (`canApply` is false in
/// simulated mode), so this decision is otherwise only ever exercised on the
/// owner's Mac, one outcome at a time.
enum CurveApplyPolicy {
    /// What the editor does next.
    enum Resolution: Equatable {
        /// The curve is running. Close the window.
        case close
        /// Nothing is running. Keep the window and say so in the warning
        /// register — something went wrong and the user may need to act.
        case failed(String)
        /// Nothing is running *yet*: the Mac is parked and the config is queued
        /// for wake. Not a failure, and deliberately not phrased as one.
        case waiting(String)
    }

    /// What to say when a refusal arrives with no message attached — better
    /// than an empty warning row, which reads as a rendering bug.
    static let unexplainedFailure = "The curve couldn’t be applied. Open the Ice Cube menu for details."

    /// Decides what, if anything, the curve editor should say after an apply.
    ///
    /// - Parameter error: `HelperManager.lastError` as it stands after the
    ///   apply, and only consulted for `.failed`. Worth being precise about what
    ///   the other two answers leave behind, because they are not the same:
    ///   `.ok` clears it (`HelperManager.run` sets `lastError = nil` the moment
    ///   the call returns), while `.deferredUntilWake` leaves whatever was
    ///   already there — a deferral is not a failure, so nothing on that path
    ///   writes the field either way. This function ignores it for both, so the
    ///   difference costs nothing here; it matters to whoever renders the two
    ///   side by side.
    static func resolve(_ outcome: HelperManager.CommandOutcome, error: String?) -> Resolution {
        switch outcome {
        case .ok:
            .close
        case .deferredUntilWake:
            .waiting(HelperManager.wakeNotice)
        case .failed:
            .failed(error.flatMap { $0.isEmpty ? nil : $0 } ?? unexplainedFailure)
        }
    }
}
