// StartupPolicy.swift — what fan mode Ice Cube should be in when it connects, and when to leave well alone.

import Foundation

/// Decides what the app applies once it reaches the daemon on launch.
///
/// The problem this solves: sitting in Automatic means macOS's own policy,
/// which lets the machine get hot and *then* spins the fans hard. Someone who
/// installed a fan-control app did not install it to get that. So a user who
/// has expressed no preference gets a sensible curve rather than nothing.
///
/// The trap it avoids: "no preference yet" and "the user deliberately chose
/// Automatic" are different states that used to look identical, because
/// choosing Automatic simply deleted the stored curve. Defaulting on absence
/// alone would therefore override an explicit choice on every single launch —
/// the user would set Automatic, quit, reopen, and find a curve running.
public enum StartupPolicy {
    /// What the user last deliberately selected. Absent = never chose.
    public enum Preference: String, Sendable, Codable {
        case automatic
        case curve
    }

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
        case .automatic:
            // An explicit choice. Honour it forever, including across restarts.
            return .leaveAlone
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
