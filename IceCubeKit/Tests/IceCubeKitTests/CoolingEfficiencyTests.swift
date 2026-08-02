// CoolingEfficiencyTests.swift — the rules that stop °C/W being a number that describes nothing.

import Foundation
@testable import IceCubeKit
import Testing

/// `R = ΔT / P` is one division. The tests are not about the arithmetic — they
/// are about the four refusals around it.
///
/// A quotient of two noisy measurements is trivial to compute and trivial to
/// get wrong, and the failure is silent: a user cannot tell a meaningless `R`
/// from a meaningful one by looking. So every path that returns `nil` is worth
/// more than the path that returns a number, and each is pinned here.
@Suite("CoolingEfficiency — when to answer, and when to refuse")
struct CoolingEfficiencyTests {
    private let epoch = Date(timeIntervalSince1970: 1_753_000_000)

    private func sample(_ offset: TimeInterval, die: Double, ambient: Double = 39, watts: Double)
        -> CoolingEfficiency.Sample
    {
        CoolingEfficiency.Sample(
            date: epoch.addingTimeInterval(offset),
            dieCelsius: die,
            ambientCelsius: ambient,
            watts: watts
        )
    }

    /// A steady window at fixed values.
    private func steady(
        die: Double = 49, ambient: Double = 39, watts: Double = 20, seconds: Int = 30
    ) -> [CoolingEfficiency.Sample] {
        (0 ... seconds).map { sample(Double($0), die: die, ambient: ambient, watts: watts) }
    }

    // MARK: - The arithmetic

