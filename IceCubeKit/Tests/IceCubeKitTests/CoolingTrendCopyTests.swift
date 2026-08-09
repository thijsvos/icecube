// CoolingTrendCopyTests.swift — the trend's words: refusals stay refusals, and no claim outruns the data.

import Foundation
@testable import IceCubeKit
import Testing

/// The copy is where an honest verdict could still become a dishonest
/// sentence. These pin the direction words, the unsigned percent, the
/// month-naming rules, and the property the whole layer exists for: a
/// refusal is never mistakable for an answer.
@Suite("CoolingTrendCopy — the words on the trend")
struct CoolingTrendCopyTests {
    /// Fixed UTC Gregorian + en_US: copy tests that inherit the machine's
    /// locale pass on the owner's Mac and fail in CI — the Dutch-locale
    /// lesson, applied in advance.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let locale = Locale(identifier: "en_US")
    /// 2026-08-08 12:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_786_190_400)
    private static let capable = CoolingTrendCopy.Capabilities(
        hasPowerReading: true, hasAirflowSensor: true
    )

    private func row(
        _ verdict: CoolingTrend.Verdict,
        capabilities: CoolingTrendCopy.Capabilities = capable,
        readings: Int = 42
    ) -> DiagnosisCopy.Row {
        CoolingTrendCopy.row(
            verdict, capabilities: capabilities, readings: readings,
            now: Self.now, calendar: Self.calendar, locale: Self.locale
        )
    }

    private func comparison(
        change: Double, since: Date, recent: Double = 0.51
    ) -> CoolingTrend.Comparison {
        CoolingTrend.Comparison(
            band: .decile(3),
            resistanceChangeFraction: change,
            recentMedian: recent,
            baselineMedian: recent / (1 + change),
            since: since,
            recentReadings: 31,
            baselineReadings: 42
        )
    }

    private func monthsAgo(_ months: Int) -> Date {
        Self.calendar.date(byAdding: .month, value: -months, to: Self.now)!
    }

    // MARK: - Direction and sign

    @Test("Worse and better carry the direction; the percent is never signed")
    func directionLivesInWordsNotSigns() {
        let worse = row(.slowRise(comparison(change: 0.18, since: monthsAgo(2))))
        #expect(worse.title.contains("worse"))
        #expect(worse.title.contains("18 %"))
        #expect(
            !worse.title.contains("+") && !worse.title.contains("-"),
            "a signed percent on a lower-is-better metric is ambiguous"
        )

