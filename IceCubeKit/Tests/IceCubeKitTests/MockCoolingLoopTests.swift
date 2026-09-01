// MockCoolingLoopTests.swift — the simulated fans must actually cool, which until now they did not.

import Foundation
@testable import IceCubeKit
import Testing

/// The property this suite exists for: **raising the fans lowers the die.**
///
/// Until 2026-09-01 the simulation had no fan→temperature feedback at all.
/// Sensor temperature read the workload envelope directly and the fans
/// responded to it, so heat drove the fans and the fans drove nothing. The
/// codebase already knew — `SimulatedCoolingHistory` documents that the mock's
/// `R` *"falls at higher RPM where real hardware's rises"*, which is why the
/// cooling history has to be seeded from `docs/THERMAL.md`'s measured table
/// rather than recorded from a running simulation.
///
/// Nothing caught it because nothing asked. Every assertion about the model was
/// about bounds, determinism, or the *fan's* lag; not one asked whether the
/// machine's cooling worked. These do.
@Suite("MockSMCSimulation — the fans actually cool")
struct MockCoolingLoopTests {
    private static let epoch: TimeInterval = 1_753_000_000

    /// The airflow sensor `CoolingEfficiency.ambient(from:)` would pick as the
    /// reference. `TaLP` is the model's only `Ta*` key, so it is that one.
    private static func airflowSpec() throws -> MockSMCProvider.SensorSpec {
        try #require(
            MockSMCProvider.sensorSpecs.first { SMCKeyMaps.isAirflowKey($0.key) },
            "the model must expose an airflow sensor, or R has no ambient reference"
        )
    }

    /// `R` as the app would compute it, from the model's own settled numbers.
    private static func resistance(watts: Double, fanFraction: Double) throws -> Double {
        let rise = MockSMCProvider.equilibriumRise(watts: watts, fanFraction: fanFraction)
        let die = MockSMCProvider.controlSensor.idle + rise
        let airflow = try airflowSpec()
        return (die - (airflow.idle + airflow.riseShare * rise)) / watts
    }

    // MARK: - The direction that was backwards

    @Test(
        "Raising the fans lowers where the die settles, at every load",
        arguments: [25.0, 35.0, 48.0, 52.0]
    )
    func fansCool(watts: Double) {
        let rises = stride(from: 0.0, through: 1.0, by: 0.1)
            .map { MockSMCProvider.equilibriumRise(watts: watts, fanFraction: $0) }
        for (slower, faster) in zip(rises, rises.dropFirst()) {
            #expect(faster < slower, "at \(watts) W the fans must remove heat, not add it")
        }
    }

    /// The headline number, in the units the user reads.
    @Test("Full fans are worth a double-digit number of degrees under load")
    func fansAreWorthRealDegrees() {
        let atRest = MockSMCProvider.equilibriumRise(watts: 48, fanFraction: 0)
        let atFull = MockSMCProvider.equilibriumRise(watts: 48, fanFraction: 1)
        #expect(atRest - atFull > 15, "48 W: rest \(atRest) °C vs full \(atFull) °C")
    }

    /// `R` is the quantity `CoolingEfficiency` publishes and `CoolingTrend`
    /// compares, so its *direction* against fan speed is what a screenshot of
    /// simulated mode teaches someone. It used to teach the opposite of
    /// `docs/THERMAL.md`.
    @Test("Cooling efficiency improves as the fans rise, as it does on real hardware")
    func resistanceFallsWithFanSpeed() throws {
        let values = try stride(from: 0.0, through: 1.0, by: 0.25)
            .map { try Self.resistance(watts: 48, fanFraction: $0) }
        for (slower, faster) in zip(values, values.dropFirst()) {
            #expect(faster < slower, "R must fall as the fans rise: \(values)")
        }
    }

    // MARK: - Calibration against the measured machine

    /// The model is not fitted to `docs/THERMAL.md` — it is a plausible plant
    /// whose constants were *chosen* so its settled readings land on that
    /// file's measured table. If they drift out of range the simulation has
    /// stopped describing the machine it claims to, and every screenshot taken
    /// from it teaches a number the hardware does not produce.
    ///
    /// Measured on a Mac14,9: **0.51 °C/W** at 19.6 W with the fans at rest,
    /// and **0.90 °C/W** at 48 W with them near maximum.
    @Test("Settled readings land on the measured Mac14,9 table")
    func calibrationMatchesMeasurement() throws {
        let idle = try Self.resistance(watts: 19.6, fanFraction: 0)
        let loaded = try Self.resistance(watts: 48, fanFraction: 0.95)
        #expect(abs(idle - 0.51) < 0.10, "idle R \(idle), measured 0.51")
        #expect(abs(loaded - 0.90) < 0.10, "loaded R \(loaded), measured 0.90")
    }

    /// Below the free-power floor every watt is going somewhere that is not the
    /// die — display, SSD, charging — so there is nothing for the fans to
    /// remove and the die sits at its resting temperature.
    @Test("Below the free-power floor there is no rise to cool", arguments: [0.0, 5.0, 12.0, 18.0])
    func noRiseBelowTheFloor(watts: Double) {
        #expect(MockSMCProvider.equilibriumRise(watts: watts, fanFraction: 0) == 0)
    }

    // MARK: - The two poles

    /// Pins that a fast pole exists.
    ///
    /// Measured as the **fraction of the approach covered** in the first ten
    /// seconds, from the pre-spike baseline to the settled value. The 75 s pole
    /// alone can only deliver `1 − e^(−10/75)` = 12 % of that; both poles
    /// together deliver 75 %.
    ///
    /// This matters beyond the simulation: anything that *fits* a single pole
    /// to this model has to be tested against a machine that genuinely has two,
    /// or the fit is exact for the wrong reason and the same code meets a
    /// two-pole machine on real hardware.
    ///
    /// The first version of this test compared the absolute rise against twice
    /// the slow pole's share and **survived deleting the fast pole entirely**
    /// (`dieFastShare = 0` → 16.8 °C against a bar of 11.2 °C, passing). The
    /// die does not start a spike at zero — it carries whatever the last one
    /// left — and that residue alone cleared the bar. Measuring the fraction of
    /// the *approach* rather than the level is what removes the baseline from
    /// the comparison.
    @Test("The die responds in seconds, not only in minutes")
    func fastPoleExists() {
        let start = Self.firstSustainedStart()
        let baseline = MockSMCProvider.state(at: start).dieRise
        let settled = MockSMCProvider.state(at: start + 130).dieRise
        let atTen = MockSMCProvider.state(at: start + 10).dieRise

        let covered = (atTen - baseline) / (settled - baseline)
        let slowPoleAlone = 1 - exp(-10 / MockSMCProvider.dieSlowTimeConstant)
        #expect(
            covered > 0.40,
            "covered \(covered) of the approach in 10 s; the slow pole alone gives \(slowPoleAlone)"
        )
    }

    /// Pins that a slow pole exists, on the one stretch where the drive is
    /// genuinely constant: a cooldown after the fans have hit their floor, so
    /// power, fan speed and therefore the equilibrium are all pinned.
    @Test("The die keeps falling long after the fast pole is spent")
    func slowPoleExists() {
        let cool = Self.firstPinnedCooldown()
        let early = MockSMCProvider.state(at: cool).dieRise
        let late = MockSMCProvider.state(at: cool + 30).dieRise
        let floor = MockSMCProvider.equilibriumRise(watts: MockSMCProvider.idleWatts, fanFraction: 0)
        #expect(late < early, "the die must keep cooling: \(early) → \(late)")
        #expect(late > floor, "and must not have arrived yet — a slow pole takes minutes")
    }

    // MARK: - The assumption the loop is hoisted on

    /// ``MockSMCProvider/controlSensor`` is chosen once, outside the integration
    /// loop, on the claim that `Tp01` leads at every load. If a future sensor
    /// spec broke that, the controller would silently watch the wrong sensor
    /// and nothing else here would notice.
    @Test("The control sensor really is the hottest one, at every load")
    func controlSensorLeads() throws {
        #expect(MockSMCProvider.controlSensor.key == "Tp01")
        for rise in stride(from: 0.0, through: 80.0, by: 5.0) {
            let hottest = try #require(
                MockSMCProvider.sensorSpecs
                    .max { ($0.idle + $0.riseShare * rise) < ($1.idle + $1.riseShare * rise) }
            )
            #expect(hottest.key == MockSMCProvider.controlSensor.key, "at rise \(rise) °C")
        }
    }

    // MARK: - Timeline scans

    /// Start of the first spike that fills a whole bucket (~132 s flat), so the
    /// die has time to approach its equilibrium.
    private static func firstSustainedStart() -> TimeInterval {
        var bucket = (epoch / MockSMCProvider.spikeBucketLength).rounded(.down)
        let limit = bucket + 60
        while bucket < limit {
            if let window = MockSMCProvider.spikeWindow(inBucket: bucket), window.duration > 100 {
                return window.start
            }
            bucket += 1
        }
        Issue.record("No sustained window found — spike model changed?")
        return epoch
    }

    /// First moment the fan target is pinned at minimum while the die is still
    /// well above its resting temperature **and stays unloaded for the next
    /// 40 s**.
    ///
    /// The quiet requirement is not decoration: without it the scan happily
    /// returns the instant *before* a spike, where the target has not yet
    /// caught up and the die is about to climb 30 °C. The first version did
    /// exactly that and reported a die 29 °C hotter after "cooling" for 30 s.
    private static func firstPinnedCooldown() -> TimeInterval {
        let floor = MockSMCProvider.equilibriumRise(watts: MockSMCProvider.idleWatts, fanFraction: 0)
        var t = epoch
        while t < epoch + 3600 {
            let fan = MockSMCProvider.fans(at: t)[0]
            if abs(fan.targetRPM - fan.minRPM) < 0.5,
               MockSMCProvider.state(at: t).dieRise > floor + 6,
               stride(from: 0.0, through: 40.0, by: 2.0)
               .allSatisfy({ MockSMCProvider.spikeEnvelope(at: t + $0) == 0 })
            {
                return t
            }
            t += 0.5
        }
        Issue.record("No pinned cooldown found in the first hour — spike model changed?")
        return epoch
    }
}