    /// The owner's own idle readings, from a screenshot on 2026-08-02: CPU 49 °C,
    /// airflow 39 °C, and the 19.6 W idle draw `docs/SMC-KEYS.md` measured on
    /// this Mac. If this number ever stops being ~0.5, either the formula or the
    /// documentation is wrong.
    @Test("A real idle reading from this Mac gives a physically sensible resistance")
    func realIdleReading() throws {
        let r = try #require(
            CoolingEfficiency.resistance(dieCelsius: 49, ambientCelsius: 39, watts: 19.6)
        )
        #expect(abs(r - 0.51) < 0.01, "10 °C over 19.6 W is about 0.51 °C/W, got \(r)")
    }

    @Test("Resistance is degrees per watt, so doubling the power halves it at the same delta")
    func scalesWithPower() throws {
        let low = try #require(CoolingEfficiency.resistance(dieCelsius: 60, ambientCelsius: 40, watts: 20))
        let high = try #require(CoolingEfficiency.resistance(dieCelsius: 60, ambientCelsius: 40, watts: 40))
        #expect(abs(low - 1.0) < 0.001)
        #expect(abs(high - 0.5) < 0.001)
    }

    // MARK: - The four refusals

    @Test("A failed sensor read never becomes a number", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteInputsRefuse(bad: Double) {
        #expect(CoolingEfficiency.resistance(dieCelsius: bad, ambientCelsius: 39, watts: 20) == nil)
        #expect(CoolingEfficiency.resistance(dieCelsius: 49, ambientCelsius: bad, watts: 20) == nil)
        #expect(CoolingEfficiency.resistance(dieCelsius: 49, ambientCelsius: 39, watts: bad) == nil)
    }

    /// The floor exists because `R` is a quotient: at 4 W a ±1 °C wobble moves
    /// it by ±0.25 °C/W, which is larger than the difference this feature is
    /// meant to detect.
    @Test("Below the power floor there is no answer, because the noise would exceed the signal")
    func belowThePowerFloorRefuses() {
        #expect(CoolingEfficiency.resistance(dieCelsius: 49, ambientCelsius: 39, watts: 4) == nil)
        #expect(CoolingEfficiency.resistance(dieCelsius: 49, ambientCelsius: 39, watts: 5) != nil)
    }

    /// Real at cold boot, when the die and the airflow sensors agree. A
    /// zero or negative resistance is not a physical quantity.
    @Test("A die at or below ambient refuses rather than reporting zero or a negative")
    func dieAtOrBelowAmbientRefuses() {
        #expect(CoolingEfficiency.resistance(dieCelsius: 39, ambientCelsius: 39, watts: 20) == nil)
        #expect(CoolingEfficiency.resistance(dieCelsius: 35, ambientCelsius: 39, watts: 20) == nil)
    }

    // MARK: - Settling

    @Test("A steady window settles")
    func steadyWindowSettles() {
        #expect(CoolingEfficiency.isSettled(steady()))
    }

    @Test("A window shorter than the settle time never settles, however steady it looks")
    func shortWindowNeverSettles() {
        #expect(!CoolingEfficiency.isSettled(steady(seconds: 5)))
        #expect(!CoolingEfficiency.isSettled(steady(seconds: 19)))
        #expect(CoolingEfficiency.isSettled(steady(seconds: 20)))
    }

    @Test("A single sample is never settled — one point has no stability")
    func singleSampleNeverSettles() {
        #expect(!CoolingEfficiency.isSettled([sample(0, die: 49, watts: 20)]))
        #expect(!CoolingEfficiency.isSettled([]))
    }

    /// The case the whole settle rule exists for: a load step. The die keeps
    /// absorbing heat after power rises, so ΔT lags P and the quotient
    /// describes neither the old state nor the new one.
    @Test("A load step does not settle, because the die is still absorbing heat")
    func loadStepDoesNotSettle() {
        var window = (0 ... 15).map { sample(Double($0), die: 45, watts: 12) }
        window += (16 ... 30).map { sample(Double($0), die: 78, watts: 45) }
        #expect(!CoolingEfficiency.isSettled(window))
    }

    @Test("Power drifting more than the tolerance does not settle")
    func driftingPowerDoesNotSettle() {
        let window: [CoolingEfficiency.Sample] = (0 ... 30).map { i in
            let watts: Double = i < 15 ? 20 : 30
            return sample(Double(i), die: 49, watts: watts)
        }
        #expect(!CoolingEfficiency.isSettled(window))
    }

    @Test("A die climbing past the tolerance does not settle even at constant power")
    func climbingDieDoesNotSettle() {
        let window: [CoolingEfficiency.Sample] = (0 ... 30).map { i in
            sample(Double(i), die: 49 + Double(i) * 0.5, watts: 20)
        }
        #expect(!CoolingEfficiency.isSettled(window))
    }

    /// Small wobble is normal and must not prevent a reading, or the feature
    /// would report `—` forever on a real machine.
    @Test("Ordinary sensor wobble still settles")
    func ordinaryWobbleSettles() {
        let window: [CoolingEfficiency.Sample] = (0 ... 30).map { i in
            let dieWobble: Double = i % 2 == 0 ? 0.4 : -0.4
            let wattWobble: Double = i % 3 == 0 ? 1 : -1
            return sample(Double(i), die: 49 + dieWobble, watts: 20 + wattWobble)
        }
        #expect(CoolingEfficiency.isSettled(window))
    }

    @Test("One low-power sample anywhere in the window disqualifies it")
    func oneLowPowerSampleDisqualifies() {
        var window = steady()
        window[10] = sample(10, die: 49, watts: 1)
        #expect(!CoolingEfficiency.isSettled(window))
    }

    // MARK: - The windowed result

    @Test("An unsettled window yields no resistance at all")
    func unsettledYieldsNothing() {
        #expect(CoolingEfficiency.settledResistance(steady(seconds: 5)) == nil)
    }

    @Test("A settled window yields the resistance of its means")
    func settledYieldsTheMean() throws {
        let r = try #require(CoolingEfficiency.settledResistance(steady(die: 60, ambient: 40, watts: 20)))
        #expect(abs(r - 1.0) < 0.001)
    }

    /// Averaging the inputs and averaging the quotients are different
    /// operations, and only the first is `R`. Pinned with a window whose power
    /// varies within tolerance, where the two answers measurably differ.
    @Test("It averages the inputs, not the per-sample quotients")
    func averagesInputsNotQuotients() throws {
        let window: [CoolingEfficiency.Sample] = (0 ... 30).map { i in
            let watts: Double = i % 2 == 0 ? 19 : 21
            return sample(Double(i), die: 60, ambient: 40, watts: watts)
        }
        let r = try #require(CoolingEfficiency.settledResistance(window))

        let meanOfQuotients = window.map { 20.0 / $0.watts }.reduce(0, +) / Double(window.count)
        #expect(abs(r - 1.0) < 0.005, "mean watts is ~20, so R is ~1.0")
        #expect(abs(r - meanOfQuotients) > 0.0001, "and that is not the same as averaging the quotients")
    }

    // MARK: - The ambient reference

    @Test("Ambient comes from the airflow sensors, not the hottest thing that is not a die")
    func ambientPrefersAirflow() {
        let readings = [
            SensorReading(key: "Tp09", label: "CPU", celsius: 95),
            SensorReading(key: "TaLP", label: "Airflow Left", celsius: 39),
            SensorReading(key: "TaRF", label: "Airflow Right", celsius: 41),
            SensorReading(key: "TB1T", label: "Battery", celsius: 34),
        ]
        #expect(CoolingEfficiency.ambient(from: readings) == 39, "coolest airflow sensor, not the battery")
    }

    /// The battery is cooler than the airflow sensors here. Taking the coolest
    /// non-die reading would pick it, and a battery is not intake air — it is a
    /// component with its own thermal behaviour. That is why `isAirflowKey`
    /// exists instead of reusing `classify`'s `.ambient` catch-all.
    @Test("A cooler non-airflow sensor is not mistaken for intake air")
    func coolerNonAirflowSensorIsIgnored() {
        let readings = [
            SensorReading(key: "TaLP", label: "Airflow Left", celsius: 39),
            SensorReading(key: "TB1T", label: "Battery", celsius: 28),
            SensorReading(key: "TW0P", label: "Wireless", celsius: 30),
        ]
        #expect(CoolingEfficiency.ambient(from: readings) == 39)
    }

    @Test("A Mac with no airflow sensors has no ambient reference, and says so")
    func noAirflowSensorsMeansNoAmbient() {
        let readings = [SensorReading(key: "Tp09", label: "CPU", celsius: 95)]
        #expect(CoolingEfficiency.ambient(from: readings) == nil, "no reference means no R, not a guessed one")
    }
}

