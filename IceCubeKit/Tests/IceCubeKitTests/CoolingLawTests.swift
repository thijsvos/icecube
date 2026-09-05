// CoolingLawTests.swift — a line through two clouds of points is easy to draw and easy to draw meaninglessly.

import Foundation
@testable import IceCubeKit
import Testing

/// The fit is four lines of arithmetic. The tests are about the four ways a
/// band's records can look like a cooling law without being one — and about the
/// measurement that says a single `R` cannot do this job at all.
@Suite("CoolingLaw — what the fans buy, and when that cannot be said")
struct CoolingLawTests {
    private static let epoch = Date(timeIntervalSince1970: 1_753_000_000)

    /// Records on a known line `rise = slope·W + intercept`, with the draw
    /// swept across `wattsRange` so the slope is identifiable.
    private static func records(
        count: Int = 24,
        slope: Double = 1.2,
        intercept: Double = -12,
        wattsFrom: Double = 15,
        wattsTo: Double = 50,
        fraction: Double = 0.95,
        scatter: Double = 0
    ) -> [CoolingRecord] {
        (0 ..< count).map { index in
            let t = Double(index) / Double(max(count - 1, 1))
            let watts = wattsFrom + (wattsTo - wattsFrom) * t
            // Alternating scatter, so the mean stays put and only the spread moves.
            let rise = slope * watts + intercept + (index % 2 == 0 ? scatter : -scatter)
            let ambient = 40.0
            return CoolingRecord(
                date: epoch.addingTimeInterval(Double(index) * 300),
                resistance: rise / watts,
                dieCelsius: ambient + rise,
                ambientCelsius: ambient,
                watts: watts,
                band: .band(forFraction: fraction),
                fanFraction: fraction,
                fanRPM: fraction * 6800,
                sampleCount: 21,
                durationSeconds: 20
            )
        }
    }

    // MARK: - The measurement that shaped the type

    /// The reason this is a line and not a ratio, kept as a test so anyone
    /// reintroducing `ΔT = R · watts` has to argue with hardware.
    ///
    /// These four readings are the project's own — `CoolingEfficiencyTests`'
    /// idle screenshot and `docs/THERMAL.md`'s two measurement tables. Their
    /// `R` spans **1.8×**, and the lowest sits at the *lowest* fan speed, which
    /// is backwards from the same file's measured fan dependence. A single
    /// ratio has nowhere to put that; an intercept does.
    @Test("The measured readings do not share one resistance, which is why this fits a line")
    func measuredReadingsRuleOutASingleRatio() throws {
        let measured: [(watts: Double, rise: Double)] = [
            (19.6, 10.0), // idle, fans at rest
            (9.0, 8.4), //  3550 RPM
            (24.0, 19.9), // 5950 RPM
            (48.0, 43.2), // sustained load
        ]
        let resistances = measured.map { $0.rise / $0.watts }
        let lowest = try #require(resistances.min())
        let highest = try #require(resistances.max())
        #expect(highest / lowest > 1.7, "R spans \(lowest)…\(highest); a single ratio cannot carry these")
    }

    // MARK: - The arithmetic

    /// "Exactly" within the resolution the file keeps.
    ///
    /// `CoolingRecord.init` rounds temperatures and watts to one decimal on
    /// the way in — deliberately, so memory and disk agree — which puts about
    /// ±0.05 °C of quantisation on every point. A line fitted through stored
    /// records therefore cannot be recovered to more than that, and a test
    /// demanding otherwise is testing the rounding rather than the fit. Found
    /// by writing one that did.
    @Test("A clean line is recovered to the resolution the record format keeps")
    func recoversAKnownLine() throws {
        let law = CoolingLaw.fit(records: Self.records(slope: 1.2, intercept: -12))
        let band = try #require(law.band(.band(forFraction: 0.95)))
        #expect(abs(band.slope - 1.2) < 0.005, "slope \(band.slope)")
        #expect(abs(band.intercept + 12) < 0.10, "intercept \(band.intercept)")
        #expect(band.residual < 0.10, "residual \(band.residual) is the record rounding, not the fit")
    }

