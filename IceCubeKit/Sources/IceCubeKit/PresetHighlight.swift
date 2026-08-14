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

    /// Whether `preset` is the one to light up, preferring what the daemon says
    /// it is **enforcing** over what the app remembers **sending**.
    ///
    /// The precedence is the point. Consulting only the app's own memory left
    /// every button unlit while the fans audibly ran, for anything the daemon
    /// was running that this app had not personally sent — a curve resumed at
    /// boot, before the app even launched. The truth about what is enforced
    /// lives in the daemon; the app's memory is a cache of it.
    ///
    /// This is the **third** home for the "is this preset active" rule. The
    /// other two are ``matches(_:applied:)`` and the copy that used to sit in
    /// `FanControlSection` — and this type exists because those two had already
    /// drifted, so the popover and Settings could disagree about which preset
    /// was active. A rule that has drifted once will drift again; it gets one
    /// home.
    ///
    /// - Parameters:
    ///   - enforced: the daemon's own report (`HelperStatus`), or `nil` when
    ///     there is no live connection.
    ///   - applied: the last config this app sent, as a fallback.
    public static func isActive(
        _ preset: Preset, enforced: HelperStatus?, applied: FanConfig?
    ) -> Bool {
        guard let enforced, enforced.mode == preset.config.mode else { return false }
        // In curve mode the daemon names the curve it is running, which settles
        // it outright — including for a curve this app never sent.
        if enforced.mode == .curve, let active = enforced.activeCurve {
            return active == preset.config.sharedCurve
        }
        return matches(preset, applied: applied)
    }

    /// Whether the fans are running a curve that is **none of these presets** —
    /// one the user drew in the editor and applied without saving it.
    ///
    /// The popover shows it as a lit "Custom" chip, and that chip exists because
    /// the alternative was worse in both directions. Leaving the row blank says
    /// "nothing is selected" while Ice Cube is driving the fans, which this type
    /// already treats as a bug in the boot-resume case. Lighting the preset the
    /// curve was *edited from* would be a label that says the opposite of what
    /// it does — the failure `ControlStatus` records this project deleting an
    /// entire preset over — and clicking it would then silently replace the
    /// user's curve with the pristine one.
    ///
    /// Deliberately false when the curve cannot be seen: no connection at all,
    /// or a daemon too old to report `activeCurve` to an app that has sent
    /// nothing this session. "Not one of your presets" is a claim about a curve
    /// we can read; unknown is not custom.
    public static func isRunningCustomCurve(
        among presets: [Preset], enforced: HelperStatus?, applied: FanConfig?
    ) -> Bool {
        guard let enforced, enforced.mode == .curve else { return false }
        guard enforced.activeCurve != nil || applied?.mode == .curve else { return false }
        return !presets.contains { isActive($0, enforced: enforced, applied: applied) }
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
