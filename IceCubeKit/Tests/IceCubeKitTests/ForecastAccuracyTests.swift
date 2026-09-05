// ForecastAccuracyTests.swift — the only test that asks whether the forecast is right, not merely careful.

import Foundation
@testable import IceCubeKit
import Testing

/// Every other suite here checks that the forecast refuses when it should.
/// This one checks the opposite: when it *does* answer, is the answer true?
///
/// That question is normally unanswerable — you would have to wait and see. It
/// is answerable here because `MockSMCSimulation` is a pure function of the
/// clock, so the future is already computable. Forecast at one moment, then
/// read what the machine actually does two minutes later, and compare.
///
/// This is the check the plan called the difference between a forecast and
/// decoration: *"a forecast never checked against its outcome is decoration."*
@Suite("ThermalForecast — does it predict what actually happens?")
struct ForecastAccuracyTests {
    private static let epoch: TimeInterval = 1_753_000_000

    /// The simulated machine's cooling law, built from the plant's own
    /// equilibrium rather than fitted from records.
    ///
    /// Deliberately not `CoolingLaw.fit`. The simulation's draw is **bimodal**
    /// — idle at 19.6 W or a spike at ~52 W, nothing between — and those two
    /// modes drive the fans into different bands, so every band sees a single
    /// wattage and `minimumPowerSpreadFraction` refuses all of them. That is
    /// the gate working correctly on data that genuinely cannot identify a
    /// slope, and it is why the seeded history exists.
    ///
    /// Building the law analytically isolates what this suite is asking about:
    /// given a correct law, does the projection land where the machine goes?
    private static func plantLaw() -> CoolingLaw {
        var bands: [FanBand: CoolingLaw.Band] = [:]
        for decile in 0 ... 9 {
            let fraction = (Double(decile) + 0.5) / 10
            let low = MockSMCProvider.equilibriumRise(watts: 30, fanFraction: fraction)
            let high = MockSMCProvider.equilibriumRise(watts: 60, fanFraction: fraction)
            let slope = (high - low) / 30
            bands[.decile(decile)] = CoolingLaw.Band(
                slope: slope,
                intercept: low - slope * 30,
                residual: 0.1,
                records: 40,
                wattsRange: 10 ... 60,
                medianFanFraction: fraction
            )
        }
        return CoolingLaw(bands: bands)
    }

    /// The simulation's own fan controller expressed as a `FanCurve`: zero
    /// demand at `demandFloorCelsius`, full at `demandCeilingCelsius`, eased
    /// the same way.
    private static func plantCurve() -> FanCurve {
        FanCurve(points: (0 ... 7).map { step in
            let x = Double(step) / 7
            return CurvePoint(
                celsius: MockSMCProvider.demandFloorCelsius
                    + x * (MockSMCProvider.demandCeilingCelsius - MockSMCProvider.demandFloorCelsius),
                fraction: MockSMCProvider.smoothstep(x)
            )
        })
    }

    private static func die(at t: TimeInterval) -> Double {
        MockSMCProvider.temperatures(at: t).filter(\.sensorClass.isDie).map(\.celsius).max() ?? 0
    }

    /// Start of the first spike that fills a whole bucket, so the machine holds
    /// one load long enough to reach equilibrium.
    private static func firstSustainedStart() -> TimeInterval {
        var bucket = (epoch / MockSMCProvider.spikeBucketLength).rounded(.down)
        let limit = bucket + 200
        while bucket < limit {
            if let window = MockSMCProvider.spikeWindow(inBucket: bucket), window.duration > 100 {
                return window.start
            }
            bucket += 1
        }
        Issue.record("No sustained window found — spike model changed?")
        return epoch
    }

    /// The claim, end to end: forecast where a sustained load settles, then
    /// read where the machine actually is once it has had time to get there.
    ///
    /// Three degrees is the bar. The forecast fits **one** pole to a machine
    /// that has two, and treats airflow as fixed when it is climbing, so exact
    /// agreement would mean the test was rigged rather than that the model is
    /// perfect. Three degrees is close enough to be worth showing someone and
    /// loose enough to survive both documented approximations.
    @Test("A forecast made during a sustained load matches where the machine ends up")
    func forecastMatchesOutcome() throws {
        let start = Self.firstSustainedStart()
        let at = start + 20 // past the 8 s envelope rise, so the draw is steady

        let temperatures = MockSMCProvider.temperatures(at: at)
        let ambient = try #require(CoolingEfficiency.ambient(from: temperatures))
        let verdict = ThermalForecast.project(
            dieCelsius: Self.die(at: at),
            ambientCelsius: ambient,
            watts: MockSMCProvider.power(at: at),
            fans: MockSMCProvider.fans(at: at),
            curve: Self.plantCurve(),
            law: Self.plantLaw(),
            tau: MockSMCProvider.dieSlowTimeConstant,
            estimateCount: ThermalTimeConstant.minimumEstimates,
            isLoadSteady: true
        )

        guard case let .settling(projection) = verdict else {
            Issue.record("expected a forecast, got \(verdict)")
            return
        }

        // What the machine actually does, late in the same sustained window.
        let actual = Self.die(at: at + 125)
        #expect(
            abs(projection.settlesAtCelsius - actual) < 3,
            "forecast \(projection.settlesAtCelsius) °C, machine reached \(actual) °C"
        )
    }

    /// The forecast must not be right by accident — it has to move when the
    /// machine does. A quiet stretch and a loaded one must produce different
    /// answers, in the right order.
    @Test("The forecast follows the machine rather than reporting a constant")
    func forecastTracksTheLoad() throws {
        let loaded = Self.firstSustainedStart() + 20
        var quiet = Self.epoch + 120
        while quiet < Self.epoch + 3600, MockSMCProvider.spikeEnvelope(at: quiet) != 0 {
            quiet += 5
        }

        func settle(at t: TimeInterval) throws -> Double {
            let temperatures = MockSMCProvider.temperatures(at: t)
            let verdict = try ThermalForecast.project(
                dieCelsius: Self.die(at: t),
                ambientCelsius: #require(CoolingEfficiency.ambient(from: temperatures)),
                watts: MockSMCProvider.power(at: t),
                fans: MockSMCProvider.fans(at: t),
                curve: Self.plantCurve(),
                law: Self.plantLaw(),
                tau: MockSMCProvider.dieSlowTimeConstant,
                estimateCount: ThermalTimeConstant.minimumEstimates,
                isLoadSteady: true
            )
            switch verdict {
            case let .settling(projection): return projection.settlesAtCelsius
            case let .reachesCeiling(projection, _): return projection.settlesAtCelsius
            case let .unavailable(gap): throw ForecastRefused(gap: gap)
            }
        }

        let underLoad = try settle(at: loaded)
        let atRest = try settle(at: quiet)
        #expect(underLoad > atRest + 20, "loaded \(underLoad) °C vs quiet \(atRest) °C")
    }

    private struct ForecastRefused: Error {
        let gap: ThermalForecast.Gap
    }
}
