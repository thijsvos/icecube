// PresetCycle.swift — which preset comes next when the user asks for "the next one".

import Foundation

/// Resolves the *next* preset for a quick-switch gesture (⌥-click on the menu
/// bar item, PLAN.md §1.1).
///
/// Pure, like ``PresetHighlight`` and ``PowerProfilePolicy``: a config in, a
/// preset out, no I/O. The gesture itself is impossible to unit-test — it needs
/// a real status item and a real modifier key — so everything that *decides*
/// anything is pulled out here, leaving the untestable part with no logic in it.
public enum PresetCycle {
    /// The preset following the one currently applied, wrapping at the end.
    ///
    /// - Parameters:
    ///   - applied: the config the daemon is enforcing, or `nil` when nothing is.
    ///   - presets: the cycle, in order. Callers pass `PresetStore.builtins`.
    ///
    /// **Built-ins only, by the caller's choice.** Cycling through an unbounded
    /// list of saved curves one modifier-click at a time is not a usable
    /// gesture — a user with nine curves would have to click nine times to get
    /// back. The list is a parameter rather than a hard-coded lookup so that
    /// stays the caller's decision and this stays testable.
    public static func next(after applied: FanConfig?, in presets: [Preset]) -> Preset? {
        guard !presets.isEmpty else { return nil }
        guard let index = presets.firstIndex(where: {
            PresetHighlight.matches($0, applied: applied)
        }) else {
            return startingPoint(in: presets)
        }
        return presets[(index + 1) % presets.count]
    }

    /// Where the cycle starts when the current state matches no preset — a
    /// hand-edited curve, a saved user curve, manual mode, or nothing applied
    /// at all.
    ///
    /// **Balanced**, matching the answer this project already gives everywhere
    /// else it has to pick for the user (CLAUDE.md ground rule 4,
    /// ``StartupPolicy``). Answering "the first one" instead would mean an
    /// ⌥-click from a custom curve silently drops the machine to Quiet, which
    /// is the wrong direction to guess in on a thermal tool.
    private static func startingPoint(in presets: [Preset]) -> Preset? {
        presets.first { $0.kind == .balanced } ?? presets.first
    }
}
