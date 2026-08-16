// FanCurve.swift — the temperature→fan-speed curve: points, invariants, interpolation, built-ins.

import Foundation

/// One control point: at `celsius`, run the fan at `fraction` of its range.
public struct CurvePoint: Sendable, Codable, Equatable, Hashable {
    /// Die temperature, °C (editor range 30…110).
    public var celsius: Double
    /// 0 = the fan's minimum RPM (still spinning), 1 = maximum.
    public var fraction: Double

    public init(celsius: Double, fraction: Double) {
        self.celsius = celsius
        self.fraction = fraction
    }
}

/// A monotonic piecewise-linear fan curve.
///
/// Invariants — enforced by construction, so a curve from ANY source
/// (editor, JSON, XPC) is safe to evaluate:
/// - points sorted by strictly increasing `celsius` (duplicates collapsed),
/// - every `fraction` clamped to 0…1 and **non-decreasing** (a fan curve
///   that spins DOWN as things get hotter is never intended),
/// - non-finite values dropped, count capped at 8.
///
/// Below the first point the curve holds the first fraction; above the last,
/// the last. In curve mode fans always spin at ≥ their minimum RPM —
/// fraction 0 means "minimum", never "stopped" (a commanded 0 RPM is
/// forbidden everywhere in Ice Cube).
public struct FanCurve: Sendable, Codable, Equatable {
    public private(set) var points: [CurvePoint]

    public init(points: [CurvePoint]) {
        self.points = Self.normalized(points)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Normalize on decode too: persisted/XPC data gets the same invariants.
        points = try Self.normalized(container.decode([CurvePoint].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(points)
    }

    /// A curve needs at least two points to define a slope worth following.
    public var isUsable: Bool {
        points.count >= 2
    }

    /// The fan fraction at `celsius`: flat before the first and after the
    /// last point, linear in between. Always finite, always 0…1.
    public func fraction(at celsius: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        guard celsius.isFinite else { return last.fraction } // fail hot, not cold
        if celsius <= first.celsius {
            return first.fraction
        }
        if celsius >= last.celsius {
            return last.fraction
        }
        for (a, b) in zip(points, points.dropFirst()) where celsius <= b.celsius {
            let span = b.celsius - a.celsius
            guard span > 0 else { return b.fraction }
            let t = (celsius - a.celsius) / span
            return a.fraction + t * (b.fraction - a.fraction)
        }
        return last.fraction
    }

    /// Applies every invariant to a raw point list (see type docs).
    public static func normalized(_ raw: [CurvePoint]) -> [CurvePoint] {
        var cleaned = raw
            .filter { $0.celsius.isFinite && $0.fraction.isFinite }
            .map { CurvePoint(
                celsius: $0.celsius.clamped(to: -20 ... 120),
                fraction: $0.fraction.clamped(to: 0 ... 1)
            ) }
            .sorted { $0.celsius < $1.celsius }
        // Collapse points closer than 0.5 °C (keep the first of each cluster).
        var deduped: [CurvePoint] = []
        for point in cleaned where deduped.last.map({ point.celsius - $0.celsius >= 0.5 }) ?? true {
            deduped.append(point)
        }
        cleaned = Array(deduped.prefix(8))
        // Non-decreasing fraction: running maximum.
        var runningMax = 0.0
        for i in cleaned.indices {
            runningMax = Swift.max(runningMax, cleaned[i].fraction)
            cleaned[i].fraction = runningMax
        }
        return cleaned
    }

    // MARK: - Built-in curves (the Quiet/Balanced/Max presets)

    /// Silent at idle, but doesn't tolerate real heat: fans from 60 °C,
    /// full speed already at 90 °C (tuned cooler per owner preference —
    /// the die should not live in the high 80s).
    public static let quiet = FanCurve(points: [
        CurvePoint(celsius: 60, fraction: 0),
        CurvePoint(celsius: 70, fraction: 0.3),
        CurvePoint(celsius: 80, fraction: 0.6),
        CurvePoint(celsius: 90, fraction: 1),
    ])

    /// The cool-running all-rounder: airflow starts in the mid-40s and the
    /// fans are at full speed by 85 °C — trades some noise for a machine
    /// that stays comfortable to the touch.
    public static let balanced = FanCurve(points: [
        CurvePoint(celsius: 45, fraction: 0),
        CurvePoint(celsius: 55, fraction: 0.25),
        CurvePoint(celsius: 65, fraction: 0.5),
        CurvePoint(celsius: 75, fraction: 0.75),
        CurvePoint(celsius: 85, fraction: 1),
    ])

    /// As cold as the hardware allows, WITHOUT the fan hunting.
    ///
    /// The idle band (35–55 °C, where an M2 Pro spends most of its light-load
    /// life) is deliberately **flat-ish**: the fans hold a steady, fairly
    /// strong ~55–70 % across it, so the ±few-°C temperature noise of ordinary
    /// use no longer crosses a steep knee and swings the fans up and down. The
    /// steep climb to full speed is placed **above 65 °C**, where real
    /// sustained load lives. Net: the machine stays just as cool, but with a
    /// constant soft hum instead of random spikes. (The die still exceeds
    /// 50 °C under real load — no fan can prevent that.)
    ///
    /// CORRECTION (2026-08-16): the first two fractions shipped as 0.5 and 0.62
    /// in `d45b2e3`, which put the idle band at 50–62 % and — because the slope
    /// then *fell* from 55→65 °C to 65→80 °C — put the steepest segment BELOW
    /// 65 °C. Both halves of the paragraph above were untrue of the constants
    /// under it from the day they landed; that commit's own message asks for
    /// "a steady ~55-70%" and a knee "ABOVE 65 C". The prose was the spec and
    /// the numbers were the typo, so the numbers moved. Cold now genuinely
    /// climbs 0.0075 → 0.008 → 0.0147 per °C, steepest last.
    public static let cold = FanCurve(points: [
        CurvePoint(celsius: 35, fraction: 0.55),
        CurvePoint(celsius: 55, fraction: 0.7),
        CurvePoint(celsius: 65, fraction: 0.78),
        CurvePoint(celsius: 80, fraction: 1),
    ])

    /// Full speed always (flat at 1.0).
    public static let max = FanCurve(points: [
        CurvePoint(celsius: 30, fraction: 1),
        CurvePoint(celsius: 95, fraction: 1),
    ])
}
