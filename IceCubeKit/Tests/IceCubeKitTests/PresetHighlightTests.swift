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

    // MARK: - matches / matching

    private var builtins: [Preset] {
        [
            Preset(name: "Quiet", kind: .quiet, config: .curve(.quiet)),
            Preset(name: "Cold", kind: .cold, config: .curve(.cold)),
        ]
    }

    @Test("A preset matches the config it represents, and only that one")
    func matchesItsOwnConfig() {
        let cold = Preset(name: "Cold", kind: .cold, config: .curve(.cold))
        let quiet = Preset(name: "Quiet", kind: .quiet, config: .curve(.quiet))
        #expect(PresetHighlight.matches(cold, applied: .curve(.cold)))
        #expect(PresetHighlight.matches(quiet, applied: .curve(.cold)) == false)
    }

    @Test("The persist flag is not part of a preset's identity")
    func persistFlagIgnored() {
        let cold = Preset(name: "Cold", kind: .cold, config: .curve(.cold, persists: false))
        // Clicking a preset stamps the app-wide persist setting onto the config;
        // that must not stop the button from highlighting.
        #expect(PresetHighlight.matches(cold, applied: .curve(.cold, persists: true)))
    }

    @Test("Nothing matches when no config has been applied yet")
    func noAppliedConfig() {
        #expect(PresetHighlight.matches(builtins[0], applied: nil) == false)
        #expect(PresetHighlight.matching(builtins, applied: nil) == nil)
    }

    @Test("matching finds the built-in by kind, and reports nil for a user curve")
    func matchingByKind() {
        #expect(PresetHighlight.matching(builtins, applied: .curve(.cold))?.kind == .cold)
        // Auto is no longer any preset's config, so it must light up none of
        // them — it is a daemon resting state, not something the user picked.
        #expect(PresetHighlight.matching(builtins, applied: .auto) == nil)
        // An edited/user curve is no built-in — the picker shows "Custom".
        let edited = FanCurve(points: [
            CurvePoint(celsius: 40, fraction: 0.1),
            CurvePoint(celsius: 90, fraction: 0.9),
        ])
        #expect(PresetHighlight.matching(builtins, applied: .curve(edited)) == nil)
        // Manual mode matches no preset either.
        #expect(PresetHighlight.matching(
            builtins, applied: FanConfig(mode: .manual, manualTargets: [0: 3000])
        ) == nil)
    }
}
