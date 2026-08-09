// FanBand.swift — the fan-speed axis every cooling-history comparison is grouped by.

import Foundation

/// Which fan-speed regime a cooling reading was taken in.
///
/// `R` genuinely differs with fan speed — docs/THERMAL.md measured
/// 1.04–1.13 °C/W at 3550 RPM against 0.89–0.93 at 5950 on the reference
/// machine, a ~16 % spread from fan speed alone, larger than the degradation
/// the trend looks for. So readings are only ever compared within one band,
/// and the band is part of every record.
public enum FanBand: Sendable, Hashable {
    /// A Mac with no fans at all. **Not band 0**: band 0 on a fanned Mac
    /// means fans nearly stopped — a machine coasting on passive convection
    /// through ducting designed for forced air. A fanless Air's entire
    /// thermal design assumes no fan. Each machine only ever produces one of
    /// the two, so merging them costs nothing today and is a category error
    /// the first time someone reads the file.
    case fanless
    /// Deciles of `actualRPM / maxRPM`, 0...9, each fan against its own
    /// maximum so the bucket edges are portable across machines with
    /// different fan ranges.
    case decile(Int)

    /// Band width as a fraction of the fan's own maximum.
    ///
    /// From the measured pair above: ΔR/R ≈ −16 % across Δfraction ≈ 0.35,
    /// i.e. ~4.6 % of `R` per 0.10 of fan range. A 10 %-wide band therefore
    /// admits ~4.6 % of `R` edge-to-edge — and the trend's within-band drift
    /// gate cuts the residual to ~1.4 %, which is what makes its 10 %
    /// threshold a 4× margin over noise instead of a 2× one. If a future
    /// measurement finds a steeper fan dependence, this is the constant to
    /// narrow — not the trend threshold to raise.
    public static let width = 0.10

    /// The band a fraction of maximum falls in.
    public static func band(forFraction fraction: Double) -> FanBand {
        .decile(Int((fraction / width).rounded(.down)).clamped(to: 0 ... 9))
    }

    /// The fraction range this band covers, or `nil` for `.fanless`.
    public var fractionRange: ClosedRange<Double>? {
        guard case let .decile(n) = self else { return nil }
        return (Double(n) * Self.width) ... (Double(n + 1) * Self.width)
    }

    /// Deterministic ordering / coding key: `.fanless` is −1, deciles 0...9.
    public var sortKey: Int {
        switch self {
        case .fanless: -1
        case let .decile(n): n
        }
    }
}

extension FanBand: Codable {
    /// Encodes as one integer: −1 for `.fanless`, 0...9 for deciles. Pinned
    /// by a test — changing the sentinel would silently re-file history.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        self = raw < 0 ? .fanless : .decile(raw.clamped(to: 0 ... 9))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sortKey)
    }
}

/// The fan context a cooling record is stamped with, measured from one
/// snapshot's fans.
public struct FanContext: Sendable, Equatable {
    public let band: FanBand
    /// Mean of per-fan `actualRPM / maxRPM` across usable fans.
    public let meanFraction: Double
    /// Mean actual RPM — display currency; not reconstructible from the
    /// fraction without a `maxRPM` the record does not carry.
    public let meanRPM: Double
    public let fanCount: Int
    /// Max − min of per-fan fractions. One stopped fan reads ~0.9 here; the
    /// recorder refuses on it rather than filing a fiction of an average.
    public let disagreement: Double

    /// The context of one snapshot's fans, or `nil` when they cannot be read
    /// well enough to say.
    ///
    /// Three distinct outcomes, deliberately:
    /// - no fans at all → `.fanless` (the feature works fine there);
    /// - fans present but none passes `hasUsableRange` → `nil` — "we cannot
    ///   tell what the fans are doing" is not "there are no fans", and
    ///   conflating them would file a broken-read Mac under `.fanless`
    ///   forever;
    /// - usable fans → a decile of the mean fraction, each fan against its
    ///   own maximum.
    public static func measure(_ fans: [Fan]) -> FanContext? {
        guard !fans.isEmpty else {
            return FanContext(band: .fanless, meanFraction: 0, meanRPM: 0, fanCount: 0, disagreement: 0)
        }
        let usable = fans.filter(\.hasUsableRange)
        guard !usable.isEmpty else { return nil }
        let fractions = usable.map { ($0.actualRPM / $0.maxRPM).clamped(to: 0 ... 1) }
        let mean = fractions.reduce(0, +) / Double(fractions.count)
        return FanContext(
            band: .band(forFraction: mean),
            meanFraction: mean,
            meanRPM: usable.map(\.actualRPM).reduce(0, +) / Double(usable.count),
            fanCount: usable.count,
            disagreement: (fractions.max() ?? 0) - (fractions.min() ?? 0)
        )
    }
}
