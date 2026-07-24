// PresetHighlightTests.swift — the active-preset highlight reconciliation, incl. the sleep/wake revert bug.

@testable import IceCubeKit
import Testing

@Suite("PresetHighlight")
struct PresetHighlightTests {
    @Test("Lid close/open: a non-persistent curve the daemon reverted to auto highlights Auto, not nothing")
    func nonPersistentCurveRevertedOverSleep() {
        // Before the lid closed, the app believed Cold (non-persistent) was
        // active. During sleep the daemon reverted it to auto. The reconciled
        // highlight MUST be Auto — the old code kept the stale curve, which
        // matched neither the curve preset nor Auto, so no button lit up.
        let cold = FanConfig.curve(.cold, persists: false)
        let result = PresetHighlight.reconcile(
            daemonMode: .auto, current: cold, storedCurve: cold, manualTargets: [:]
        )
        #expect(result == .auto)
    }

    @Test("A Keep-Running curve that survives sleep keeps its own preset highlighted")
    func persistentCurveKept() {
        let cold = FanConfig.curve(.cold, persists: true)
        let result = PresetHighlight.reconcile(
            daemonMode: .curve, current: cold, storedCurve: cold, manualTargets: [:]
        )
        #expect(result == cold)
    }

    @Test("Boot-persisted curve with no app memory restores from the saved curve")
    func restoresFromStoredCurve() {
        let balanced = FanConfig.curve(.balanced, persists: true)
        let result = PresetHighlight.reconcile(
            daemonMode: .curve, current: nil, storedCurve: balanced, manualTargets: [:]
        )
        #expect(result == balanced)
    }

    @Test("Auto stays Auto — idempotent, no churn")
    func autoIsStable() {
        let result = PresetHighlight.reconcile(
            daemonMode: .auto, current: .auto, storedCurve: nil, manualTargets: [:]
        )
        #expect(result == .auto)
    }

    @Test("Manual is reflected (no preset lights) rather than leaving a stale curve")
    func manualReflected() {
        let result = PresetHighlight.reconcile(
            daemonMode: .manual,
            current: FanConfig.curve(.cold, persists: false),
            storedCurve: nil,
            manualTargets: [0: 3000]
        )
        #expect(result?.mode == .manual)
    }
}