    /// The intercept is the whole point: it holds the watts that never reach
    /// the die, so the line crosses zero rise at a real positive draw rather
    /// than at the origin.
    @Test("The fitted line predicts no rise until the free power is exceeded")
    func interceptAbsorbsFreePower() throws {
        let law = CoolingLaw.fit(records: Self.records(slope: 1.2, intercept: -12))
        let band = try #require(law.band(.band(forFraction: 0.95)))
        #expect(band.rise(atWatts: 8) == 0, "8 W is under the crossing and must predict no rise")
        #expect(band.rise(atWatts: 40) > 30)
    }

    @Test("Bands are fitted separately and keep their own slopes")
    func bandsAreIndependent() throws {
        let slow = Self.records(slope: 1.9, intercept: -18, fraction: 0.25)
        let fast = Self.records(slope: 1.1, intercept: -10, fraction: 0.95)
        let law = CoolingLaw.fit(records: slow + fast)
        #expect(law.measuredBands.count == 2)
        #expect(try #require(law.band(.band(forFraction: 0.25))).slope > 1.5)
        #expect(try #require(law.band(.band(forFraction: 0.95))).slope < 1.5)
    }

    /// Which band runs coolest genuinely depends on the load, because bands
    /// differ in intercept as well as slope — two lines with different slopes
    /// cross. So the API asks for a wattage instead of answering in the
    /// abstract, and this pins **both sides of the crossing**.
    ///
    /// One side alone is not enough. The first version of this test asserted
    /// only the high-load answer and **survived a mutation that ignored the
    /// wattage entirely** and simply returned the highest-RPM band — which is
    /// the right answer at 48 W, and the wrong one at 20 W.
    @Test("Which band runs coolest depends on the load, and the answer changes across the crossing")
    func coolestBandDependsOnLoad() throws {
        // Steep and low-offset against shallow and high-offset: the lines cross.
        let quiet = Self.records(slope: 1.9, intercept: -30, fraction: 0.25)
        let loud = Self.records(slope: 1.1, intercept: -5, fraction: 0.95)
        let law = CoolingLaw.fit(records: quiet + loud)

        let atLowLoad = try #require(law.coolestBand(atWatts: 20))
        #expect(atLowLoad.band == .band(forFraction: 0.25), "below the crossing the quiet band wins")

        let atHighLoad = try #require(law.coolestBand(atWatts: 48))
        #expect(atHighLoad.band == .band(forFraction: 0.95), "above it the loud band wins")
    }

    // MARK: - The refusals

    /// **The gate that makes the fit mean anything.** Least squares will fit a
    /// line to points stacked at one wattage and report a number; slope and
    /// intercept become perfectly anti-correlated and the answer is noise
    /// wearing a number. This is the shape the seeded simulated history had
    /// before it was given a spread of draw.
    @Test("Records stacked at one wattage are refused, however many there are")
    func narrowPowerSpreadIsRefused() {
        let stacked = Self.records(count: 200, wattsFrom: 47.5, wattsTo: 48.5)
        #expect(CoolingLaw.fit(records: stacked).band(.band(forFraction: 0.95)) == nil)
    }

    @Test("A band under the evidence bar is not fitted", arguments: [0, 1, 5, 11])
    func tooFewRecordsIsRefused(count: Int) {
        let law = CoolingLaw.fit(records: Self.records(count: count))
        #expect(law.band(.band(forFraction: 0.95)) == nil)
    }

