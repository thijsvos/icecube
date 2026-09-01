// ThermalForecastTests.swift — a forecast is confidently wrong or it is nothing; these are the ways it declines.

import Foundation
@testable import IceCubeKit
import Testing

/// The projection is two logarithms and a fixed point. What is worth testing is
/// when it declines to run them, and whether the fixed point finds the same
/// answer a person would.
///
/// A wrong forecast does not look wrong. It puts a plausible temperature and a
/// plausible number of minutes on screen and the reader has no way to tell.
/// Every refusal is therefore worth more than the answer, and the ceiling
/// crossing is worth most of all — it is the only number here a user might act
/// on urgently.
@Suite("ThermalForecast — where this is heading, and when it will not say")
struct ThermalForecastTests {
    // MARK: - Fixtures

    /// Two fans with the Mac14,9's measured range.
    private static let fans: [Fan] = [0, 1].map {
        Fan(
            id: $0,
            name: "Fan \($0)",
            mode: .system,
            actualRPM: 4500,
            targetRPM: 4500,
            minRPM: 2317,
            maxRPM: 6800
        )
    }

    /// Fans pinned at a given fraction of their range.
    private static func fans(atFraction fraction: Double) -> [Fan] {
        let rpm = 2317 + fraction * (6800 - 2317)
        return [0, 1].map {
            Fan(
                id: $0,
                name: "Fan \($0)",
                mode: .forced,
                actualRPM: rpm,
                targetRPM: rpm,
                minRPM: 2317,
                maxRPM: 6800
            )
        }
    }

    /// A law with a chosen line in each named band, measured over `range`.
    private static func law(
        _ entries: [(FanBand, slope: Double, intercept: Double)],
        measuredOver range: ClosedRange<Double> = 5 ... 60
    ) -> CoolingLaw {
        var bands: [FanBand: CoolingLaw.Band] = [:]
        for entry in entries {
            bands[entry.0] = CoolingLaw.Band(
                slope: entry.slope, intercept: entry.intercept,
                residual: 0.5, records: 40, wattsRange: range
            )
        }
        return CoolingLaw(bands: bands)
    }

    /// A law whose bands were each measured over their own load range.
    private static func law(
        ranged entries: [(FanBand, slope: Double, intercept: Double, range: ClosedRange<Double>)]
    ) -> CoolingLaw {
        var bands: [FanBand: CoolingLaw.Band] = [:]
        for entry in entries {
            bands[entry.0] = CoolingLaw.Band(
                slope: entry.slope, intercept: entry.intercept,
                residual: 0.5, records: 40, wattsRange: entry.range
            )
        }
        return CoolingLaw(bands: bands)
    }

    private static func project(
        die: Double = 70,
        ambient: Double = 45,
        watts: Double = 40,
        fans: [Fan] = ThermalForecastTests.fans,
        curve: FanCurve? = nil,
        law: CoolingLaw,
        tau: TimeInterval? = 75,
        estimates: Int = 40,
        steady: Bool = true
    ) -> ThermalForecast.Verdict {
        ThermalForecast.project(
            dieCelsius: die, ambientCelsius: ambient, watts: watts, fans: fans,
            curve: curve, law: law, tau: tau, estimateCount: estimates, isLoadSteady: steady
        )
    }

    private static func projection(_ verdict: ThermalForecast.Verdict) -> ThermalForecast.Projection? {
        switch verdict {
        case let .settling(projection): projection
        case let .reachesCeiling(projection, _): projection
        case .unavailable: nil
        }
    }

    private static func gap(_ verdict: ThermalForecast.Verdict) -> ThermalForecast.Gap? {
        if case let .unavailable(gap) = verdict {
            gap
        } else {
            nil
        }
    }

    // MARK: - The arithmetic

    /// Fans at 4500 of 6800 is fraction 0.66, so band 6. At 40 W the line
    /// `1.0·W − 5` predicts a 35 °C rise over 45 °C airflow — 80 °C.
    @Test("Under manual control it settles where this band's law says")
    func settlesWhereTheLawSays() throws {
        let verdict = Self.project(law: Self.law([(.decile(6), slope: 1.0, intercept: -5)]))
        let projection = try #require(Self.projection(verdict))
        #expect(abs(projection.settlesAtCelsius - 80) < 0.01, "settles at \(projection.settlesAtCelsius)")
        #expect(projection.settlingBand == .decile(6))
    }

    /// From 70 °C toward 80 °C is a 10 °C gap, closed to within 2 °C after
    /// `τ · ln(10/2)` = 75 · 1.609 ≈ 121 s.
    @Test("Time to settle is the time to close the gap to within the settling band")
    func timeToSettle() throws {
        let verdict = Self.project(law: Self.law([(.decile(6), slope: 1.0, intercept: -5)]))
        let projection = try #require(Self.projection(verdict))
        #expect(abs(projection.secondsToSettle - 75 * log(5)) < 1, "\(projection.secondsToSettle) s")
    }

