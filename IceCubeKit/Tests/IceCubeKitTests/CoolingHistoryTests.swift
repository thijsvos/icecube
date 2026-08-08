// CoolingHistoryTests.swift — what the history file may never grow into, and the statistics under it.

import Foundation
@testable import IceCubeKit
import Testing

/// Retention is the contract that lets the trend run on the main actor and
/// the file live forever: every bound is re-established on every append, and
/// none of them may silently eat the baseline the feature exists to keep.
@Suite("CoolingHistory — retention and folding")
struct CoolingHistoryTests {
    private static let machine = MachineFingerprint(
        modelIdentifier: "Mac14,9", fanCount: 2, fanMaxRPM: [6800, 6800],
        isSimulated: false, serialNumber: "TESTSERIAL", salt: "0f"
    )
    /// Midnight UTC, so day arithmetic in tests is exact.
    private static let epoch = Date(timeIntervalSince1970: 1_753_056_000)

    private func record(
        _ date: Date, r: Double = 0.91, band: FanBand = .decile(5),
        fraction: Double = 0.55, watts: Double = 20
    ) -> CoolingRecord {
        CoolingRecord(
            date: date, resistance: r, dieCelsius: 49, ambientCelsius: 39, watts: watts,
            band: band, fanFraction: fraction, fanRPM: fraction * 6800,
            sampleCount: 21, durationSeconds: 20
        )
    }

    // MARK: - Raw tier

