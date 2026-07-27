// StartupPolicy.swift — what fan mode Ice Cube should be in when it connects, and when to leave well alone.

import Foundation

/// Decides what the app applies once it reaches the daemon on launch.
///
/// The problem this solves: sitting in Automatic means macOS's own policy,
/// which lets the machine get hot and *then* spins the fans hard. Someone who
/// installed a fan-control app did not install it to get that. So a user who
/// has expressed no preference gets a sensible curve rather than nothing.
///
/// HISTORY (2026-07-26): there used to be a third state here, `.automatic` —
/// "the user deliberately chose to hand the fans to macOS" — kept distinct from
/// "never chose" so that defaulting on absence could not override a real choice
/// on every launch. It is gone because the choice itself is gone: macOS mode was
/// removed from the UI, so nothing can express it any more. An old stored
/// `"automatic"` now fails to decode, reads as `nil`, and lands the user on the
/// fallback curve — which is the right destination and needs no migration code.
/// Handing the fans back is no longer a mode at all; it is Settings ->
/// "Turn Off Fan Control", which removes the daemon entirely.
public enum StartupPolicy {
    /// What the user last deliberately selected. Absent = never chose.
    public enum Preference: String, Sendable, Codable {
        case curve
    }

    /// What the app should do on reaching the daemon. `.leaveAlone` is not
    /// "nothing went wrong" — it is the deliberate refusal to stomp a mode the
    /// daemon is already enforcing, such as a curve resumed at boot before the
    /// app existed, or manual control in active use.
    public enum Decision: Sendable, Equatable {
        /// Change nothing.
        case leaveAlone
        /// Apply this config.
        case apply(FanConfig)
    }

    /// - Parameters:
    ///   - daemonMode: what the daemon reports it is already enforcing.
    ///   - preference: the user's last deliberate choice, or `nil`.
    ///   - storedCurve: the curve saved alongside a `.curve` preference.
    ///   - fallback: the curve to use when the user has never chosen.
    public static func decide(
        daemonMode: FanConfig.Mode,
        preference: Preference?,
        storedCurve: FanConfig?,
        fallback: FanCurve
    ) -> Decision {
        // Something is already being enforced — a curve the daemon resumed at
        // boot, or manual control the user is actively using. Never stomp it.
        guard daemonMode == .auto else { return .leaveAlone }

        switch preference {
        case .curve:
            // Their curve, if it still decodes; otherwise the fallback rather
            // than silently dropping them into Automatic.
            if let storedCurve, storedCurve.isUsableCurveConfig {
                return .apply(storedCurve)
            }
            return .apply(defaultConfig(fallback))
        case nil:
            // Never chose: give them the point of the app.
            return .apply(defaultConfig(fallback))
        }
    }

    /// The out-of-the-box config. Deliberately does NOT persist without the
    /// app: a default the user never opted into must not outlive the app that
    /// applied it, and `persistsWithoutApp` is theirs to turn on.
    public static func defaultConfig(_ curve: FanCurve) -> FanConfig {
        var config = FanConfig(mode: .curve, persistsWithoutApp: false)
        config.sharedCurve = curve
        return config
    }
}