    /// Already inside the band means zero, not a negative logarithm.
    @Test("A die that has effectively arrived reports no wait")
    func alreadySettledReportsZero() throws {
        let verdict = Self.project(die: 79.5, law: Self.law([(.decile(6), slope: 1.0, intercept: -5)]))
        let projection = try #require(Self.projection(verdict))
        #expect(projection.secondsToSettle == 0)
    }

    /// Nothing under manual control predicts a fan speed, because nothing is
    /// going to move them.
    @Test("Manual control forecasts a temperature but not a fan speed")
    func manualHasNoFanPrediction() throws {
        let verdict = Self.project(law: Self.law([(.decile(6), slope: 1.0, intercept: -5)]))
        #expect(try #require(Self.projection(verdict)).fanRPMAtSettle == nil)
    }

    // MARK: - The fixed point

    /// The claim the feature is built on: a running curve moves the fans as the
    /// die climbs, so the machine settles cooler than the current band implies.
    ///
    /// Band 3 would settle it at 45 + (1.8·40 − 10) = 107 °C. But a curve that
    /// reaches full fans by then puts it in band 9, whose line settles it at
    /// 45 + (0.9·40 − 8) = 73 °C. The answer must be the second, and the naive
    /// evaluation would have reported the first.
    @Test("A running curve settles the machine cooler than its current band implies")
    func curveIsSolvedAsAFixedPoint() throws {
        let curve = FanCurve(points: [
            CurvePoint(celsius: 50, fraction: 0.3),
            CurvePoint(celsius: 70, fraction: 0.95),
        ])
        let law = Self.law([
            (.decile(3), slope: 1.8, intercept: -10),
            (.decile(9), slope: 0.9, intercept: -8),
        ])
        let verdict = Self.project(die: 60, fans: Self.fans(atFraction: 0.35), curve: curve, law: law)
        let projection = try #require(Self.projection(verdict))
        #expect(abs(projection.settlesAtCelsius - 73) < 1, "settles at \(projection.settlesAtCelsius)")
        #expect(projection.settlingBand == .decile(9))
    }

    /// With a curve there *is* a fan speed to predict, and it is the one the
    /// user's own curve commands at the settling temperature.
    @Test("A running curve predicts the fan speed it will command")
    func curvePredictsFanSpeed() throws {
        let curve = FanCurve(points: [
            CurvePoint(celsius: 50, fraction: 0.3),
            CurvePoint(celsius: 70, fraction: 0.95),
        ])
        let law = Self.law([
            (.decile(3), slope: 1.8, intercept: -10),
            (.decile(9), slope: 0.9, intercept: -8),
        ])
        let verdict = Self.project(die: 60, fans: Self.fans(atFraction: 0.35), curve: curve, law: law)
        let rpm = try #require(Self.projection(verdict)?.fanRPMAtSettle)
        #expect(rpm > 6000, "a curve at 0.95 of a 2317–6800 range is over 6000 RPM, got \(rpm)")
    }

