// CurveDerivationTests.swift — a curve derived from measurements has to hold what it promises.

import Foundation
@testable import IceCubeKit
import Testing

/// The derivation is a sweep and a sort. The tests are about the four ways it
/// can produce a plausible-looking curve that does not hold — and about the
/// one claim worth making, which is that feeding a derived curve back through
/// the *forward* solver lands where the derivation said it would.
@Suite("CurveDerivation — the law run backwards")
struct CurveDerivationTests {
    // MARK: - Fixtures

    /// Ambient used throughout: the reference machine's idle airflow reading.
    private static let ambient = 39.5

    /// A band, written as the line it is.
    private static func band(
        slope: Double,
        intercept: Double,
        fraction: Double,
        over range: ClosedRange<Double> = 20 ... 52,
        records: Int = 40
    ) -> CoolingLaw.Band {
        CoolingLaw.Band(
            slope: slope,
            intercept: intercept,
            residual: 0.5,
            records: records,
            wattsRange: range,
            medianFanFraction: fraction
        )
    }

    /// The simulated plant's own physics, expressed as a law with every decile
    /// measured — the same construction `ForecastAccuracyTests.plantLaw` uses,
    /// and for the same reason: it isolates the derivation from whether the
    /// *fit* was any good.
    private static func plantLaw(over range: ClosedRange<Double> = 20 ... 52) -> CoolingLaw {
        var bands: [FanBand: CoolingLaw.Band] = [:]
        for decile in 0 ... 9 {
            let fraction = (Double(decile) + 0.5) / 10
            let low = MockSMCProvider.equilibriumRise(watts: range.lowerBound, fanFraction: fraction)
            let high = MockSMCProvider.equilibriumRise(watts: range.upperBound, fanFraction: fraction)
            let slope = (high - low) / (range.upperBound - range.lowerBound)
            bands[.decile(decile)] = CoolingLaw.Band(
                slope: slope,
                intercept: low - slope * range.lowerBound,
                residual: 0.1,
                records: 40,
                wattsRange: range,
                medianFanFraction: fraction
            )
        }
        return CoolingLaw(bands: bands)
    }

    /// Where the plant actually settles under `watts` while `curve` drives the
    /// fans: the fixed point of `T = ambient + rise(W, curve(T))`.
    ///
    /// Bisection rather than iteration. `rise` falls as the fans rise and the
    /// curve rises with temperature, so `g(T) = ambient + rise(W, curve(T)) − T`
    /// is strictly decreasing and has exactly one root — which is the same
    /// argument `ThermalForecast.solve` makes over discrete bands.
    private static func plantSettles(watts: Double, curve: FanCurve) -> Double {
        var low = ambient
        var high = 140.0
        for _ in 0 ..< 60 {
            let mid = (low + high) / 2
            let landed = ambient + MockSMCProvider.equilibriumRise(
                watts: watts, fanFraction: curve.fraction(at: mid)
            )
            if landed > mid {
                low = mid
            } else {
                high = mid
            }
        }
        return (low + high) / 2
    }

    private static func derived(_ verdict: CurveDerivation.Verdict) throws -> CurveDerivation.Derivation {
        guard case let .derived(derivation) = verdict else {
            Issue.record("expected a derivation, got \(verdict)")
            throw CancellationError()
        }
        return derivation
    }

    // MARK: - What it refuses

    @Test("A machine measured at one fan speed cannot say what another would buy")
    func oneBandIsNotAComparison() {
        let law = CoolingLaw(bands: [.decile(2): Self.band(slope: 1.8, intercept: -30, fraction: 0.25)])
        let verdict = CurveDerivation.derive(holdingAt: 85, law: law, ambientCelsius: Self.ambient)
        #expect(verdict == .unavailable(.tooFewBands(measured: 1, need: 2)))
    }

    @Test("A fresh install answers nothing, and says which input is missing")
    func anEmptyLawNamesTheGap() {
        let verdict = CurveDerivation.derive(
            holdingAt: 85, law: CoolingLaw(), ambientCelsius: Self.ambient
        )
        #expect(verdict == .unavailable(.tooFewBands(measured: 0, need: 2)))
    }

