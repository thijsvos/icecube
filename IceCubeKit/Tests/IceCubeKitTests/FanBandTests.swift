// FanBandTests.swift — the axis the whole cooling-history comparison hangs on.

import Foundation
@testable import IceCubeKit
import Testing

/// °C/W is only comparable at comparable fan speeds, so every record is filed
/// under a band and every verdict stays inside one. A banding bug does not
/// crash — it silently files a year of readings where they will be compared
/// against the wrong regime, so the edges, the sentinel and the refusals are
/// each pinned.
@Suite("FanBand — filing readings by fan speed")
struct FanBandTests {
    private func fan(
        id: Int = 0, actual: Double, min: Double = 2317, max: Double = 6800
    ) -> Fan {
        Fan(
            id: id, name: "Fan \(id)", mode: .system,
            actualRPM: actual, targetRPM: actual, minRPM: min, maxRPM: max
        )
    }

    @Test("Deciles cover the range without overlap, and the edges land where documented")
    func decilesCoverTheRangeWithoutOverlap() {
        #expect(FanBand.band(forFraction: 0.0) == .decile(0))
        #expect(FanBand.band(forFraction: 0.099) == .decile(0))
        #expect(FanBand.band(forFraction: 0.100) == .decile(1))
        #expect(FanBand.band(forFraction: 0.55) == .decile(5))
        #expect(FanBand.band(forFraction: 0.999) == .decile(9))
        #expect(FanBand.band(forFraction: 1.0) == .decile(9), "a fan at exactly maximum is still band 9")
    }

    /// Band 0 on a fanned Mac means fans nearly stopped — coasting on
    /// convection through ducting designed for forced air. A fanless Air has
    /// no fan and its whole thermal design assumes that. Merging them is a
    /// category error the first time someone reads the file.
    @Test("A fanless Mac is not band zero")
    func aFanlessMacIsNotBandZero() throws {
        let context = try #require(FanContext.measure([]))
        #expect(context.band == .fanless)
        #expect(FanBand.fanless != FanBand.decile(0))
    }

    /// "We cannot tell what the fans are doing" is not "there are no fans".
    /// Conflating them would file a broken-read Mac under `.fanless` forever.
    @Test("Fans present but unreadable refuse rather than reading as fanless")
    func fansPresentButUnreadableRefuse() {
        let broken = [fan(actual: 3000, min: 0, max: 6800)] // minRPM 0 fails hasUsableRange
        #expect(FanContext.measure(broken) == nil)
    }

    @Test("Each fan is measured against its own maximum")
    func eachFanIsMeasuredAgainstItsOwnMaximum() throws {
        let mixed = [
            fan(id: 0, actual: 2000, min: 1000, max: 4000), // half of ITS range's max
            fan(id: 1, actual: 3400), // half of 6800
        ]
        let context = try #require(FanContext.measure(mixed))
        #expect(abs(context.meanFraction - 0.5) < 0.001, "fractions, not raw RPM, are averaged")
    }

    @Test("Disagreement is max minus min of per-fan fractions — a stopped fan reads large")
    func disagreementIsMaxMinusMin() throws {
        let context = try #require(FanContext.measure([
            fan(id: 0, actual: 5950), // 0.875 of max
            fan(id: 1, actual: 0), // stopped
        ]))
        #expect(abs(context.disagreement - 0.875) < 0.001)
    }

    /// Changing the sentinel would silently re-file existing history.
    @Test("The band encodes as one integer and survives a round trip, fanless as −1")
    func bandEncodesAsOneIntegerAndSurvivesARoundTrip() throws {
        let bands: [FanBand] = [.fanless, .decile(0), .decile(5), .decile(9)]
        let data = try JSONEncoder().encode(bands)
        #expect(String(data: data, encoding: .utf8) == "[-1,0,5,9]")
        let decoded = try JSONDecoder().decode([FanBand].self, from: data)
        #expect(decoded == bands)
    }
}
