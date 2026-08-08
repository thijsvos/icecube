// TemperatureStyleTests.swift — the absolute/difference split, which is the whole reason this type exists.

import Foundation
@testable import IceCubeKit
import Testing

/// Fahrenheit converts a point on the scale and a gap between two points
/// **differently**, and a single `display(_:)` applied to both is the natural
/// mistake. These tests exist to make that mistake fail loudly.
@Suite("TemperatureStyle — absolutes take the offset, differences do not")
struct TemperatureStyleTests {
    @Test("Celsius changes nothing, whichever kind of value it is")
    func celsiusIsIdentity() {
        #expect(TemperatureStyle.celsius.reading(62) == "62 °C")
        #expect(TemperatureStyle.celsius.difference(30) == "30 °C")
        #expect(TemperatureStyle.celsius.perWatt(0.42) == "0.42 °C/W")
    }

    /// The headline. 30 °C of headroom is 54 °F of headroom — applying the
    /// +32 offset would print 86, a number that looks entirely plausible and
    /// is wrong by exactly the offset.
    @Test("A difference converts without the offset")
    func differenceHasNoOffset() {
        #expect(TemperatureStyle.fahrenheit.difference(30) == "54 °F", "not 86 — this is a gap, not a point")
        #expect(TemperatureStyle.fahrenheit.difference(0) == "0 °F", "no difference is no difference in any unit")
    }

    @Test("An absolute reading takes the offset")
    func absoluteHasOffset() {
        #expect(TemperatureStyle.fahrenheit.reading(100) == "212 °F")
        #expect(TemperatureStyle.fahrenheit.reading(0) == "32 °F")
        #expect(TemperatureStyle.fahrenheit.reading(62) == "144 °F")
    }

    /// The two must never agree except where the maths says they do, which is
    /// nowhere in Fahrenheit — the offset is a constant 32, so any value that
    /// rendered the same both ways would mean the split had collapsed.
    @Test("The two conversions stay apart across the range", arguments: [0.0, 20, 37.5, 62, 104])
    func splitDoesNotCollapse(celsius: Double) {
        let style = TemperatureStyle.fahrenheit
        #expect(style.reading(celsius) != style.difference(celsius))
        #expect(style.absolute(celsius) - style.delta(celsius) == 32)
    }

    /// °C/W is a rise per watt — a difference, so it scales by 9/5 alone. The
    /// symbol has to follow the unit too, or the number changes while the
    /// label still claims Celsius.
    @Test("Thermal resistance scales like a difference and relabels")
    func perWattIsADifference() {
        #expect(TemperatureStyle.fahrenheit.perWatt(1.0) == "1.80 °F/W")
        #expect(TemperatureStyle.fahrenheit.perWatt(0.42) == "0.76 °F/W")
    }

    @Test("A range converts both ends as absolutes")
    func rangeIsAbsolute() {
        #expect(TemperatureStyle.celsius.range(95, 105) == "95–105 °C")
        #expect(TemperatureStyle.fahrenheit.range(95, 105) == "203–221 °F")
    }

    /// Rounding is applied after conversion, not before — converting a rounded
    /// figure loses up to 0.9 °F, which shows up as an off-by-one against any
    /// other tool the user checks against.
    @Test("Conversion happens before rounding")
    func roundsAfterConverting() {
        #expect(TemperatureStyle.fahrenheit.reading(62.4) == "144 °F", "62.4 °C is 144.32 °F")
        #expect(TemperatureStyle.fahrenheit.reading(62.6) == "145 °F", "62.6 °C is 144.68 °F")
    }
}

/// The window this was built for. `DiagnosisCopy` composes finished prose in
/// the Kit rather than emitting a number and a unit tag the way the charts do,
/// so it is the one place that has to be handed a style.
@Suite("DiagnosisCopy — the unit reaches the words")
struct DiagnosisCopyUnitTests {
    static func measured(_ celsius: Double) -> ThermalDiagnosis.Heat {
        .measured(
            celsius: celsius,
            label: "Tp01",
            band: .warm,
            headroom: SafetyMonitor.Limits().dieCeiling - celsius
        )
    }

    @Test("Celsius is the default, so the CLI and every existing caller are unchanged")
    func defaultsToCelsius() {
        let row = DiagnosisCopy.heat(Self.measured(74), load: .noPowerSignal)
        #expect(row.metric?.contains("°C") == true)
        #expect(row.metric?.contains("°F") == false)
    }

    /// Both figures in this row are conversions of different kinds — the
    /// metric is headroom (a difference) and the hover names the reading (an
    /// absolute). A style that got either wrong would show here.
    @Test("Fahrenheit reaches both the metric and the hover, each converted its own way")
    func fahrenheitReachesTheHeatRow() throws {
        let row = DiagnosisCopy.heat(Self.measured(74), load: .noPowerSignal, style: .fahrenheit)
        let metric = try #require(row.metric)
        let hover = try #require(row.hover)

        // 104 - 74 = 30 °C of headroom -> 54 °F, NOT 86.
        #expect(metric.contains("54 °F"), "headroom is a difference: \(metric)")
        #expect(!metric.contains("86"), "86 would be the offset wrongly applied to a gap")
        // The reading itself is a point on the scale: 74 °C -> 165 °F.
        #expect(hover.contains("165 °F"), "the sensor reading is an absolute: \(hover)")
        #expect(!hover.contains("°C"), "no Celsius may survive in a Fahrenheit row")
    }

    @Test("The load row converts a rise and a per-watt figure, and relabels the unit in prose")
    func fahrenheitReachesTheLoadRow() throws {
        let row = DiagnosisCopy.load(.explained(watts: 20, riseCelsius: 30, resistance: 1.0), style: .fahrenheit)
        let metric = try #require(row.metric)
        let hover = try #require(row.hover)
        #expect(metric.contains("54 °F"), "a rise above airflow is a difference: \(metric)")
        #expect(metric.contains("1.80 °F/W"))
        #expect(hover.contains("°F/W is better"), "the prose names the unit too, not just the number")
        #expect(!hover.contains("°C"))
    }

    /// The `.hotWithoutLoad` state is the one the window exists for, so its
    /// number must not be the one left in Celsius.
    @Test("The finding this window exists for is converted too")
    func hotWithoutLoadConverts() throws {
        let row = DiagnosisCopy.load(.hotWithoutLoad(watts: 6, celsius: 95), style: .fahrenheit)
        #expect(try #require(row.metric).contains("203 °F"))
    }
}
