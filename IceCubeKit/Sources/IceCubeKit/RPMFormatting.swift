// RPMFormatting.swift — how a fan reading is written, in one place, so no locale can garble it.

import Foundation

/// Fan speeds, formatted without a grouping separator.
///
/// Caught in the project's own README screenshots, taken on a Dutch-locale
/// Mac: the popover read **"6.802 RPM"** and the sensors browser
/// **"(2.317–6.800)"**. Both are correct `nl_NL` output — and both read as
/// "six point eight RPM" to most of the world, which for a fan-control app is
/// not a cosmetic problem. The same window showed "6802 RPM" in its chart rows,
/// so the app disagreed with itself on screen.
///
/// The cause is easy to reproduce and easy to miss: `Text("\(someInt)")` takes
/// the `LocalizedStringKey` overload, which formats integers with the locale's
/// grouping separator. `Text(someString)` does not. Chart rows built a `String`
/// first and came out right; everywhere else interpolated and came out grouped.
///
/// RPM is a raw count that never exceeds five digits, so grouping buys nothing
/// and costs clarity. Ungrouped is unambiguous in every locale.
///
/// Lives in IceCubeKit rather than beside the views that use it purely so it
/// can be tested: the app target has no test target, and this is exactly the
/// kind of formatting that regresses without anyone noticing until a
/// screenshot goes out.
public enum RPM {
    /// `6802` → `"6802"`. No separators, no localization.
    public static func text(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// `6802` → `"6802 RPM"`.
    public static func labeled(_ value: Double) -> String {
        "\(text(value)) RPM"
    }
}
