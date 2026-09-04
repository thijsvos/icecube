// MenuBarLabelTests.swift — what the status item says, and the fixed shape that keeps it from resizing, pinned.

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
@Suite("MenuBarLabel — what sits beside the icon, and how wide")
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
        let pad = MenuBarLabel.figureSpace
        #expect(MenuBarLabel.text(display: .temperature, hottest: "62°", fans: fans) == "62°\(pad)")
        #expect(MenuBarLabel.text(display: .fanSpeed, hottest: "62°", fans: fans) == "6.8k")
        #expect(MenuBarLabel.text(display: .both, hottest: "62°", fans: fans) == "62°\(pad) 6.8k")
    }

    /// The fastest fan, not the first — on a two-fan Mac they diverge under
    /// load, and reporting the slower one understates what the machine is doing.
    @Test("The reading follows the fastest fan")
    func reportsTheFastestFan() {
        #expect(MenuBarLabel.fanSpeed([fan(2400), fan(6800, id: 1)]) == "6.8k")
        #expect(MenuBarLabel.fanSpeed([fan(6800), fan(2400, id: 1)]) == "6.8k")
    }

    /// One shape at every speed. Below 1000 this used to print the bare
    /// number, which is more precise — and a different width, so the item
    /// resized whenever a fan crossed 1000 RPM. The popover has the exact figure.
    @Test("Every speed reads as N.Nk, below 1000 RPM included")
    func oneShapeAtEverySpeed() {
        #expect(MenuBarLabel.fanSpeed([fan(0)]) == "0.0k")
        #expect(MenuBarLabel.fanSpeed([fan(500)]) == "0.5k")
        #expect(MenuBarLabel.fanSpeed([fan(999)]) == "1.0k")
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

    // MARK: - A fixed shape, so the item never resizes

    /// `MenuBarExtra` copies this text into the native status-bar button and
    /// discards every SwiftUI layout hint, so the only thing that can hold the
    /// item's width is the string: a fixed number of digit-width cells in the
    /// tabular-digit font `StatusItemShim` sets. Fahrenheit is the unit that
    /// matters — "99°" becomes "100°" at 37.8 °C, many times an hour — so the
    /// sweep runs both units.
    @Test("Every temperature from -20 °C to 110 °C is three digit cells and a degree sign, in both units")
    func temperatureIsAlwaysThreeCells() {
        let cell = Set("0123456789" + MenuBarLabel.figureSpace + MenuBarLabel.figureDash)
        for unit in TemperatureUnit.allCases {
            for celsius in -20 ... 110 {
                let text = MenuBarLabel.temperature(unit.text(Double(celsius)))
                #expect(text.count == MenuBarLabel.temperatureCells + 1, "\(text) in \(unit.title)")
                #expect(text.filter { $0 == "°" }.count == 1, "\(text) in \(unit.title)")
                #expect(
                    text.filter { $0 != "°" }.allSatisfy { cell.contains($0) },
                    "\(text) has a cell that is not a digit width"
                )
                // Digits first, padding last: the number sits against the icon
                // and any spare cell is at the far edge, never between them.
                #expect(!text.hasPrefix(MenuBarLabel.figureSpace), "\(text) is padded on the icon side")
            }
        }
    }

    @Test("The placeholder before the first reading is the same shape as a reading")
    func placeholderHasTheSameShape() {
        let placeholder = MenuBarLabel.temperature("--°")
        #expect(placeholder == MenuBarLabel.figureDash + MenuBarLabel.figureDash + "°" + MenuBarLabel.figureSpace)
        #expect(placeholder.count == MenuBarLabel.temperature("104°").count)
    }

    @Test("Every fan speed from 0 to 7000 RPM is the same four-cell N.Nk shape")
    func fanSpeedIsAlwaysFourCells() {
        for rpm in stride(from: 0.0, through: 7000, by: 50) {
            let text = MenuBarLabel.fanSpeed([fan(rpm)])
            #expect(text.count == 4 && text.hasSuffix("k") && text.dropFirst().first == ".", "\(text) at \(rpm) RPM")
        }
    }

    @Test("Both mode is nine cells in every unit")
    func bothModeIsNineCells() {
        for unit in TemperatureUnit.allCases {
            for celsius in [0.0, 37.8, 62, 104] {
                let text = MenuBarLabel.text(display: .both, hottest: unit.text(celsius), fans: [fan(4250)]) ?? ""
                #expect(text.count == 9, "\(text) in \(unit.title)")
            }
        }
    }

    /// THE REGRESSION THIS FILE IS FOR. `RPM.text` inserts a grouping separator
    /// — "6.800" in a de_DE locale — and the status item has no room for it.
    /// This path must stay separator-free in every locale.
    @Test("The compact form carries no grouping separator, in any locale")
    func noGroupingSeparatorAnywhere() {
        for value in [500.0, 1000.0, 4250.0, 6800.0] {
            let text = MenuBarLabel.fanSpeed([fan(value)])
            #expect(!text.contains(","))
            #expect(text.filter { $0 == "." }.count <= 1, "one decimal point at most, never a thousands mark")
        }
    }
}
