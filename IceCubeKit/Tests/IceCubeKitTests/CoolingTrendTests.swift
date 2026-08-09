// CoolingTrendTests.swift — the claims the trend may make, and the many it may not.

import Foundation
@testable import IceCubeKit
import Testing

/// The one unacceptable failure mode is a confident false "your cooling
/// degraded". Every threshold clears the noise measured on real hardware,
/// every refusal is reachable, and the mutations that would fake a verdict —
/// dropping the band key, flipping the sign, averaging instead of taking the
/// median, scanning for a favourable baseline — each have a named test here.
@Suite("CoolingTrend — verdicts and refusals")
struct CoolingTrendTests {
    /// Midnight UTC, so day arithmetic is exact.
    private static let epoch = Date(timeIntervalSince1970: 1_753_056_000)
    private static let day0 = CoolingStatistics.dayIndex(epoch)
    private static let machine = MachineFingerprint(
        modelIdentifier: "Mac14,9", fanCount: 2, fanMaxRPM: [6800, 6800],
        isSimulated: false, serialNumber: "TESTSERIAL", salt: "0f"
    )

    // MARK: - History synthesis

    private func makeHistory() -> CoolingHistory {
        CoolingHistory(machine: Self.machine, createdAt: Self.epoch)
    }

    private func date(day: Int, hour: Double) -> Date {
        Self.epoch.addingTimeInterval(Double(day) * 86400 + hour * 3600)
    }

    /// 23:59 on the given day — evaluation time that keeps the whole day's
    /// records in the past.
    private func endOfDay(_ day: Int) -> Date {
        Self.epoch.addingTimeInterval(Double(day + 1) * 86400 - 60)
    }

    private func record(
        _ date: Date, r: Double, band: FanBand = .decile(5), fraction: Double = 0.55
    ) -> CoolingRecord {
        CoolingRecord(
            date: date, resistance: r, dieCelsius: 49, ambientCelsius: 39, watts: 20,
            band: band, fanFraction: fraction, fanRPM: fraction * 6800,
            sampleCount: 21, durationSeconds: 20
        )
    }

    /// Adds one day of readings: three per day, jittered ±2 % (the measured
    /// repeatability) in a pattern whose median is exactly `r`.
    private func addDay(
        _ history: inout CoolingHistory, day: Int, r: Double,
        band: FanBand = .decile(5), fraction: Double = 0.55
    ) {
        for (index, hour) in [9.0, 12.0, 15.0].enumerated() {
            let jitter = [1.02, 0.98, 1.0][index]
            let at = date(day: day, hour: hour)
            history.append(record(at, r: r * jitter, band: band, fraction: fraction), now: at)
        }
    }

    // MARK: - The healthy cases

    @Test("A flat history is stable")
    func aFlatHistoryIsStable() {
        var history = makeHistory()
        for day in 0 ..< 120 {
            addDay(&history, day: day, r: 0.91)
        }
        guard case let .stable(comparison) = CoolingTrend.evaluate(history, now: endOfDay(119)) else {
            Issue.record("expected stable, got \(CoolingTrend.evaluate(history, now: endOfDay(119)))")
            return
        }
        #expect(abs(comparison.resistanceChangeFraction) < 0.03)
    }

    @Test("A twenty percent drift over four months is a slow rise, since the earliest window")
    func aTwentyPercentDriftIsASlowRise() {
        var history = makeHistory()
        for day in 0 ..< 120 {
            addDay(&history, day: day, r: 0.91 + 0.18 * Double(day) / 119)
        }
        guard case let .slowRise(comparison) = CoolingTrend.evaluate(history, now: endOfDay(119)) else {
            Issue.record("expected slowRise")
            return
        }
        #expect(comparison.resistanceChangeFraction > CoolingTrend.slowRiseThreshold)
        let sinceDay = CoolingStatistics.dayIndex(comparison.since) - Self.day0
        #expect(sinceDay < 20, "the baseline is the earliest window, so 'since' names the start")
    }

    /// The sign is the classic mutation: positive must mean R rose, which
    /// means cooling got WORSE. Pinned in both directions.
    @Test("The sign convention is pinned in both directions")
    func theSignConventionIsPinned() {
        var worse = makeHistory()
        var better = makeHistory()
        for day in 0 ..< 60 {
            addDay(&worse, day: day, r: day < 30 ? 0.90 : 1.08)
            addDay(&better, day: day, r: day < 30 ? 1.08 : 0.90)
        }
        guard case let .slowRise(rise) = CoolingTrend.evaluate(worse, now: endOfDay(59)),
              case let .improved(fall) = CoolingTrend.evaluate(better, now: endOfDay(59))
        else {
            Issue.record("expected slowRise and improved")
            return
        }
        #expect(rise.resistanceChangeFraction > 0, "rise is positive, positive is worse")
        #expect(fall.resistanceChangeFraction < 0, "improvement is negative")
    }