    @Test("Bands that cover no span of load produce no curve")
    func aPointLoadRangeIsNotARange() {
        let law = CoolingLaw(bands: [
            .decile(2): Self.band(slope: 1.8, intercept: -30, fraction: 0.25, over: 30 ... 30),
            .decile(8): Self.band(slope: 1.4, intercept: -24, fraction: 0.85, over: 30 ... 30),
        ])
        let verdict = CurveDerivation.derive(holdingAt: 85, law: law, ambientCelsius: Self.ambient)
        #expect(verdict == .unavailable(.noLoadCovered))
    }

    /// The failure `CoolingLaw.Band.covers(watts:)` was written for, seen from
    /// the other side: an idle band's line extrapolated to a load it never saw
    /// reads *cooler* than a loaded band's, so the quietest-band-first walk
    /// would pick it and the curve would command slow fans under heavy load.
    @Test("A band is never evaluated at a load it was not measured near")
    func theIdleBandDoesNotGetToAnswerForALoadedMachine() throws {
        // Idle band, measured 14-25 W, whose line extrapolates absurdly cool.
        // Loaded band, measured 34-62 W, is the only honest answer up there.
        let law = CoolingLaw(bands: [
            .decile(1): Self.band(slope: 0.30, intercept: -2, fraction: 0.15, over: 14 ... 25),
            .decile(8): Self.band(slope: 1.40, intercept: -24, fraction: 0.85, over: 34 ... 62),
        ])
        let derivation = try Self.derived(
            CurveDerivation.derive(holdingAt: 85, law: law, ambientCelsius: Self.ambient)
        )
        // At 50 W the idle band's line would claim a 13 °C rise. If it had been
        // allowed to answer, the curve would sit at 15 % fan up there.
        #expect(law.band(.decile(1))?.covers(watts: 50) == false)
        #expect(derivation.curve.fraction(at: Self.ambient + 1.40 * 50 - 24) >= 0.85)
    }

    // MARK: - Invariants of every derived curve

