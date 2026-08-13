// CurveApplyPolicyTests.swift — the curve editor closes on success and only on success.

import Testing

/// Applying a curve needs real hardware, so this decision cannot be reached in
/// simulated mode at all (`CurveEditorView.canApply` is false there) — which
/// makes it exactly the kind of thing that has to be pinned here instead of
/// found by clicking. The failure this guards against is silent by
/// construction: a window that closes on a refusal looks identical to a window
/// that closed on success.
@Suite("CurveApplyPolicy — when the editor puts itself away")
@MainActor
struct CurveApplyPolicyTests {
    @Test("A curve the daemon accepted closes the window")
    func successCloses() {
        #expect(CurveApplyPolicy.resolve(.ok, error: nil) == .close)
    }

    /// The whole reason this is a policy and not `dismiss()` on the button.
    @Test("A refused curve keeps the window, and says why")
    func failureStaysOpen() {
        let resolution = CurveApplyPolicy.resolve(.failed, error: "Fan 0 is out of range")
        #expect(resolution == .failed("Fan 0 is out of range"))
    }

    /// `HelperManager.run` sets `lastError` from the thrown error, but nothing
    /// guarantees it is non-empty — and an empty warning row reads as a bug in
    /// the app rather than a refusal from the daemon.
    @Test("A refusal with no message still explains itself", arguments: [nil, ""])
    func failureWithoutMessage(error: String?) {
        #expect(
            CurveApplyPolicy.resolve(.failed, error: error)
                == .failed(CurveApplyPolicy.unexplainedFailure)
        )
    }

    /// A parked Mac is not a failure: `HelperManager.apply` queues the config
    /// and re-sends it on wake. Closing here would claim a curve is running
    /// while it sits in a queue; the warning register would claim something
    /// broke.
    @Test("A curve held for a sleeping Mac keeps the window, in the calm register")
    func deferralWaits() {
        #expect(
            CurveApplyPolicy.resolve(.deferredUntilWake, error: nil)
                == .waiting(HelperManager.wakeNotice)
        )
    }

    /// A stale `lastError` from an earlier command must not be dressed up as
    /// this command's answer — the deferral path never sets it.
    @Test("A deferral ignores an error left over from before")
    func deferralIgnoresStaleError() {
        #expect(
            CurveApplyPolicy.resolve(.deferredUntilWake, error: "Registration failed (1)")
                == .waiting(HelperManager.wakeNotice)
        )
    }
}