    /// There is no refusal available for a real 9 % drift — the data exists —
    /// so `stable` carries the number and the copy layer decides between
    /// "unchanged" and "slightly higher, not enough to call".
    @Test("A nine percent drift is still reported stable, and carries the number")
    func aNinePercentDriftIsStillStable() {
        var history = makeHistory()
        for day in 0 ..< 60 {
            addDay(&history, day: day, r: day < 46 ? 0.91 : 0.99)
        }
        guard case let .stable(comparison) = CoolingTrend.evaluate(history, now: endOfDay(59)) else {
            Issue.record("expected stable — 8.8 % is under the 10 % bar")
            return
        }
        #expect(comparison.resistanceChangeFraction > 0.05, "and the number survives to the copy layer")
    }

    /// Synthesised from THERMAL.md's actual three 5950 RPM readings. The
    /// thresholds must clear the noise measured on real hardware — this is
    /// the test that fails first if the constants are ever tuned down.
    @Test("The spread measured on real hardware does not produce a verdict")
    func measuredHardwareSpreadIsStable() {
        var history = makeHistory()
        let measured = [0.91, 0.93, 0.89]
        for day in 0 ..< 120 {
            let at = date(day: day, hour: 12)
            for (index, r) in measured.enumerated() {
                let when = date(day: day, hour: 9 + Double(index) * 3)
                history.append(record(when, r: r), now: when)
            }
            _ = at
        }
        guard case let .stable(comparison) = CoolingTrend.evaluate(history, now: endOfDay(119)) else {
            Issue.record("real repeatability must not read as degradation")
            return
        }
        #expect(abs(comparison.resistanceChangeFraction) < 0.05)
    }

    /// The settle rule's rare failures all push R UP — THERMAL.md records a
    /// real 1.89 °C/W transient beside the true 1.04. One such outlier per
    /// day for two weeks must not move the verdict. The mutation is mean
    /// instead of median, at either the day or the epoch level.
    @Test("The worst readings cannot drag the verdict")
    func outliersCannotDragTheVerdict() {
        var history = makeHistory()
        for day in 0 ..< 120 {
            addDay(&history, day: day, r: 0.91)
            if day >= 106 { // one transient every recent day
                let at = date(day: day, hour: 18)
                history.append(record(at, r: 1.89), now: at)
            }
        }
        let verdict = CoolingTrend.evaluate(history, now: endOfDay(119))
        guard case .stable = verdict else {
            Issue.record("a daily 1.89 transient outvoted three honest readings: \(verdict)")
            return
        }
    }

    // MARK: - The sudden jump

    @Test("A jump in the last day is a sudden jump")
    func aJumpInTheLastDayIsASuddenJump() {
        var history = makeHistory()
        for day in 0 ..< 40 {
            addDay(&history, day: day, r: 0.95)
        }
        for step in 0 ..< 6 { // six readings across 2.5 h, all +21 %
            let at = date(day: 40, hour: 18 + Double(step) * 0.5)
            history.append(record(at, r: 1.15), now: at)
        }
        guard case let .suddenJump(band, change, _, readings) =
            CoolingTrend.evaluate(history, now: endOfDay(40))
        else {
            Issue.record("expected suddenJump")
            return
        }
        #expect(band == .decile(5))
        #expect(change > CoolingTrend.suddenJumpThreshold)
        #expect(readings == 6)
    }

    /// Deliberately ahead of collectingBaseline: "R rose 18 % yesterday" is
    /// actionable on day 15, and withholding it for the seasonal baseline
    /// would suppress the urgent finding for the sake of the slow one. The
    /// mutation is reordering the checks.
    @Test("A jump is reported before the seasonal baseline exists")
    func aJumpBeatsCollectingBaseline() {
        var history = makeHistory()
        for day in 0 ..< 15 {
            addDay(&history, day: day, r: 0.95)
        }
        for step in 0 ..< 6 {
            let at = date(day: 15, hour: 18 + Double(step) * 0.5)
            history.append(record(at, r: 1.20), now: at)
        }
        guard case .suddenJump = CoolingTrend.evaluate(history, now: endOfDay(15)) else {
            Issue.record("fifteen days of history is enough for the jump, not the baseline")
            return
        }
    }