    /// A fixed point that sits on a band boundary makes the iteration bounce:
    /// one band settles hot enough to want more fan, the next settles cool
    /// enough to want less. Resolved to the warmer of the two, because that is
    /// the conservative direction for a number someone might act on.
    @Test("An oscillation across a band boundary resolves warm, not to whichever iterate came last")
    func oscillationResolvesWarm() throws {
        // A near-vertical curve at 80 °C: any guess above it wants full fans,
        // any guess below wants almost none.
        let curve = FanCurve(points: [
            CurvePoint(celsius: 79, fraction: 0.15),
            CurvePoint(celsius: 81, fraction: 0.95),
        ])
        let law = Self.law([
            (.decile(1), slope: 2.3, intercept: -8), // settles ~129 °C at 40 W → wants more fan
            (.decile(9), slope: 0.7, intercept: -5), // settles ~68 °C → wants less
        ])
        let verdict = Self.project(die: 80, curve: curve, law: law)
        let projection = try #require(
            Self.projection(verdict), "an oscillation must resolve, not refuse"
        )
        #expect(projection.settlesAtCelsius > 100, "must take the warmer branch, got \(projection.settlesAtCelsius)")
    }

    /// Two bands can both be self-consistent when their fitted lines come out
    /// of physical order — which noisy real data does produce, since each band
    /// is fitted independently and nothing constrains a higher band to be
    /// cooler than a lower one.
    ///
    /// The curve is monotone, so with *well-ordered* laws this cannot happen
    /// and either choice would do. It is reachable exactly when the fits
    /// disagree with physics, which is when picking wrong matters most.
    /// Warmest wins, conservatively.
    @Test("When two bands are both self-consistent, the warmer one is the answer")
    func multipleConsistentBandsResolveWarm() throws {
        let curve = FanCurve(points: [
            CurvePoint(celsius: 70, fraction: 0.55),
            CurvePoint(celsius: 82, fraction: 0.95),
        ])
        // Band 5 settles at 70 °C and band 9 at 82 °C — out of physical order,
        // and each agrees with what the curve asks for at its own temperature.
        let law = Self.law([
            (.decile(5), slope: 0.625, intercept: 0), // 45 + 25.0 = 70 → curve 0.55 → band 5
            (.decile(9), slope: 0.925, intercept: 0), // 45 + 37.0 = 82 → curve 0.95 → band 9
        ])
        let verdict = Self.project(die: 70, curve: curve, law: law)
        let projection = try #require(Self.projection(verdict))
        #expect(projection.settlingBand == .decile(9), "got \(projection.settlingBand)")
        #expect(abs(projection.settlesAtCelsius - 82) < 1, "got \(projection.settlesAtCelsius)")
    }

    // MARK: - The ceiling

    /// The one number here a user might act on urgently, and the one that must
    /// agree with the daemon. Reads `SafetyMonitor.Limits().dieCeiling` rather
    /// than a literal, so the forecast and the rule that will act on it cannot
    /// drift apart.
    @Test("A projection above the ceiling reports when it gets there")
    func ceilingCrossingIsReported() {
        // 2.5·40 − 5 = 95 °C rise over 45 °C airflow = 140 °C, well past 104.
        let law = Self.law([(.decile(6), slope: 2.5, intercept: -5)])
        guard case let .reachesCeiling(_, seconds) = Self.project(law: law) else {
            Issue.record("a projection past the ceiling must say so")
            return
        }
        let ceiling = SafetyMonitor.Limits().dieCeiling
        // ΔT₀ = 25, ΔT∞ = 95, ceiling rise = 104 − 45 = 59.
        let expected = 75 * log((95 - 25) / (95 - (ceiling - 45)))
        #expect(abs(seconds - expected) < 1, "\(seconds) s, expected \(expected)")
    }

    @Test("A projection that stays under the ceiling is not dressed as a warning")
    func belowCeilingIsPlainSettling() {
        guard case .settling = Self.project(law: Self.law([(.decile(6), slope: 1.0, intercept: -5)]))
        else {
            Issue.record("80 °C is not a ceiling crossing")
            return
        }
    }

    /// A die already past the ceiling is the daemon's problem, not a forecast.
    @Test("A die already over the ceiling is not given a countdown")
    func alreadyOverCeilingIsNotACountdown() {
        let law = Self.law([(.decile(6), slope: 2.5, intercept: -5)])
        guard case .settling = Self.project(die: 106, law: law) else {
            Issue.record("past the ceiling there is nothing to count down to")
            return
        }
    }

    // MARK: - Extrapolation

    /// The forecast must not settle in a band on the strength of a line
    /// evaluated far outside anything that band was measured at.
    ///
    /// Band 3 here was fitted on idle draws (10–20 W) and, extrapolated to
    /// 48 W, is the only self-consistent answer — so without the coverage
    /// check the window would confidently report the machine settling with its
    /// fans nearly stopped. Band 9 has the evidence at this draw but is not
    /// self-consistent, so the honest outcome is a refusal.
    @Test("The fixed point will not settle in a band that was never measured at this draw")
    func solverRefusesToExtrapolate() {
        // A gentle curve, so both candidate temperatures land inside band 3's
        // own decile — which is what makes the extrapolated answer look
        // self-consistent, and therefore what the guard has to catch.
        let curve = FanCurve(points: [
            CurvePoint(celsius: 60, fraction: 0.30),
            CurvePoint(celsius: 95, fraction: 0.42),
        ])
        let law = Self.law(ranged: [
            // Fitted on idle draws only. At 48 W its line predicts 73.8 °C, at
            // which this curve asks for band 3 — so without the coverage check
            // it is the one self-consistent answer, and the window would report
            // the machine settling with its fans nearly stopped.
            (.decile(3), slope: 0.6, intercept: 0, range: 10 ... 20),
            // Has the evidence at 48 W, but settles at 69 °C where the curve
            // asks for band 3 — so it is not self-consistent on its own.
            (.decile(9), slope: 0.5, intercept: 0, range: 34 ... 62),
        ])
        let verdict = Self.project(die: 70, watts: 48, curve: curve, law: law)
        guard case let .unavailable(gap) = verdict else {
            Issue.record("expected a refusal, got \(verdict)")
            return
        }
        guard case .bandNotMeasured = gap else {
            Issue.record("expected bandNotMeasured, got \(gap)")
            return
        }
    }

    /// Same rule on the manual path, where there is no curve and the machine
    /// simply stays where the fans were put.
    @Test("Manual control is refused when this band has no readings at this draw")
    func manualRefusesToExtrapolate() {
        let law = Self.law([(.decile(6), slope: 1.0, intercept: -5)], measuredOver: 10 ... 20)
        #expect(Self.gap(Self.project(watts: 48, law: law)) == .bandNotMeasured(.decile(6)))
        // The same band, asked about a draw it actually saw, still answers.
        #expect(Self.projection(Self.project(watts: 18, law: law)) != nil)
    }

    // MARK: - The counterfactual

    /// The comparison the feature exists for, in the units the user pays in.
    @Test("A cooler measured band is offered as what the noise would buy")
    func counterfactualNamesTheSaving() throws {
        let law = Self.law([
            (.decile(6), slope: 1.0, intercept: -5), //  settles 80 °C
            (.decile(9), slope: 0.6, intercept: -4), //  settles 65 °C
        ])
        let counterfactual = try #require(Self.projection(Self.project(law: law))?.counterfactual)
        #expect(counterfactual.band == .decile(9))
        #expect(abs(counterfactual.settlesAtCelsius - 65) < 0.01)
        #expect(abs(counterfactual.degreesSaved - 15) < 0.01)
    }

    /// **Absent, not zero.** A machine that has only ever run in one band has
    /// nothing to compare against, and inventing one would be extrapolating
    /// onto a fan speed it has never been measured at.
    @Test("With only one measured band there is no comparison to offer")
    func noCounterfactualFromOneBand() throws {
        let law = Self.law([(.decile(6), slope: 1.0, intercept: -5)])
        #expect(try #require(Self.projection(Self.project(law: law))).counterfactual == nil)
    }

    /// A saving inside the settling band is not a saving worth a sentence.
    @Test("A negligible saving is not offered")
    func negligibleSavingIsNotOffered() throws {
        let law = Self.law([
            (.decile(6), slope: 1.0, intercept: -5), // 80.0 °C
            (.decile(9), slope: 0.98, intercept: -5), // 79.2 °C
        ])
        #expect(try #require(Self.projection(Self.project(law: law))).counterfactual == nil)
    }

    // MARK: - The refusals

    @Test("A moving load has no equilibrium to head toward")
    func movingLoadIsRefused() {
        let verdict = Self.project(law: Self.law([(.decile(6), slope: 1.0, intercept: -5)]), steady: false)
        #expect(Self.gap(verdict) == .loadNotSteady)
    }

    @Test("Without a time constant there is no forecast, and it says how far along it is")
    func noTimeConstantIsRefused() {
        let verdict = Self.project(
            law: Self.law([(.decile(6), slope: 1.0, intercept: -5)]), tau: nil, estimates: 7
        )
        #expect(Self.gap(verdict) == .noTimeConstantYet(
            estimates: 7, need: ThermalTimeConstant.minimumEstimates
        ))
    }

    /// The rule that keeps this from inventing numbers: a fan speed this
    /// machine has never been measured at gets no forecast, not a borrowed one.
    @Test("A band this machine has never run in is refused by name")
    func unmeasuredBandIsRefused() {
        let verdict = Self.project(law: Self.law([(.decile(9), slope: 0.6, intercept: -4)]))
        #expect(Self.gap(verdict) == .bandNotMeasured(.decile(6)))
    }

    @Test("Fans that cannot be read are refused, not guessed at")
    func unreadableFansAreRefused() {
        let broken = [Fan(id: 0, name: "Fan", mode: .system, actualRPM: 0, targetRPM: 0, minRPM: 0, maxRPM: 0)]
        let verdict = Self.project(fans: broken, law: Self.law([(.decile(6), slope: 1.0, intercept: -5)]))
        #expect(Self.gap(verdict) == .fansUnreadable)
    }

    /// Half an hour out, the inputs have almost certainly changed. A number
    /// with hours on it reads as precision this model does not have.
    @Test("A projection beyond the horizon refuses rather than claiming hours")
    func beyondHorizonIsRefused() {
        // A very slow machine with a long way to go.
        let law = Self.law([(.decile(6), slope: 2.4, intercept: -5)])
        let verdict = Self.project(die: 46, law: law, tau: 590)
        #expect(Self.gap(verdict) == .beyondHorizon)
    }

    @Test("An empty law forecasts nothing")
    func emptyLawIsRefused() {
        #expect(Self.gap(Self.project(law: CoolingLaw())) != nil)
    }

    @Test("A non-finite reading never becomes a forecast", arguments: [Double.nan, .infinity])
    func nonFiniteIsRefused(bad: Double) {
        let law = Self.law([(.decile(6), slope: 1.0, intercept: -5)])
        #expect(Self.gap(Self.project(die: bad, law: law)) != nil)
    }
}
