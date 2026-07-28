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

    // MARK: - isActive: the daemon outranks the app's memory

    /// THE case this rule exists for. A curve the daemon resumed at boot —
    /// before the app ever launched — leaves `lastAppliedConfig` nil, so a
    /// memory-only check lights nothing while the fans audibly run.
    @Test("A curve the daemon resumed at boot lights its preset with no app memory")
    func daemonEnforcedCurveWinsWithoutAppMemory() throws {
        let cold = try #require(builtins.first { $0.kind == .cold })
        let status = HelperStatus(mode: .curve, activeCurve: cold.config.sharedCurve)
        #expect(PresetHighlight.isActive(cold, enforced: status, applied: nil))
    }

    /// …and it must light the RIGHT one. The daemon naming a curve settles it
    /// outright, so a different preset stays dark even in the same mode.
    @Test("Only the curve the daemon names lights up")
    func daemonNamedCurveIsExclusive() throws {
        let cold = try #require(builtins.first { $0.kind == .cold })
        let quiet = try #require(builtins.first { $0.kind == .quiet })
        let status = HelperStatus(mode: .curve, activeCurve: cold.config.sharedCurve)
        #expect(PresetHighlight.isActive(cold, enforced: status, applied: nil))
        #expect(PresetHighlight.isActive(quiet, enforced: status, applied: nil) == false)
    }

    /// No connection means no claim. Highlighting from stale app memory while
    /// the daemon is unreachable is how the UI ends up asserting a state the
    /// hardware is not in.
    @Test("No daemon status lights nothing, whatever the app remembers")
    func noStatusLightsNothing() throws {
        let cold = try #require(builtins.first { $0.kind == .cold })
        #expect(PresetHighlight.isActive(cold, enforced: nil, applied: cold.config) == false)
    }

    /// A mode disagreement is decisive before any curve comparison happens —
    /// this is what stops a curve preset lighting while the daemon is in manual.
    @Test("A mode mismatch loses regardless of the curve")
    func modeMismatchLoses() throws {
        let cold = try #require(builtins.first { $0.kind == .cold })
        let manual = HelperStatus(mode: .manual, activeCurve: cold.config.sharedCurve)
        #expect(PresetHighlight.isActive(cold, enforced: manual, applied: cold.config) == false)
    }

    /// The fallback path: the daemon says "curve" but names none (an older
    /// protocol, or a status sent before the curve was recorded). The app's own
    /// memory is then the only evidence there is, so it is used.
    @Test("Without a named curve it falls back to what the app sent")
    func fallsBackToAppMemory() throws {
        let cold = try #require(builtins.first { $0.kind == .cold })
        let quiet = try #require(builtins.first { $0.kind == .quiet })
        let unnamed = HelperStatus(mode: .curve, activeCurve: nil)
        #expect(PresetHighlight.isActive(cold, enforced: unnamed, applied: cold.config))
        #expect(PresetHighlight.isActive(quiet, enforced: unnamed, applied: cold.config) == false)
    }
}