    /// `maximumRawRecords` is exactly 7 × 288 — what seven days at the
    /// recorder's spacing can produce — so the time window and the count cap
    /// say the same thing. The time cap must always bite first.
    @Test("Records at the minimum spacing can never exceed the raw cap, and time bites first")
    func rawTierIsBoundedByTimeBeforeCount() {
        var history = CoolingHistory(machine: Self.machine, createdAt: Self.epoch)
        var now = Self.epoch
        for i in 0 ..< 4000 { // ~13.9 days at one record per 300 s
            now = Self.epoch.addingTimeInterval(Double(i) * 300)
            history.append(record(now), now: now)
        }
        #expect(history.records.count <= CoolingHistory.maximumRawRecords)
        let oldest = history.records.first?.date ?? .distantPast
        #expect(
            now.timeIntervalSince(oldest) <= Double(CoolingHistory.rawRetentionDays) * 86400,
            "the day window pruned before the count cap ever had to"
        )
    }

    @Test("Today is not folded while it is still happening")
    func todayIsNotFolded() {
        var history = CoolingHistory(machine: Self.machine, createdAt: Self.epoch)
        let now = Self.epoch.addingTimeInterval(3600 * 6)
        history.append(record(now), now: now)
        #expect(history.days.isEmpty, "an incomplete day stays raw")
        #expect(history.records.count == 1)
    }

    /// An unsynced clock at boot writes records dated 2030; one of those
    /// would poison "recent" forever.
    @Test("A record from the future is dropped; plausible skew is kept")
    func futureRecordsAreDropped() {
        var history = CoolingHistory(machine: Self.machine, createdAt: Self.epoch)
        let now = Self.epoch
        history.append(record(now.addingTimeInterval(7200)), now: now)
        #expect(history.records.isEmpty, "two hours ahead is a wrong clock")
        history.append(record(now.addingTimeInterval(600)), now: now)
        #expect(history.records.count == 1, "ten minutes is ordinary skew")
    }

    // MARK: - Aggregate tier

    @Test("Aggregates age out at two years")
    func aggregatesAgeOut() {
        var history = CoolingHistory(machine: Self.machine, createdAt: Self.epoch)
        var now = Self.epoch
        for day in 0 ..< 800 {
            now = Self.epoch.addingTimeInterval(Double(day) * 86400 + 43200)
            history.append(record(now), now: now)
        }
        let today = CoolingStatistics.dayIndex(now)
        #expect(history.days.allSatisfy { $0.day >= today - CoolingHistory.maximumDayAgeDays })
        #expect(!history.days.isEmpty)
    }

    /// A naive FIFO cap would evict the baseline — the exact thing the
    /// feature exists to compare against — and the failure would be
    /// invisible: the verdict just degrades to "not enough data" one day.
    @Test("The count cap thins the middle, never the oldest ninety days")
    func countCapPreservesTheBaseline() throws {
        var history = CoolingHistory(machine: Self.machine, createdAt: Self.epoch)
        var now = Self.epoch
        // Ten bands every day for 500 days: 5000 aggregates, over the cap.
        for day in 0 ..< 500 {
            for tenth in 0 ..< 10 {
                let fraction = Double(tenth) / 10 + 0.05
                now = Self.epoch.addingTimeInterval(Double(day) * 86400 + Double(tenth) * 3600)
                history.append(
                    record(now, band: .decile(tenth), fraction: fraction), now: now
                )
            }
        }
        history.compact(now: now)
        #expect(history.days.count <= CoolingHistory.maximumDayAggregates)
        let firstDay = try #require(history.days.first?.day)
        let protected = history.days.filter { $0.day <= firstDay + CoolingHistory.protectedOldestDays }
        #expect(
            protected.count >= 90 * 10,
            "the oldest ninety days survive intact, got \(protected.count) entries"
        )

        // While the worst-case file is in hand, pin its size. Typical use
        // (2–4 bands/day) is a few hundred kilobytes; this pathological
        // 10-band machine is the ceiling.
        let encoded = try history.encoded()
        #expect(encoded.count < 2_500_000, "worst-case file is \(encoded.count) bytes")
    }

    // MARK: - Folding

    @Test("Folding is idempotent — compacting twice is byte-identical")
    func foldingIsIdempotent() {
        var history = CoolingHistory(machine: Self.machine, createdAt: Self.epoch)
        var now = Self.epoch
        for day in 0 ..< 30 {
            for hour in [9.0, 12.0, 15.0] {
                now = Self.epoch.addingTimeInterval(Double(day) * 86400 + hour * 3600)
                history.append(record(now, r: 0.9 + Double(day % 3) * 0.01), now: now)
            }
        }
        var again = history
        again.compact(now: now)
        again.compact(now: now)
        #expect(again == { var h = history; h.compact(now: now); return h }())
    }

    /// The invariant that keeps a quit-and-relaunch from changing the
    /// answer: the verdict is a pure function of the appended stream, not of
    /// when compaction happened to run.
    @Test("The verdict does not depend on when compact last ran")
    func verdictIndependentOfCompactTiming() {
        func build() -> CoolingHistory {
            var history = CoolingHistory(machine: Self.machine, createdAt: Self.epoch)
            for day in 0 ..< 60 {
                for hour in [9.0, 12.0, 15.0] {
                    let date = Self.epoch.addingTimeInterval(Double(day) * 86400 + hour * 3600)
                    history.append(record(date, r: 0.91), now: date)
                }
            }
            return history
        }
        // The machine then sits closed for three weeks: no appends, no
        // compacts. Evaluating must give the same verdict whether or not a
        // compaction happened just before.
        let now = Self.epoch.addingTimeInterval(81 * 86400)
        let unclean = build()
        var clean = build()
        clean.compact(now: now)
        #expect(
            CoolingTrend.evaluate(unclean, now: now) == CoolingTrend.evaluate(clean, now: now)
        )
    }

    // MARK: - The statistics under it all

    /// The test values deliberately include an outlier, so a mean cannot
    /// masquerade: on `[1, 2, 3, 4]` mean and median coincide at 2.5 and the
    /// mutation walks straight through.
    @Test("A median of an even count averages the two middle values — and is not a mean")
    func medianOfEvenCount() {
        #expect(CoolingStatistics.median([1, 2, 3, 100]) == 2.5, "a mean would say 26.5")
        #expect(CoolingStatistics.median([1, 2, 10]) == 2, "a mean would say 4.33")
        #expect(CoolingStatistics.median([3, 1]) == 2)
        #expect(CoolingStatistics.median([5]) == 5)
        #expect(CoolingStatistics.median([]) == nil)
    }

    @Test("Percentiles are nearest-rank and do not interpolate")
    func percentilesAreNearestRank() {
        #expect(CoolingStatistics.percentile([1, 2, 3, 4], 25) == 1)
        #expect(CoolingStatistics.percentile([1, 2, 3, 4], 75) == 3)
        #expect(CoolingStatistics.percentile([1, 2, 3, 4], 100) == 4)
        #expect(CoolingStatistics.percentile([7], 25) == 7)
    }

    @Test("Day indices bucket at UTC midnight and name back as UTC noon")
    func dayIndexingIsUTC() {
        let day = CoolingStatistics.dayIndex(Self.epoch)
        #expect(CoolingStatistics.dayIndex(Self.epoch.addingTimeInterval(86399)) == day)
        #expect(CoolingStatistics.dayIndex(Self.epoch.addingTimeInterval(86400)) == day + 1)
        let named = CoolingStatistics.dayDate(day)
        #expect(named.timeIntervalSince(Self.epoch) == 43200, "named at noon, unambiguous")
    }
}
