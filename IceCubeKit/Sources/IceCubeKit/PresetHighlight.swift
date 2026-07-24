// PresetHighlight.swift — pure reconciliation of the "active preset" highlight with the daemon's real mode.

import Foundation

/// Decides which ``FanConfig`` the popover should treat as the *active preset*,
/// given the mode the daemon is actually enforcing, what the app currently
/// believes, and the last curve the app saved.
///
/// Pulled out as a pure function so the sleep/wake edge is unit-testable without
/// a real sleep cycle: when the lid closes, the daemon silently reverts a
/// non-persistent curve to auto (stale-heartbeat watchdog / XPC invalidation),
/// yet the app still remembers the curve — which then matches neither the curve
/// preset nor Auto, leaving no button highlighted.
public enum PresetHighlight {
    /// Whether `applied` is the config `preset` represents.
    ///
    /// A preset is identified by its mode plus its shared curve — the same two
    /// fields everywhere. This lived inline in two different views, and the
    /// copies had already drifted, so the popover and Settings could disagree
    /// about which preset was active.
    public static func matches(_ preset: Preset, applied: FanConfig?) -> Bool {
        guard let applied else { return false }
        return applied.mode == preset.config.mode
            && applied.sharedCurve == preset.config.sharedCurve
    }

    /// The built-in preset `applied` corresponds to, or `nil` for a
    /// user curve, an edited curve, or manual mode.
    public static func matching(_ presets: [Preset], applied: FanConfig?) -> Preset? {
        presets.first { matches($0, applied: applied) }
    }

    /// The config the highlight should reflect. Callers set it only when it
    /// differs from the current value, so a consistent state causes no churn.
    public static func reconcile(
        daemonMode: FanConfig.Mode,
        current: FanConfig?,
        storedCurve: FanConfig?,
        manualTargets: [Int: Double]
    ) -> FanConfig? {
        switch daemonMode {
        case .auto:
            // Daemon is on auto. If the app still thinks a curve is active (it
            // was reverted during sleep), fall back to Auto so a button stays
            // lit instead of nothing matching.
            current?.mode == .auto ? current : .auto
        case .curve:
            // Keep the app's curve identity if it already has one; otherwise
            // restore from the saved curve (e.g. a boot-persisted profile).
            current?.mode == .curve ? current : storedCurve
        case .manual:
            // Manual isn't a preset button; reflect it honestly so a stale curve
            // doesn't linger, but nothing will highlight.
            current?.mode == .manual ? current : FanConfig(mode: .manual, manualTargets: manualTargets)
        }
    }
}