    @Test("The curve is monotone, within the point cap, and reaches full fans")
    func theShapeIsAlwaysUsable() throws {
        let derivation = try Self.derived(
            CurveDerivation.derive(holdingAt: 85, law: Self.plantLaw(), ambientCelsius: Self.ambient)
        )
        let points = derivation.curve.points
        #expect(points.count <= CurveDerivation.maximumPoints)
        #expect(points.count >= 2)
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.celsius < $1.celsius })
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
        #expect(points.last?.fraction == 1)
    }

    @Test("Full fans arrive before the ceiling, not after the evidence runs out")
    func theRampToFullIsAlwaysPresent() throws {
        // Evidence that tops out well below the ceiling: without the loud
        // anchor this curve would clamp flat at its warmest measured point.
        let law = CoolingLaw(bands: [
            .decile(0): Self.band(slope: 1.0, intercept: -14, fraction: 0.05, over: 20 ... 30),
            .decile(3): Self.band(slope: 0.9, intercept: -14, fraction: 0.35, over: 20 ... 40),
        ])
        let derivation = try Self.derived(
            CurveDerivation.derive(holdingAt: 85, law: law, ambientCelsius: Self.ambient)
        )
        #expect(derivation.holdsAtCelsius < CurveDerivation.fullFanCelsius)
        #expect(derivation.curve.fraction(at: CurveDerivation.fullFanCelsius) == 1)
        #expect(derivation.curve.fraction(at: SafetyMonitor.Limits().dieCeiling) == 1)
    }

    @Test("The quiet anchor lets a curve derived from loaded readings idle silently")
    func idleIsSilentEvenWhenEveryReadingCameFromWork() throws {
        // Every band measured at 30 W or more and none of them slow: without
        // the quiet anchor the curve would command 45 % fan at room
        // temperature, because that is the slowest speed it ever *recorded*.
        let law = CoolingLaw(bands: [
            .decile(4): Self.band(slope: 1.7, intercept: -28, fraction: 0.45, over: 30 ... 52),
            .decile(8): Self.band(slope: 1.4, intercept: -24, fraction: 0.85, over: 30 ... 52),
        ])
        let derivation = try Self.derived(
            CurveDerivation.derive(holdingAt: 85, law: law, ambientCelsius: Self.ambient)
        )
        #expect(derivation.curve.fraction(at: 35) == 0)
        #expect(derivation.curve.points.first?.fraction == 0)
    }

    // MARK: - The honest limit

    @Test("A target this Mac cannot hold is named, not promised")
    func theShortfallSaysWhatTheMachineCanActuallyDo() throws {
        let derivation = try Self.derived(
            CurveDerivation.derive(holdingAt: 75, law: Self.plantLaw(), ambientCelsius: Self.ambient)
        )
        let shortfall = try #require(derivation.shortfall)
        #expect(shortfall.settlesAtCelsius > 75)
        #expect(derivation.holdsAtCelsius == shortfall.settlesAtCelsius)
        // The best it managed there was its fastest measured fan speed.
        #expect(shortfall.fanFraction >= 0.9)
    }

    @Test("A target well within reach reports no shortfall")
    func anAchievableTargetIsSimplyMet() throws {
        let derivation = try Self.derived(
            CurveDerivation.derive(holdingAt: 95, law: Self.plantLaw(), ambientCelsius: Self.ambient)
        )
        #expect(derivation.shortfall == nil)
        #expect(derivation.holdsAtCelsius <= 95)
    }

    // MARK: - The claim: the forward solver agrees

    /// The inverse checked by the forward. `ThermalForecast` is the shipped,
    /// tested answer to "where does this curve settle"; if the curve this
    /// derives does not settle where it said, one of the two is wrong and this
    /// is the test that finds out which.
    @Test("A derived curve settles where it promised, per the forward solver")
    func theForwardSolverAgreesWithTheDerivation() throws {
        let law = Self.plantLaw()
        for target in [80.0, 85.0, 90.0] {
            let derivation = try Self.derived(
                CurveDerivation.derive(holdingAt: target, law: law, ambientCelsius: Self.ambient)
            )
            let promised = derivation.holdsAtCelsius
            for watts in stride(from: 22.0, through: 50.0, by: 4.0) {
                guard case let .success(landed) = ThermalForecast.solve(
                    from: 60, ambient: Self.ambient, watts: watts,
                    curve: derivation.curve, law: law
                ) else { continue }
                #expect(
                    landed.celsius <= promised + 1,
                    "target \(target): \(watts) W settled at \(landed.celsius), promised \(promised)"
                )
            }
        }
    }

    /// And the same claim against the plant itself rather than against a fit of
    /// it — the shape `ForecastAccuracyTests` uses, because a model checked
    /// only against its own fit is checked against nothing.
    @Test("A derived curve holds its promise against the simulated machine's own physics")
    func thePlantAgreesToo() throws {
        let law = Self.plantLaw()
        for target in [80.0, 85.0, 90.0] {
            let derivation = try Self.derived(
                CurveDerivation.derive(holdingAt: target, law: law, ambientCelsius: Self.ambient)
            )
            for watts in stride(from: 20.0, through: 52.0, by: 2.0) {
                let settled = Self.plantSettles(watts: watts, curve: derivation.curve)
                #expect(
                    settled <= derivation.holdsAtCelsius + 2,
                    "target \(target), \(watts) W: plant \(settled), promised \(derivation.holdsAtCelsius)"
                )
            }
        }
    }

    @Test("The quietest curve is quieter than Balanced where the evidence allows")
    func aDerivedCurveIsNotJustAnotherPreset() throws {
        let derivation = try Self.derived(
            CurveDerivation.derive(holdingAt: 90, law: Self.plantLaw(), ambientCelsius: Self.ambient)
        )
        // Balanced starts spinning at 45 °C. On this machine that is fan speed
        // bought before there is any heat to spend it on.
        #expect(FanCurve.balanced.fraction(at: 60) > 0)
        #expect(derivation.curve.fraction(at: 60) < FanCurve.balanced.fraction(at: 60))
    }

    // MARK: - Simulated mode

    /// Ground rule 3: every feature must be demonstrable with no root, no
    /// helper and no real SMC. That is not a nicety here — CI runs simulated
    /// only, so a feature that cannot be reached from the seeded history is a
    /// feature CI never exercises.
    @Test("The seeded simulated history derives a real curve", arguments: [
        SimulatedCoolingHistory.Story.rising,
        .stable,
        .jump,
        .improved,
    ])
    func everyDemonstrableStoryProducesACurve(_ story: SimulatedCoolingHistory.Story) throws {
        let history = SimulatedCoolingHistory.seed(story, endingAt: Date())
        let law = CoolingLaw.fit(history)
        let ambient = try #require(CurveDerivation.ambient(from: history.records))

        let derivation = try Self.derived(
            CurveDerivation.derive(holdingAt: 85, law: law, ambientCelsius: ambient)
        )
        #expect(derivation.bandsUsed >= CurveDerivation.minimumBands)
        #expect(derivation.records > 0)
        #expect(derivation.curve.isUsable)
        #expect(derivation.curve.points.last?.fraction == 1)
        #expect(!CurveDerivation.measuredSpans(law: law, ambientCelsius: ambient).isEmpty)
    }

    /// And the refusal is reachable too — `sparse` is the story that exists so
    /// the honest "cannot say" wording can be seen by hand.
    @Test("The sparse story reaches the refusal rather than inventing a curve")
    func theSparseStoryRefuses() {
        let history = SimulatedCoolingHistory.seed(.sparse, endingAt: Date())
        let law = CoolingLaw.fit(history)
        let ambient = CurveDerivation.ambient(from: history.records) ?? 40

        guard case let .unavailable(gap) = CurveDerivation.derive(
            holdingAt: 85, law: law, ambientCelsius: ambient
        ) else {
            Issue.record("sparse history produced a curve")
            return
        }
        #expect(gap == .tooFewBands(measured: law.measuredBands.count, need: 2))
    }

    // MARK: - The evidence, drawn

    @Test("Each measured band becomes the span of temperatures it settles at")
    func spansAreTheBandsInTheEditorsOwnCoordinates() throws {
        let law = CoolingLaw(bands: [
            .decile(2): Self.band(slope: 1.8, intercept: -30, fraction: 0.25, over: 20 ... 40),
            .decile(8): Self.band(slope: 1.4, intercept: -24, fraction: 0.85, over: 30 ... 52),
        ])
        let spans = CurveDerivation.measuredSpans(law: law, ambientCelsius: Self.ambient)

        #expect(spans.count == 2)
        let slow = try #require(spans.first { $0.band == .decile(2) })
        #expect(slow.fanFraction == 0.25)
        #expect(slow.celsius.lowerBound == Self.ambient + 1.8 * 20 - 30)
        #expect(slow.celsius.upperBound == Self.ambient + 1.8 * 40 - 30)
        // The whole point of drawing them: most of the 30-110 °C plot is
        // somewhere this Mac has never been.
        #expect(spans.allSatisfy { $0.celsius.upperBound < 110 })
    }

    /// `ClosedRange` traps on inverted bounds, and `Band` is a value anyone can
    /// construct. A trap inside a `Canvas` body takes the app down.
    @Test("A band that would invert its own span is skipped, not drawn")
    func anInvertedSpanCannotTrapTheCanvas() {
        let impossible = CoolingLaw(bands: [
            .decile(3): Self.band(slope: -1.0, intercept: 60, fraction: 0.35, over: 20 ... 52),
        ])
        #expect(CurveDerivation.measuredSpans(law: impossible, ambientCelsius: Self.ambient).isEmpty)
    }

    // MARK: - Shaping

    /// The lowest temperature at which the curve commands at least `fraction`.
    private static func temperature(_ curve: FanCurve, reaching fraction: Double) -> Double {
        for step in 0 ... 800 {
            let celsius = 30 + Double(step) / 10
            if curve.fraction(at: celsius) >= fraction {
                return celsius
            }
        }
        return 110
    }

    /// The defect this exists for, measured. Against the simulated plant the
    /// raw sweep produced `(78.4, 0.05) (79.0, 0.85)` — a jump from 5 % to
    /// 85 % across **0.6 °C**. Correct, and unfollowable: `CurveFollower`
    /// carries a 4 °C deadband, so that curve is a step function that hunts.
    @Test("A derived curve is followable rather than a cliff")
    func theCurveIsShallowEnoughForTheFollower() throws {
        let derivation = try Self.derived(
            CurveDerivation.derive(holdingAt: 80, law: Self.plantLaw(), ambientCelsius: Self.ambient)
        )
        let span = Self.temperature(derivation.curve, reaching: 0.90)
            - Self.temperature(derivation.curve, reaching: 0.10)
        // 0.8 of range at the 0.05/°C cap is 16 °C; four deadbands, not one.
        #expect(span >= 15)
    }

    @Test("Limiting steepness raises the cooler points and never lowers one")
    func steepnessLimitingIsAlwaysTheSafeDirection() {
        let cliff = [
            CurvePoint(celsius: 40, fraction: 0),
            CurvePoint(celsius: 78.4, fraction: 0.05),
            CurvePoint(celsius: 79.0, fraction: 0.85),
            CurvePoint(celsius: 94, fraction: 1),
        ]
        let shaped = CurveDerivation.limitSteepness(cliff)

        #expect(zip(cliff, shaped).allSatisfy { $0.fraction <= $1.fraction })
        #expect(shaped[1].fraction > cliff[1].fraction)
        for (cooler, warmer) in zip(shaped, shaped.dropFirst()) {
            let gradient = (warmer.fraction - cooler.fraction) / (warmer.celsius - cooler.celsius)
            #expect(gradient <= CurveDerivation.maximumFractionPerCelsius + 1e-9)
        }
    }

    /// The one place a derived curve could quietly under-promise: thinning
    /// replaces a corner with the chord under it.
    @Test("Thinning cannot leave the curve below what the measurements asked for")
    func repairRestoresWhatThinningFlattened() {
        let required = [
            CurvePoint(celsius: 40, fraction: 0),
            CurvePoint(celsius: 60, fraction: 0.60),
            CurvePoint(celsius: 80, fraction: 0.70),
        ]
        let thinned = CurveDerivation.thin(required, to: 2)

        #expect(FanCurve(points: thinned).fraction(at: 60) < 0.60)
        #expect(FanCurve(points: CurveDerivation.repair(thinned, meeting: required))
            .fraction(at: 60) >= 0.60)
    }

    // MARK: - Thinning

    @Test("Thinning keeps the ends and drops the point the curve misses least")
    func thinningKeepsTheCorners() {
        let points = [
            CurvePoint(celsius: 40, fraction: 0),
            CurvePoint(celsius: 50, fraction: 0.10), // dead on the line 40→60
            CurvePoint(celsius: 60, fraction: 0.20),
            CurvePoint(celsius: 70, fraction: 0.90), // the knee
            CurvePoint(celsius: 80, fraction: 1.0),
        ]
        let thinned = CurveDerivation.thin(points, to: 4)
        #expect(thinned.count == 4)
        #expect(thinned.first?.celsius == 40)
        #expect(thinned.last?.celsius == 80)
        #expect(thinned.contains { $0.celsius == 70 })
        #expect(!thinned.contains { $0.celsius == 50 })
    }

    /// Why the derivation thins before handing points to `FanCurve` instead of
    /// letting it cap: `normalized` caps with `prefix(8)`, which keeps the
    /// coolest eight and throws the ramp to full fans away.
    @Test("FanCurve's own cap would delete the ramp, which is why thinning exists")
    func theCapAloneWouldLoseTheHotEnd() {
        let sweep = (0 ..< 12).map { CurvePoint(celsius: 40 + Double($0), fraction: Double($0) / 40) }
        let withRamp = sweep + [CurvePoint(celsius: 94, fraction: 1)]

        #expect(FanCurve(points: withRamp).fraction(at: 94) < 1)
        #expect(FanCurve(points: CurveDerivation.thin(withRamp, to: 8)).fraction(at: 94) == 1)
    }

    // MARK: - The ambient reference

    @Test("The airflow reference is the median of the history, not the last reading")
    func ambientComesFromTheWholeWeek() {
        let records = [38.0, 39.0, 40.0, 41.0, 72.0].map { ambient in
            CoolingRecord(
                date: Date(timeIntervalSince1970: 1_753_000_000),
                resistance: 0.9, dieCelsius: ambient + 30, ambientCelsius: ambient,
                watts: 40, band: .decile(5), fanFraction: 0.55, fanRPM: 3740,
                sampleCount: 21, durationSeconds: 20
            )
        }
        // The 72 °C outlier moves a mean by 6 °C and the median not at all.
        #expect(CurveDerivation.ambient(from: records) == 40)
        #expect(CurveDerivation.ambient(from: []) == nil)
    }
}
