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
/// **Every string here has a fixed shape, and that is what keeps the menu bar
/// still.** `MenuBarExtra` does not host its label as a view; it copies the
/// text into the native status-bar button and discards every layout hint
/// (measured 2026-09-02: hidden placeholder Texts and `.monospacedDigit()`
/// both vanished, and the item was 59–63 pt wide depending on the digits). The
/// only two levers left are the font on that button — `StatusItemShim` gives
/// it tabular digits — and the string itself. In a tabular-digit font a figure
/// space and a figure dash are exactly one digit wide, so padding a reading to
/// a fixed number of digit cells makes "52°" and "104°" the same width. With
/// both in place the item measured 71 pt on 45 of 45 one-second ticks.
///
/// The compact RPM form is the other part worth pinning. It is the one place a
/// fan speed is deliberately *not* run through `RPM.text` — the menu bar has no
/// room for "6.800 RPM", so it says "6.8k" — and getting that wrong is how a
/// grouping separator ends up in a status item a few characters wide.
enum MenuBarLabel {
    /// A space exactly one tabular digit wide (U+2007 FIGURE SPACE): the
    /// padding that keeps a two-digit reading the width of a three-digit one.
    static let figureSpace = "\u{2007}"
    /// A dash exactly one tabular digit wide (U+2012 FIGURE DASH), so the
    /// placeholder before the first reading is the same width as a reading.
    static let figureDash = "\u{2012}"
    /// Digit cells a temperature occupies. Three, because a Mac14,9 die
    /// legitimately reads 95–105 °C under load, and Fahrenheit passes "100°" at
    /// 37.8 °C — many times an hour, which is where a two-cell slot would jump
    /// the most. Nothing reaches four: 105 °C is 221 °F.
    static let temperatureCells = 3

    /// The text beside the icon, or `nil` for icon-only.
    static func text(
        display: MenuBarDisplayMode,
        hottest: String,
        fans: [Fan]
    ) -> String? {
        switch display {
        case .iconOnly: nil
        case .temperature: temperature(hottest)
        case .fanSpeed: fanSpeed(fans)
        case .both: "\(temperature(hottest)) \(fanSpeed(fans))"
        }
    }

    /// The reading padded to ``temperatureCells`` digit widths, so every
    /// temperature in either unit is the same width. Padded on the **right**:
    /// the digits sit against the icon and the spare cell lands at the far
    /// edge, where the menu bar's own spacing absorbs it — padded on the left
    /// it opened a visible gap between the ice cube and the number (owner,
    /// 2026-09-02). In `.both` the spare cell sits between the reading and the
    /// fan speed, which keeps the fan speed's position fixed as well. The
    /// pre-reading placeholder "--°" becomes figure dashes for the same
    /// width reason, and a negative sign becomes one too.
    static func temperature(_ hottest: String) -> String {
        let cells = hottest.replacingOccurrences(of: "-", with: figureDash)
        let digits = cells.hasSuffix("°") ? cells.count - 1 : cells.count
        return cells + String(repeating: figureSpace, count: max(0, temperatureCells - digits))
    }

    /// The fastest fan's speed as "N.Nk" — always that shape, so the text is
    /// the same width at 500 RPM and at 6,800 RPM. Below 1000 it used to print
    /// the bare number ("999"), which is more precise and a different width;
    /// the width mattered more, and the popover has the exact figure. `"--"`
    /// when there are no fans at all (a fanless Mac, or before the first
    /// reading).
    static func fanSpeed(_ fans: [Fan]) -> String {
        guard let top = fans.map(\.actualRPM).max() else { return "--" }
        return String(format: "%.1fk", top / 1000)
    }
}
