// AppSettingsTests.swift — the display units, pinned; every reading in the app goes through them.

import Foundation
import IceCubeKit
import Testing

/// Three pure enums that measured 0% covered, which is only surprising until
/// you notice nothing constructs them in a test — they are read from views.
///
/// They are worth pinning because `TemperatureUnit` is the last thing that
/// touches every number the user sees, and because `text(_:)` is one of the two
/// places in the app that deliberately avoids `NumberFormatter`. The other one,
/// `MenuBarLabel`, has its own suite for the same reason: a Dutch-locale Mac
/// once rendered an RPM axis as "5.000 / 2.500 / 0".
@Suite("AppSettings — units and intervals")
struct AppSettingsTests {
    @Test("Celsius is passed through untouched")
    func celsiusIsIdentity() {
        #expect(TemperatureUnit.celsius.display(0) == 0)
        #expect(TemperatureUnit.celsius.display(66.4) == 66.4)
        #expect(TemperatureUnit.celsius.display(-40) == -40)
    }

    @Test(
        "Fahrenheit converts at the two fixed points and through the crossover",
        arguments: [
            (0.0, 32.0),
            (100.0, 212.0),
            (37.0, 98.6),
            // The one temperature where both scales agree. A sign error in the
            // conversion still passes 0 and 100 if it is symmetric; this does not.
            (-40.0, -40.0),
        ]
    )
    func fahrenheitConverts(celsius: Double, fahrenheit: Double) {
        let converted = TemperatureUnit.fahrenheit.display(celsius)
        #expect(abs(converted - fahrenheit) < 0.001, "\(celsius) °C should be \(fahrenheit) °F, got \(converted)")
    }

    /// The rendered string, not the number. Interpolating an `Int` is
    /// locale-independent; a `NumberFormatter` here would put a thousands
    /// separator in a three-digit Fahrenheit reading on some locales.
    @Test("The rendered reading is a rounded integer with a degree sign and no separators")
    func textIsLocaleProof() {
        #expect(TemperatureUnit.celsius.text(66.4) == "66°")
        #expect(TemperatureUnit.celsius.text(66.6) == "67°")
        #expect(TemperatureUnit.fahrenheit.text(100) == "212°")
        #expect(!TemperatureUnit.fahrenheit.text(1000).contains(","), "no thousands separator, ever")
        #expect(!TemperatureUnit.fahrenheit.text(1000).contains("."), "and no decimal separator either")
    }

    @Test("A negative reading keeps its sign rather than rendering as unsigned")
    func negativeReadingsKeepTheirSign() {
        #expect(TemperatureUnit.celsius.text(-5) == "-5°")
    }

    @Test("Both units are offered, each with its own symbol")
    func bothUnitsAreSelectable() {
        #expect(TemperatureUnit.allCases.count == 2)
        #expect(TemperatureUnit.celsius.title == "°C")
        #expect(TemperatureUnit.fahrenheit.title == "°F")
        #expect(Set(TemperatureUnit.allCases.map(\.id)).count == 2, "ids must be distinct or Picker selection breaks")
    }

    @Test("Poll intervals are seconds, labelled as seconds, and ordered fastest first")
    func pollIntervals() {
        let all = PollInterval.allCases
        #expect(all.map(\.rawValue) == [1, 2, 5])
        #expect(all.map(\.title) == ["1 s", "2 s", "5 s"])
        #expect(all.map(\.id) == all.map(\.rawValue))
    }

    @Test("Every menu bar display mode has a distinct id and a non-empty title")
    func menuBarModesAreDistinct() {
        let all = MenuBarDisplayMode.allCases
        #expect(all.count == 4)
        #expect(Set(all.map(\.id)).count == all.count, "ids must be distinct or Picker selection breaks")
        for mode in all {
            #expect(!mode.title.isEmpty, "\(mode) has no title")
        }
    }
}