        let better = row(.improved(comparison(change: -0.12, since: monthsAgo(2))))
        #expect(better.title.contains("better"))
        #expect(better.title.contains("12 %"), "unsigned even when the change is negative")
    }

    /// A 9 % drift reports stable — and the copy must admit the number
    /// rather than say "unchanged" about a drift it can see.
    @Test("Stable near the threshold admits the drift; stable near zero stays quiet")
    func stableIsHonestAboutNearMisses() {
        let drifting = row(.stable(comparison(change: 0.088, since: monthsAgo(2))))
        #expect(drifting.title == "Cooling is steady")
        #expect(drifting.note?.contains("9 %") == true, "the number survives to the screen")
        #expect(drifting.note?.contains("not enough to call") == true)

        let flat = row(.stable(comparison(change: 0.01, since: monthsAgo(2))))
        #expect(flat.note == nil, "prose about nothing is noise")
    }

    // MARK: - Naming the baseline's time

    @Test("The baseline month is bare in the same year, dated beyond eleven months")
    func monthNamingFollowsDistance() {
        let recent = row(.slowRise(comparison(change: 0.15, since: monthsAgo(2))))
        #expect(recent.title.contains("in June"), "same year: the month alone")
        #expect(!recent.title.contains("2026"), "the year goes unsaid when it is this one")

        let lastYear = row(.slowRise(comparison(change: 0.15, since: monthsAgo(9))))
        #expect(lastYear.title.contains("in November 2025"), "a different year is named")

        let old = row(.slowRise(comparison(change: 0.15, since: monthsAgo(14))))
        #expect(old.title.contains("on "), "beyond eleven months a bare month reads as this year's")
        #expect(old.title.contains("2025"))
    }

    @Test("The locale flows through to the month name")
    func localeReachesTheMonth() {
        let french = CoolingTrendCopy.row(
            .slowRise(comparison(change: 0.15, since: monthsAgo(2))),
            capabilities: Self.capable, readings: 42,
            now: Self.now, calendar: Self.calendar, locale: Locale(identifier: "fr_FR")
        )
        #expect(french.title.contains("juin"), "got \(french.title)")
    }

    // MARK: - Refusals and progress

    @Test("Collecting shows a real denominator — a date, not a spinner")
    func collectingNamesTheFinishLine() throws {
        let since = try #require(Self.calendar.date(byAdding: .day, value: -10, to: Self.now))
        let ready = try #require(Self.calendar.date(byAdding: .day, value: 34, to: Self.now))
        let copy = row(.collectingBaseline(since: since, readyAfter: ready), readings: 14)
        #expect(copy.title == "Building a baseline")
        #expect(copy.metric?.contains("14 readings") == true)
        #expect(copy.note?.contains("Comparisons begin") == true)
        #expect(copy.note?.contains("September") == true, "the finish line is a date")
    }

    @Test("Every refusal stays distinguishable from every answer")
    func refusalsAreNotAnswers() {
        let answers = [
            row(.stable(comparison(change: 0.01, since: monthsAgo(2)))).title,
            row(.slowRise(comparison(change: 0.15, since: monthsAgo(2)))).title,
            row(.improved(comparison(change: -0.15, since: monthsAgo(2)))).title,
            row(.suddenJump(band: .decile(3), change: 0.2, referenceDays: 12, readings: 6)).title,
        ]
        let refusals = [
            row(.noHistory).title,
            row(.collectingBaseline(since: monthsAgo(1), readyAfter: Self.now)).title,
            row(.insufficientComparableReadings(reason: .noBandHasBothEpochs, band: nil)).title,
        ]
        for refusal in refusals {
            #expect(!answers.contains(refusal))
            #expect(!refusal.contains("%"), "a refusal never carries a percentage")
        }
    }

    /// A Mac that can never record must be told why, not left collecting
    /// a baseline forever.
    @Test("Impossibility is named from the live snapshot, not inferred from silence")
    func impossibilityIsNamed() {
        let noPower = row(
            .noHistory,
            capabilities: .init(hasPowerReading: false, hasAirflowSensor: true)
        )
        #expect(noPower.title == "No cooling history on this Mac")
        #expect(noPower.note?.contains("power figure") == true)

        let noAirflow = row(
            .noHistory,
            capabilities: .init(hasPowerReading: true, hasAirflowSensor: false)
        )
        #expect(noAirflow.note?.contains("airflow sensor") == true)

        let capableButNew = row(.noHistory)
        #expect(capableButNew.title == "No readings yet", "a capable Mac is merely early")
    }

    // MARK: - The warning triangle

    @Test("Only the jump earns the warning; a slow drift has no moment that deserves orange")
    func onlyTheJumpWarns() {
        #expect(CoolingTrendCopy.isWarning(
            .suddenJump(band: .decile(3), change: 0.2, referenceDays: 12, readings: 6)
        ))
        #expect(!CoolingTrendCopy.isWarning(.slowRise(comparison(change: 0.5, since: monthsAgo(2)))))
        #expect(!CoolingTrendCopy.isWarning(.noHistory))
        #expect(!CoolingTrendCopy.isWarning(.stable(comparison(change: 0, since: monthsAgo(2)))))
    }

    /// The two confounds move R in opposite directions, and each verdict must
    /// name the one that could fake *it* — a display unplugged fakes "worse",
    /// a display plugged in fakes "better".
    @Test("The display confound is named with the right direction on each verdict")
    func displayConfoundDirections() {
        let worse = row(.slowRise(comparison(change: 0.18, since: monthsAgo(2))))
        #expect(worse.hover?.contains("unplugged") == true)

        let better = row(.improved(comparison(change: -0.12, since: monthsAgo(2))))
        #expect(better.hover?.contains("plugged in") == true)
    }
}