/// The tracker is the only stateful part, and its one interesting decision is
/// what to do about a snapshot that cannot contribute.
@Suite("CoolingEfficiency.Tracker — the window over time")
struct CoolingEfficiencyTrackerTests {
    private let epoch = Date(timeIntervalSince1970: 1_753_000_000)

    private func snapshot(_ offset: TimeInterval, die: Double, ambient: Double?, watts: Double?)
        -> SMCSnapshot
    {
        var temps = [SensorReading(key: "Tp09", label: "CPU", celsius: die)]
        if let ambient {
            temps.append(SensorReading(key: "TaLP", label: "Airflow Left", celsius: ambient))
        }
        return SMCSnapshot(
            date: epoch.addingTimeInterval(offset), fans: [], temperatures: temps, power: watts
        )
    }

    @Test("A steady stream eventually settles and reports")
    func settlesOverTime() throws {
        var tracker = CoolingEfficiency.Tracker()
        for i in 0 ... 30 {
            tracker.ingest(snapshot(Double(i), die: 60, ambient: 40, watts: 20))
        }
        #expect(tracker.isSettled)
        let r = try #require(tracker.resistance)
        #expect(abs(r - 1.0) < 0.001)
    }

    @Test("It reports nothing until the window is long enough")
    func nothingBeforeTheWindowFills() {
        var tracker = CoolingEfficiency.Tracker()
        for i in 0 ... 5 {
            tracker.ingest(snapshot(Double(i), die: 60, ambient: 40, watts: 20))
        }
        #expect(!tracker.isSettled)
        #expect(tracker.resistance == nil)
    }

    /// The decision worth pinning. A gap must **reset** the window, not be
    /// skipped over — stitching the two sides together would call a stretch
    /// containing a hole "steady", which is precisely the lie the settle rule
    /// exists to prevent.
    @Test("A snapshot with no power resets the window rather than being skipped")
    func aGapResetsRatherThanStitches() {
        var tracker = CoolingEfficiency.Tracker()
        for i in 0 ... 30 {
            tracker.ingest(snapshot(Double(i), die: 60, ambient: 40, watts: 20))
        }
        #expect(tracker.isSettled)

        tracker.ingest(snapshot(31, die: 60, ambient: 40, watts: nil))
        #expect(!tracker.isSettled, "one missing reading invalidates the window")

        for i in 32 ... 40 {
            tracker.ingest(snapshot(Double(i), die: 60, ambient: 40, watts: 20))
        }
        #expect(!tracker.isSettled, "and it must re-earn a full window, not resume the old one")
    }

    @Test("A Mac with no airflow sensor never settles, because there is no reference")
    func noAmbientNeverSettles() {
        var tracker = CoolingEfficiency.Tracker()
        for i in 0 ... 40 {
            tracker.ingest(snapshot(Double(i), die: 60, ambient: nil, watts: 20))
        }
        #expect(!tracker.isSettled)
        #expect(tracker.resistance == nil)
    }

    /// This runs once per poll for the life of the app. It must not grow.
    @Test("The window stays bounded however long the app runs")
    func windowIsBounded() throws {
        var tracker = CoolingEfficiency.Tracker()
        for i in 0 ... 5000 {
            tracker.ingest(snapshot(Double(i), die: 60, ambient: 40, watts: 20))
        }
        #expect(tracker.isSettled)
        let mirror = Mirror(reflecting: tracker)
        let samples = try #require(mirror.children.first { $0.label == "samples" }?
            .value as? [CoolingEfficiency.Sample])
        #expect(
            samples.count <= 45,
            "after 5000 polls the window still holds ~2× the settle time, got \(samples.count)"
        )
    }
}