    /// The tempting bug: a band with no evidence must stay absent rather than
    /// borrowing its neighbours'. Quoting a fitted line at a fan speed the
    /// machine has never run is exactly the confident-and-wrong number the
    /// refusals exist to prevent, and it is the rule `CoolingTrend` already
    /// enforces.
    @Test("An unmeasured band is absent, never interpolated from its neighbours")
    func neighbouringBandsAreNotInterpolated() {
        let low = Self.records(slope: 1.9, intercept: -18, fraction: 0.05)
        let high = Self.records(slope: 1.1, intercept: -10, fraction: 0.95)
        let law = CoolingLaw.fit(records: low + high)
        for decile in 1 ... 8 {
            #expect(
                law.band(.decile(decile)) == nil,
                "band \(decile) has no records and must not be invented"
            )
        }
    }

    /// The line has to describe the readings, not merely pass among them. A
    /// band whose points scatter far wider than a settled window's own
    /// tolerance is not one operating regime.
    @Test("A scattered band fails the residual test")
    func scatteredRecordsAreRefused() {
        let scattered = Self.records(count: 40, scatter: 9)
        #expect(CoolingLaw.fit(records: scattered).band(.band(forFraction: 0.95)) == nil)
    }

    /// A negative slope means more work made the die cooler. That is not a
    /// cooling law, it is a mislabelled band or a broken sensor.
    @Test("A band where more power reads as less heat is refused")
    func negativeSlopeIsRefused() {
        let backwards = Self.records(slope: -0.8, intercept: 60)
        #expect(CoolingLaw.fit(records: backwards).band(.band(forFraction: 0.95)) == nil)
    }

    // MARK: - Extrapolation

    /// **The bug this was written for.** `wattsRange` was recorded from the
    /// first commit, described as the range "outside which the line is
    /// extrapolation, and callers are expected to care" — and no caller cared.
    ///
    /// Caught in simulated mode. The seeded history held an idle band measured
    /// at 14–25 W and a loaded band at 34–62 W. Asked what the fans would buy
    /// at 48 W, the idle band's line — extrapolated 2.3× past anything it had
    /// seen — came out **18.9 °C cooler** than the loaded one, and the app was
    /// one merge from telling someone to slow their fans down to cool the
    /// machine.
    @Test("A band is not asked about a draw it was never measured at")
    func extrapolationIsRefused() throws {
        let idleOnly = Self.records(slope: 0.5, intercept: 0, wattsFrom: 14, wattsTo: 25, fraction: 0.34)
        let loaded = Self.records(slope: 0.9, intercept: 0, wattsFrom: 34, wattsTo: 62, fraction: 0.95)
        let law = CoolingLaw.fit(records: idleOnly + loaded)

        let idleBand = try #require(law.band(.band(forFraction: 0.34)))
        #expect(idleBand.covers(watts: 20), "20 W is inside what it saw")
        #expect(!idleBand.covers(watts: 48), "48 W is more than twice anything it saw")

        // And the comparison must therefore not offer it.
        let coolest = try #require(law.coolestBand(atWatts: 48))
        #expect(
            coolest.band == .band(forFraction: 0.95),
            "at 48 W only the loaded band has evidence, got \(coolest.band)"
        )
    }

    /// A small margin is deliberate: a line is still roughly itself just
    /// outside the readings that produced it.
    @Test("A draw just outside the measured range is still answered")
    func smallMarginIsAllowed() throws {
        let band = try #require(
            CoolingLaw.fit(records: Self.records(wattsFrom: 20, wattsTo: 40)).band(.band(forFraction: 0.95))
        )
        #expect(band.covers(watts: 43), "3 W past a 20 W span is inside the margin")
        #expect(!band.covers(watts: 55), "15 W past it is a different regime")
    }

    @Test("With no band measured near the draw, there is no comparison at all")
    func noBandCoversTheDraw() {
        let law = CoolingLaw.fit(records: Self.records(wattsFrom: 10, wattsTo: 20))
        #expect(law.coolestBand(atWatts: 60) == nil)
    }

    // MARK: - The seeded history must teach the right thing

    /// `docs/THERMAL.md` exists partly because a screenshot can teach a number
    /// the hardware does not produce. The seeded history is where every
    /// simulated screenshot comes from, so the law fitted from it has to be
    /// **physically ordered**: at any given load, more fan must be cooler.
    ///
    /// It was not, until 2026-09-01. Each band carried a fixed `R` taken from a
    /// different real measurement — 0.51 °C/W at idle, 0.90 under load — and
    /// `R` genuinely varies with load, which is the whole reason this type fits
    /// a line. Compared at one wattage those constants said the near-stopped
    /// fans were coolest.
    @Test("The seeded history fits a law where more fan is cooler at every load")
    func seededLawIsPhysicallyOrdered() {
        let history = SimulatedCoolingHistory.seed(.stable, endingAt: Self.epoch)
        let law = CoolingLaw.fit(history)
        #expect(law.measuredBands.count >= 3, "got \(law.measuredBands)")

        for watts in [20.0, 35.0, 45.0] {
            let ordered = law.measuredBands
                .compactMap { band -> (Int, Double)? in
                    guard let fit = law.band(band), fit.covers(watts: watts) else { return nil }
                    return (band.sortKey, fit.rise(atWatts: watts))
                }
                .sorted { $0.0 < $1.0 }
            guard ordered.count >= 2 else { continue }
            for (slower, faster) in zip(ordered, ordered.dropFirst()) {
                #expect(
                    faster.1 < slower.1,
                    "at \(watts) W band \(faster.0) must be cooler than band \(slower.0): \(ordered)"
                )
            }
        }
    }

    /// Ground rule 3: the comparison has to be demonstrable with no hardware,
    /// and it has to point the right way when it is.
    @Test("The seeded history can offer a cooler fan speed, and it is a faster one")
    func seededHistoryOffersAFasterFan() throws {
        let law = CoolingLaw.fit(SimulatedCoolingHistory.seed(.stable, endingAt: Self.epoch))
        let atMidLoad = try #require(law.coolestBand(atWatts: 35))
        let slowest = try #require(law.measuredBands.first)
        #expect(
            atMidLoad.band.sortKey > slowest.sortKey,
            "the coolest option at 35 W must be faster than the slowest measured band"
        )
    }

    @Test("An empty history yields an empty law rather than a crash or a zero")
    func emptyHistoryIsEmpty() {
        let law = CoolingLaw.fit(records: [])
        #expect(law.measuredBands.isEmpty)
        #expect(law.coolestBand(atWatts: 40) == nil)
        #expect(law.band(.decile(5)) == nil)
    }

    /// A fresh install has nothing, and must say so rather than guess.
    @Test("A brand-new history answers nothing at all")
    func freshInstallAnswersNothing() {
        let history = CoolingHistory(machine: SimulatedCoolingHistory.machine, createdAt: Self.epoch)
        #expect(CoolingLaw.fit(history).measuredBands.isEmpty)
    }

    /// The fit must survive the file it will actually be handed, and simulated
    /// mode must be able to demonstrate the feature (CLAUDE.md ground rule 3).
    ///
    /// **Two** bands, not one: a single fitted band can forecast, but the
    /// comparison this whole type exists for — what a different fan speed
    /// would buy — needs somewhere to compare *to*.
    @Test("The seeded simulated history fits both of its fan bands")
    func seededHistoryFits() throws {
        let history = SimulatedCoolingHistory.seed(.stable, endingAt: Self.epoch)
        let law = CoolingLaw.fit(history)
        #expect(
            law.measuredBands.count >= 2,
            "the demo history must support a comparison, got \(law.measuredBands)"
        )
        let coolest = try #require(law.coolestBand(atWatts: 40))
        #expect(coolest.law.slope > 0)
    }

    // MARK: - The fan speed a band was measured at

    @Test("A band reports the fan speed its records were taken at, not its decile's midpoint")
    func theBandCarriesTheMeasuredFanSpeed() throws {
        // Pinned at 0.91: deep inside decile 9, whose midpoint is 0.95. A Mac
        // that idles against its own RPM floor lives at one edge of a band all
        // day, and the midpoint would name a fan speed it never runs at.
        let law = CoolingLaw.fit(records: Self.records(fraction: 0.91))
        let band = try #require(law.band(.decile(9)))
        #expect(band.medianFanFraction == 0.91)
    }

    @Test("A band that cannot say what its fans were doing is refused, not guessed")
    func anUnreadableFanSpeedDropsTheBand() {
        // Identical readings on an identical line — only the fan fraction is
        // unreadable. Guessing it at the decile midpoint would be guessing
        // *low* for a band recorded near the top of its decile, and a derived
        // curve built on that commands less fan than the readings were taken
        // with: the machine then settles hotter than the number it promised.
        let poisoned = Self.records(fraction: 0.91).map { record in
            CoolingRecord(
                date: record.date,
                resistance: record.resistance,
                dieCelsius: record.dieCelsius,
                ambientCelsius: record.ambientCelsius,
                watts: record.watts,
                band: record.band,
                fanFraction: .nan,
                fanRPM: record.fanRPM,
                sampleCount: record.sampleCount,
                durationSeconds: record.durationSeconds
            )
        }
        #expect(CoolingLaw.fit(records: Self.records(fraction: 0.91)).band(.decile(9)) != nil)
        #expect(CoolingLaw.fit(records: poisoned).band(.decile(9)) == nil)
    }
}
