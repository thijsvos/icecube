// MenuBarLabel.swift — what the text beside the menu bar icon says, as a pure function of the readings.

import Foundation
import IceCubeKit

/// Formats the menu bar readout.
///
/// Pure statics rather than computed properties on `AppState`, for the reason
/// `FanControlStatus` and `MenuBarMode` were extracted: this is a *decision*
/// about what the user sees, it is on the hottest path in the app —
/// `StatusItemController` sets `button.title` from it on every poll — and until
/// now it could only be exercised by building an `AppState`, which drags in the
/// chart store, the alert manager and `UNUserNotificationCenter`.
///
/// The compact RPM form is the part worth pinning. It is the one place a fan
/// speed is deliberately *not* run through `RPM.text` — the menu bar has no
/// room for "6.800 RPM", so it says "6.8k" — and getting that wrong is how a
/// grouping separator ends up in a status item four characters wide.
enum MenuBarLabel {
    /// The text beside the icon, or `nil` for icon-only.
    static func text(
        display: MenuBarDisplayMode,
        hottest: String,
        fans: [Fan]
    ) -> String? {
        switch display {
        case .iconOnly: nil
        case .temperature: hottest
        case .fanSpeed: fanSpeed(fans)
        case .both: "\(hottest) \(fanSpeed(fans))"
        }
    }

    /// The fastest fan's speed, compact: `"5.0k"` above 1000 RPM, `"--"` when
    /// there are no fans at all (a fanless Mac, or before the first reading).
    static func fanSpeed(_ fans: [Fan]) -> String {
        guard let top = fans.map(\.actualRPM).max() else { return "--" }
        return top >= 1000 ? String(format: "%.1fk", top / 1000) : String(Int(top.rounded()))
    }
}