    /// Five readings inside 25 minutes could be one anomalous sitting; the
    /// loudest verdict needs at least an hour. Consequence, accepted: the
    /// jump lags the event by an hour — the seconds-scale stopped-fan case
    /// is ThermalDiagnosis.Cooling.stalled's job, not this one's.
    @Test("A twenty-five minute anomaly is not a jump")
    func aBriefAnomalyIsNotAJump() {
        var history = makeHistory()
        for day in 0 ..< 15 {
            addDay(&history, day: day, r: 0.95)
        }
        for step in 0 ..< 5 {
            let at = date(day: 15, hour: 18 + Double(step) * 0.1) // 5 readings in 24 min
            history.append(record(at, r: 1.30), now: at)
        }
        guard case .collectingBaseline = CoolingTrend.evaluate(history, now: endOfDay(15)) else {
            Issue.record("a 24-minute burst must not fire the loudest verdict")
            return
        }
    }

    // MARK: - Collecting, and the refusals

    @Test("A fresh install collects rather than refusing, and names the finish line")
    func aFreshInstallCollects() {
        var history = makeHistory()
        for day in 0 ..< 3 {
            addDay(&history, day: day, r: 0.91)
        }
        guard case let .collectingBaseline(since, readyAfter) =
            CoolingTrend.evaluate(history, now: endOfDay(2))
        else {
            Issue.record("expected collectingBaseline")
            return
        }
        #expect(CoolingStatistics.dayIndex(since) == Self.day0)
        #expect(
            CoolingStatistics.dayIndex(readyAfter) == Self.day0
                + CoolingTrend.minimumSeparationDays + CoolingTrend.baselineSpanDays,
            "ready at day 44, stated as a date the copy can show"
        )
    }

    @Test("An empty history is not the same as a young one")
    func emptyIsNotYoung() {
        #expect(CoolingTrend.evaluate(makeHistory(), now: Self.epoch) == .noHistory)
        var young = makeHistory()
        addDay(&young, day: 0, r: 0.91)
        guard case .collectingBaseline = CoolingTrend.evaluate(young, now: endOfDay(0)) else {
            Issue.record("one day of data is collecting, not nothing")
            return
        }
    }

    /// Epochs that touch could share a weather system, a workload, a road
    /// trip. The 30-day separation must hold even when data exists on both
    /// sides — the mutation is shrinking it.
    @Test("A history spanning 43 days still collects; 45 days compares")
    func epochsThatWouldTouchAreNeverCompared() {
        var short = makeHistory()
        var enough = makeHistory()
        for day in 0 ..< 43 {
            addDay(&short, day: day, r: 0.91)
        }
        for day in 0 ..< 45 {
            addDay(&enough, day: day, r: 0.91)
        }
        guard case .collectingBaseline = CoolingTrend.evaluate(short, now: endOfDay(42)) else {
            Issue.record("43 days is one short of the first verdict")
            return
        }
        guard case .stable = CoolingTrend.evaluate(enough, now: endOfDay(44)) else {
            Issue.record("45 days is exactly enough")
            return
        }
    }

    /// The band-mismatch refusal. Dropping the band from the grouping key
    /// would compare idle readings against loaded ones and report a
    /// confident ~16 % slowRise from the same data — the exact lie the
    /// banding exists to prevent.
    @Test("Readings split across two bands refuse rather than merging")
    func splitBandsRefuse() {
        var history = makeHistory()
        for day in 0 ..< 21 {
            addDay(&history, day: day, r: 0.91, band: .decile(5), fraction: 0.55)
        }
        for day in 50 ..< 64 {
            addDay(&history, day: day, r: 1.06, band: .decile(8), fraction: 0.85)
        }
        guard case .insufficientComparableReadings =
            CoolingTrend.evaluate(history, now: endOfDay(63))
        else {
            Issue.record("no band has both epochs — merging them would fake a slowRise")
            return
        }
    }

    /// Same band is not the same fan speed: a baseline at the band's low
    /// edge against a recent at its high edge fakes an improvement of up to
    /// 4.6 %. Deleting the drift gate is the mutation.
    @Test("Fan drift within one band refuses rather than claiming an improvement")
    func withinBandDriftRefuses() {
        var history = makeHistory()
        for day in 0 ..< 50 {
            addDay(&history, day: day, r: 0.95, band: .decile(8), fraction: 0.805)
        }
        for day in 50 ..< 64 {
            addDay(&history, day: day, r: 0.84, band: .decile(8), fraction: 0.885)
        }
        guard case let .insufficientComparableReadings(reason, _) =
            CoolingTrend.evaluate(history, now: endOfDay(63))
        else {
            Issue.record("faster fans, not better cooling — must refuse, not report improved")
            return
        }
        guard case .fanSpeedDrifted = reason else {
            Issue.record("the reason must name the drift, got \(reason)")
            return
        }
    }

    @Test("Four recent days of data is not enough")
    func fourRecentDaysIsNotEnough() {
        var history = makeHistory()
        for day in 0 ..< 46 {
            addDay(&history, day: day, r: 0.91)
        }
        for day in 56 ..< 60 { // the machine was off for ten days, then four days of use
            addDay(&history, day: day, r: 0.91)
        }
        guard case let .insufficientComparableReadings(reason, _) =
            CoolingTrend.evaluate(history, now: endOfDay(59))
        else {
            Issue.record("four day-medians cannot anchor an epoch")
            return
        }
        guard case .tooFewRecentDays(4, _) = reason else {
            Issue.record("expected tooFewRecentDays(4, _), got \(reason)")
            return
        }
    }

    @Test("Five recent days with one reading each is not enough")
    func fiveSparseDaysIsNotEnough() {
        var history = makeHistory()
        for day in 0 ..< 46 {
            addDay(&history, day: day, r: 0.91)
        }
        for day in 55 ..< 60 {
            let at = date(day: day, hour: 12)
            history.append(record(at, r: 0.91), now: at)
        }
        guard case .insufficientComparableReadings =
            CoolingTrend.evaluate(history, now: endOfDay(59))
        else {
            Issue.record("five single readings are five points, not an epoch")
            return
        }
    }

    // MARK: - Baseline selection

    /// Oldest-first is a pre-specified choice, not a search for a result —
    /// the mutation is scanning newest-first, which would quietly shrink
    /// every claim's lever arm.
    @Test("The baseline is the earliest qualifying window")
    func baselineIsTheEarliestWindow() {
        var history = makeHistory()
        for day in 0 ..< 300 {
            addDay(&history, day: day, r: 0.91)
        }
        guard case let .stable(comparison) = CoolingTrend.evaluate(history, now: endOfDay(299)) else {
            Issue.record("expected stable")
            return
        }
        #expect(
            CoolingStatistics.dayIndex(comparison.since) - Self.day0 < 20,
            "'since' names the start of history, not the nearest qualifying month"
        )
    }

    @Test("A baseline older than a year is not used")
    func baselineOlderThanAYearIsNotUsed() {
        var history = makeHistory()
        for day in 0 ..< 500 {
            addDay(&history, day: day, r: 0.91)
        }
        guard case let .stable(comparison) = CoolingTrend.evaluate(history, now: endOfDay(499)) else {
            Issue.record("expected stable")
            return
        }
        let sinceDay = CoolingStatistics.dayIndex(comparison.since) - Self.day0
        #expect(sinceDay >= 499 - CoolingTrend.maxBaselineAgeDays, "beyond a year is a different experiment")
    }

    /// A cleaning resets what the baseline means. Without the mark, sixty
    /// post-cleaning days still read `improved` against the dusty past —
    /// odd by month three. With it, the baseline starts after the mark.
    @Test("The baseline never spans a service mark")
    func baselineNeverSpansAServiceMark() {
        func build(marked: Bool) -> CoolingHistory {
            var history = makeHistory()
            for day in 0 ..< 60 {
                addDay(&history, day: day, r: 1.10)
            }
            if marked {
                history.markServiced(at: date(day: 60, hour: 8))
            }
            for day in 60 ..< 120 {
                addDay(&history, day: day, r: 0.90)
            }
            return history
        }
        guard case .improved = CoolingTrend.evaluate(build(marked: false), now: endOfDay(119)) else {
            Issue.record("without the mark the cleaning reads as an improvement — expected")
            return
        }
        guard case .stable = CoolingTrend.evaluate(build(marked: true), now: endOfDay(119)) else {
            Issue.record("with the mark the baseline restarts and the verdict is stable")
            return
        }
    }

    @Test("A fanless Mac gets a verdict like any other")
    func fanlessMacGetsAVerdict() {
        var history = makeHistory()
        for day in 0 ..< 60 {
            addDay(
                &history, day: day, r: 0.91 + 0.18 * Double(day) / 59,
                band: .fanless, fraction: 0
            )
        }
        guard case .slowRise = CoolingTrend.evaluate(history, now: endOfDay(59)) else {
            Issue.record("no fans does not mean no verdict")
            return
        }
    }
}
