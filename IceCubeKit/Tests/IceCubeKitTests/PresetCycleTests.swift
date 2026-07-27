// PresetCycleTests.swift — the quick-switch order, the wrap, and where it starts from an unrecognised state.

import Foundation
@testable import IceCubeKit
import Testing

/// The ⌥-click gesture cannot be unit-tested — it needs a real status item and a
/// real modifier key. So all the deciding lives here, where it can be, and the
/// gesture is left with nothing to get wrong but the plumbing.
@Suite("PresetCycle — what comes next")
struct PresetCycleTests {
    /// Mirrors `PresetStore.builtins`, which lives in the app target. Duplicated
    /// rather than shared because the *order* is the thing under test: if the
    /// app's order changes, this list should have to change too, deliberately.
    private let cycle: [Preset] = [
        Preset(name: "Quiet", kind: .quiet, config: .curve(.quiet)),
        Preset(name: "Balanced", kind: .balanced, config: .curve(.balanced)),
        Preset(name: "Cold", kind: .cold, config: .curve(.cold)),
        Preset(name: "Max", kind: .max, config: .curve(.max)),
    ]

    private func preset(_ kind: Preset.Kind) -> Preset {
        cycle.first { $0.kind == kind }!
    }

    @Test(
        "Each preset advances to the next",
        arguments: [
            (Preset.Kind.quiet, Preset.Kind.balanced),
            (.balanced, .cold),
            (.cold, .max),
        ]
    )
    func advancesInOrder(_ step: (from: Preset.Kind, to: Preset.Kind)) {
        let next = PresetCycle.next(after: preset(step.from).config, in: cycle)
        #expect(next?.kind == step.to)
    }

    /// Without the wrap the gesture is a dead end: a user who reaches Max can
    /// never get back with the same gesture.
    @Test("The last preset wraps to the first")
    func wrapsAtTheEnd() {
        #expect(PresetCycle.next(after: preset(.max).config, in: cycle)?.kind == .quiet)
    }

    /// Manual mode, a hand-edited curve and a saved user curve all look the same
    /// from here: they match no built-in. Guessing Quiet would silently drop a
    /// machine's cooling, which is the wrong direction to guess in.
    @Test(
        "An unrecognised state starts at Balanced, not at the first preset",
        arguments: [
            FanConfig?.none,
            FanConfig(mode: .manual, manualTargets: [0: 3000]),
            .curve(FanCurve(points: [.init(celsius: 40, fraction: 0.3), .init(celsius: 85, fraction: 0.9)])),
            .auto,
        ]
    )
    func unrecognisedStateStartsAtBalanced(applied: FanConfig?) {
        #expect(PresetCycle.next(after: applied, in: cycle)?.kind == .balanced)
    }

    @Test("An empty cycle yields nothing rather than crashing")
    func emptyCycleIsSafe() {
        #expect(PresetCycle.next(after: preset(.quiet).config, in: []) == nil)
    }

    /// The gesture must always land somewhere. A cycle that returned nil for a
    /// reachable state would present as an ⌥-click that does nothing at all —
    /// indistinguishable from the modifier not being detected.
    @Test("Every preset in the cycle has a successor")
    func everyPresetHasASuccessor() {
        for preset in cycle {
            #expect(
                PresetCycle.next(after: preset.config, in: cycle) != nil,
                "\(preset.name) is a dead end"
            )
        }
    }

    /// Four clicks from anywhere must return to where it started, or the gesture
    /// is not a cycle.
    @Test("Cycling the full length returns to the start")
    func fullLoopReturnsToStart() {
        var config: FanConfig? = preset(.quiet).config
        for _ in 0 ..< cycle.count {
            config = PresetCycle.next(after: config, in: cycle)?.config
        }
        #expect(config == preset(.quiet).config)
    }
}
