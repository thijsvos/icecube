// CoolingHistoryChartModel.swift — the history chart's data decisions, out of the view and under test.

import Foundation

/// Prepares `CoolingTrend.seriesByBand` output for drawing. Every decision a
/// chart could get quietly wrong lives here rather than in a `View` body: no
/// line may span a data gap, the y-axis must never clip a dusty Mac, and the
/// band labels speak RPM, not decile numbers.
public enum CoolingHistoryChartModel {
    /// One band the picker can offer, with the evidence behind it.
    public struct BandOption: Sendable, Equatable, Identifiable {
        public let band: FanBand
        public let days: Int
        public let readings: Int

        public var id: Int {
            band.sortKey
        }
    }

    /// One day's dot on the chart.
    public struct DayPoint: Sendable, Equatable, Identifiable {
        /// The day's UTC noon.
        public let date: Date
        public let median: Double
        public let readings: Int

        public var id: Date {
            date
        }

        init(_ aggregate: CoolingDayAggregate) {
            date = CoolingStatistics.dayDate(aggregate.day)
            median = aggregate.median
            readings = aggregate.count
        }
    }

    /// Bands worth offering, most evidence first — the default selection is
    /// the first. Never overlaid: cross-band comparison is the exact thing
    /// the physics forbids, so the chart shows one band at a time.
    public static func bandOptions(
        _ series: [FanBand: [CoolingDayAggregate]]
    ) -> [BandOption] {
        series
            .map { band, aggregates in
                BandOption(
                    band: band,
                    days: aggregates.count,
                    readings: aggregates.map(\.count).reduce(0, +)
                )
            }
            .sorted { ($0.readings, $1.band.sortKey) > ($1.readings, $0.band.sortKey) }
    }

    public static func points(_ series: [CoolingDayAggregate]) -> [DayPoint] {
        series.map(DayPoint.init)
    }

    /// The median line's contiguous runs, broken wherever more than three
    /// days pass with no reading. A line drawn across a gap asserts
    /// continuity nothing measured — the same lie the settle rule refuses at
    /// the seconds scale, refused here at the days scale.
    public static func medianRuns(_ points: [DayPoint]) -> [[DayPoint]] {
        var runs: [[DayPoint]] = []
        for point in points {
            if let last = runs.last?.last,
               point.date.timeIntervalSince(last.date) <= 3 * 86400
            {
                runs[runs.count - 1].append(point)
            } else {
                runs.append([point])
            }
        }
        return runs
    }

    /// The y-axis for a set of points: zero-based, covering the worst reading
    /// with headroom, rounded up to a tidy 0.1.
    ///
    /// Not hardcoded like the dashboard's 20–110 °C — `R` has no universal
    /// range (0.3 on one machine, 1.2 on another, higher still on a dusty
    /// one), and a fixed ceiling would clip exactly the machine this chart
    /// exists for. Computed once when the window opens and held for its
    /// lifetime, which honours the anti-jump rule: the axis must not rescale
    /// *while you watch*; on open is not while you watch.
    public static func yDomain(_ points: [DayPoint]) -> ClosedRange<Double> {
        let top = points.map(\.median).max() ?? 1
        return 0 ... max(1.2, (top * 1.25 * 10).rounded(.up) / 10)
    }

    /// "2317–2720 RPM" for decile 3 of a 2317–6800 fan, clamped to the fan's
    /// real floor — that band's own lower edge is 2040 RPM, below the minimum
    /// the fan can actually turn, and naming a speed it cannot do would be a
    /// small lie on every label.
    ///
    /// The edges are plain fractions of `maxRPM` (`n/10 … (n+1)/10`,
    /// ``FanBand/width`` apart), with the floor applied to **both** ends. Only
    /// the lower one was clamped until 2026-08-16, so a band lying entirely
    /// below the floor printed backwards — decile 0 of that same fan read
    /// "2317–680 RPM". Those low deciles are reachable rather than theoretical:
    /// the fans genuinely report 0 RPM in mode 3 when the Mac is cool, and
    /// `FanContext.measure` bands on `actualRPM / maxRPM`. A band collapsed to
    /// its floor at both ends reads as a single speed, which is the truth about
    /// a fan that cannot go slower. `.fanless` says so in words.
    public static func rpmLabel(_ band: FanBand, minRPM: Double, maxRPM: Double) -> String {
        guard let range = band.fractionRange else { return "No fans" }
        let low = max(minRPM, range.lowerBound * maxRPM)
        // The floor is applied to the upper edge too, or the label inverts. The
        // low deciles are genuinely reachable on Mac14,9 — the fans read 0 RPM in
        // mode 3 when cool, and `FanContext.measure` bands on `actualRPM/maxRPM`
        // — so decile 0 of a 2317–6800 fan used to render "2317–680 RPM".
        let high = max(low, range.upperBound * maxRPM)
        return "\(Int(low.rounded()))–\(Int(high.rounded())) RPM"
    }
}
