// CoolingHistoryChartModelTests.swift — the chart's data rules: no line across a gap, no clipped axis.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("CoolingHistoryChartModel — what the history chart may draw")
struct CoolingHistoryChartModelTests {
    private func aggregate(day: Int, median: Double = 0.51, count: Int = 3) -> CoolingDayAggregate {
        CoolingDayAggregate(
            day: day, band: .decile(3), median: median, p25: median, p75: median,
            count: count, medianFanFraction: 0.34, medianWatts: 19.6
        )
    }

    /// A line across a gap asserts continuity nothing measured — the settle
    /// rule's refusal, applied at the days scale.
    @Test("The median line breaks wherever more than three days have no reading")
    func lineBreaksAtGaps() {
        let points = CoolingHistoryChartModel.points([
            aggregate(day: 100), aggregate(day: 101), aggregate(day: 103), // ≤ 3-day steps join
            aggregate(day: 110), aggregate(day: 111), // a week's silence splits
        ])
        let runs = CoolingHistoryChartModel.medianRuns(points)
        #expect(runs.map(\.count) == [3, 2], "got \(runs.map(\.count))")
    }

    /// A fixed ceiling would clip exactly the dusty machine this chart
    /// exists for.
    @Test("The y-axis always covers the worst reading with headroom, from zero")
    func yDomainNeverClips() {
        let clean = CoolingHistoryChartModel.yDomain(
            CoolingHistoryChartModel.points([aggregate(day: 1, median: 0.51)])
        )
        #expect(clean.lowerBound == 0)
        #expect(clean.upperBound == 1.2, "small readings keep the standard scale")

        let dusty = CoolingHistoryChartModel.yDomain(
            CoolingHistoryChartModel.points([aggregate(day: 1, median: 1.9)])
        )
        #expect(dusty.upperBound >= 1.9 * 1.2, "a 1.9 reading must sit inside the axis, not on it")
    }

    @Test("Band options come most-evidence-first, so the default selection has the most to say")
    func bandOptionsSortByEvidence() {
        let options = CoolingHistoryChartModel.bandOptions([
            .decile(3): [aggregate(day: 1, count: 2)],
            .decile(9): [aggregate(day: 1, count: 5), aggregate(day: 2, count: 5)],
        ])
        #expect(options.map(\.band) == [.decile(9), .decile(3)])
        #expect(options.first?.readings == 10)
    }

    /// A decile's lower edge can sit below the fan's own floor; naming
    /// speeds the fan cannot do would be a small lie on every label.
    @Test("Band labels speak RPM and clamp to the fan's real floor")
    func rpmLabelsClampToTheFloor() {
        #expect(
            CoolingHistoryChartModel.rpmLabel(.decile(3), minRPM: 2317, maxRPM: 6800)
                == "2317–2720 RPM",
            "decile 3 starts at 2040 RPM, below the 2317 floor — the floor wins"
        )
        #expect(
            CoolingHistoryChartModel.rpmLabel(.decile(8), minRPM: 2317, maxRPM: 6800)
                == "5440–6120 RPM"
        )
        #expect(CoolingHistoryChartModel.rpmLabel(.fanless, minRPM: 0, maxRPM: 0) == "No fans")
    }

    /// The low deciles are not hypothetical: the fans genuinely read 0 RPM in
    /// mode 3 when the Mac is cool, and `FanContext.measure` bands on
    /// `actualRPM / maxRPM`, so a real record can carry `.decile(0)`. Clamping
    /// only the lower edge made those labels read backwards — "2317–680 RPM".
    @Test("A decile entirely below the fan's floor still reads forwards")
    func rpmLabelsNeverInvert() {
        for decile in 0 ... 9 {
            let label = CoolingHistoryChartModel.rpmLabel(.decile(decile), minRPM: 2317, maxRPM: 6800)
            let bounds = label
                .replacingOccurrences(of: " RPM", with: "")
                .split(separator: "–")
                .compactMap { Int($0) }
            #expect(bounds.count == 2, "decile \(decile) produced \(label)")
            if bounds.count == 2 {
                #expect(bounds[0] <= bounds[1], "decile \(decile) reads backwards: \(label)")
            }
        }
    }
}
