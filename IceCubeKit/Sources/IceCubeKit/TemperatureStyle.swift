// TemperatureStyle.swift — how a °C figure is rendered, keeping absolutes and differences apart.

import Foundation

/// The unit a temperature is shown in, and — the part that matters — *which
/// kind* of temperature it is.
///
/// ## Why this is not one conversion function
///
/// Fahrenheit converts an absolute reading and a difference **differently**.
/// 30 °C of headroom is 54 °F of headroom, not 86 °F: the `+32` offset belongs
/// to the point on the scale, not to the gap between two points. A single
/// `display(_:)` helper applied to both is the natural mistake, and it produces
/// a number that looks plausible and is wrong by 32 — worst in the one place
/// this app is asked to be trusted, a temperature readout.
///
/// So the two are separate operations and a caller has to choose. `°C/W` is a
/// difference per watt, so it scales like ``delta``.
///
/// ## Why it lives in the Kit
///
/// The Kit computes in °C and never decides the unit — `ChartStore.Unit` states
/// the same rule from the other side ("this crosses the module boundary into
/// the app target, where it gates the Fahrenheit conversion"). This type is the
/// *mechanism*; the app target still owns the *choice*, and passes one in.
/// `DiagnosisCopy` needs it because it composes finished prose rather than
/// emitting a number and a unit tag the way the charts do.
public struct TemperatureStyle: Sendable, Equatable {
    /// `"°C"` or `"°F"`, already including the degree sign.
    public let symbol: String

    /// A point on the scale: a sensor reading, a ceiling.
    public let absolute: @Sendable (Double) -> Double

    /// A gap between two points: headroom, a rise above airflow, °C/W.
    /// **Never** carries the Fahrenheit offset.
    public let delta: @Sendable (Double) -> Double

    public init(
        symbol: String,
        absolute: @escaping @Sendable (Double) -> Double,
        delta: @escaping @Sendable (Double) -> Double
    ) {
        self.symbol = symbol
        self.absolute = absolute
        self.delta = delta
    }

    public static let celsius = TemperatureStyle(symbol: "°C", absolute: { $0 }, delta: { $0 })

    public static let fahrenheit = TemperatureStyle(
        symbol: "°F",
        absolute: { $0 * 9 / 5 + 32 },
        delta: { $0 * 9 / 5 }
    )

    /// Two styles are the same when they name the same unit. The closures make
    /// the synthesized conformance impossible, and the symbol is the identity
    /// that matters — there are exactly two of these.
    public static func == (lhs: TemperatureStyle, rhs: TemperatureStyle) -> Bool {
        lhs.symbol == rhs.symbol
    }

    // MARK: - Rendering

    /// A whole-number reading with its unit, e.g. `"62 °C"` / `"144 °F"`.
    public func reading(_ celsius: Double) -> String {
        "\(Int(absolute(celsius).rounded())) \(symbol)"
    }

    /// A whole-number difference with its unit, e.g. `"30 °C"` / `"54 °F"`.
    public func difference(_ celsius: Double) -> String {
        "\(Int(delta(celsius).rounded())) \(symbol)"
    }

    /// Thermal resistance, e.g. `"0.42 °C/W"` / `"0.76 °F/W"`.
    public func perWatt(_ celsiusPerWatt: Double) -> String {
        String(format: "%.2f", delta(celsiusPerWatt)) + " \(symbol)/W"
    }

    /// An inclusive range of absolute readings, e.g. `"95–105 °C"`.
    public func range(_ low: Double, _ high: Double) -> String {
        "\(Int(absolute(low).rounded()))–\(Int(absolute(high).rounded())) \(symbol)"
    }
}
