// MenuBarLabelTests.swift — what the status item says, pinned; it is four characters wide and read constantly.

import Foundation
import IceCubeKit
import Testing

/// The menu bar readout is the app's most-read surface and its least-tested
/// one: it was a computed property on `AppState`, so exercising it meant
/// building the chart store, the alert manager and `UNUserNotificationCenter`.
///
/// The compact RPM form is the reason this suite exists. It is the one place a
/// fan speed is deliberately not run through `RPM.text` — and a locale bug in
/// exactly that formatter shipped once already (fan speeds read "6.802 RPM"
/// outside en_US), caught only by the owner's screenshots.
@MainActor
@Suite("MenuBarLabel — the four characters beside the icon")
struct MenuBarLabelTests {
    private func fan(_ rpm: Double, id: Int = 0) -> Fan {
        Fan(id: id, name: "F\(id)", mode: .forced, actualRPM: rpm, targetRPM: rpm, minRPM: 2317, maxRPM: 6800)
    }

    @Test("Icon-only shows nothing at all, not an empty string that still takes space")
    func iconOnlyIsNil() {
        #expect(MenuBarLabel.text(display: .iconOnly, hottest: "62°", fans: [fan(4000)]) == nil)
    }

    @Test("Each display mode shows what it says on the tin")
    func modesShowTheirSubject() {
        let fans = [fan(4000), fan(6800, id: 1)]
        #expect(MenuBarLabel.text(display: .temperature, hottest: "62°", fans: fans) == "62°")
        #expect(MenuBarLabel.text(display: .fanSpeed, hottest: "62°", fans: fans) == "6.8k")
        #expect(MenuBarLabel.text(display: .both, hottest: "62°", fans: fans) == "62° 6.8k")
    }

    /// The fastest fan, not the first — on a two-fan Mac they diverge under
    /// load, and reporting the slower one understates what the machine is doing.
    @Test("The reading follows the fastest fan")
    func reportsTheFastestFan() {
        #expect(MenuBarLabel.fanSpeed([fan(2400), fan(6800, id: 1)]) == "6.8k")
        #expect(MenuBarLabel.fanSpeed([fan(6800), fan(2400, id: 1)]) == "6.8k")
    }

    /// Below 1000 the compact form would read "0.9k", which is both longer and
    /// less precise than the number itself.
    @Test("Under 1000 RPM it shows the number; at or above it switches to k")
    func theCompactThreshold() {
        #expect(MenuBarLabel.fanSpeed([fan(0)]) == "0")
        #expect(MenuBarLabel.fanSpeed([fan(999)]) == "999")
        #expect(MenuBarLabel.fanSpeed([fan(1000)]) == "1.0k")
        #expect(MenuBarLabel.fanSpeed([fan(6800)]) == "6.8k")
    }

    /// A fanless Mac (MacBook Air) is supported by design, and so is the second
    /// before the first reading lands. Neither may render as "0".
    @Test("No fans reads as unknown, not as zero")
    func noFansIsUnknown() {
        #expect(MenuBarLabel.fanSpeed([]) == "--")
        #expect(MenuBarLabel.text(display: .fanSpeed, hottest: "--°", fans: []) == "--")
    }

    /// THE REGRESSION THIS FILE IS FOR. `RPM.text` inserts a grouping separator
    /// — "6.800" in a de_DE locale — and the status item has no room for it.
    /// This path must stay separator-free in every locale.
    @Test("The compact form carries no grouping separator, in any locale")
    func noGroupingSeparatorAnywhere() {
        for value in [1000.0, 4250.0, 6800.0] {
            let text = MenuBarLabel.fanSpeed([fan(value)])
            #expect(!text.contains(","))
            #expect(text.filter { $0 == "." }.count <= 1, "one decimal point at most, never a thousands mark")
        }
    }
}
