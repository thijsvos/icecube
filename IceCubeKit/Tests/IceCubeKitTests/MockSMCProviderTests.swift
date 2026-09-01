// MockSMCProviderTests.swift — proves the thermal simulation is deterministic, bounded, and physically consistent.

import Foundation
@testable import IceCubeKit
import Testing

/// A manually-advanced clock. Injecting it into `MockSMCProvider` replays the
/// exact same simulated timeline on every test run.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    /// The closure to pass to `MockSMCProvider(now:)`.
    var closure: @Sendable () -> Date {
        { self.now }
    }
}

@Suite("MockSMCProvider")
struct MockSMCProviderTests {
    /// A fixed simulated "now". Every test starts the timeline here.
    static let epoch = Date(timeIntervalSince1970: 1_753_000_000)
    static let epochSeconds = epoch.timeIntervalSince1970

    // MARK: Timeline scans (deterministic, so scans always find the same spots)

    /// First time ≥ `epoch + 120` with no spike anywhere in the previous
    /// 120 s — long past the 80 s fan-lag horizon, so fans are fully settled.
    private static func firstQuietTime() -> TimeInterval {
        var t = epochSeconds + 120
        while t < epochSeconds + 3600 {
            var quiet = true
            var back = 0.0
            while back <= 120 {
                if MockSMCProvider.spikeEnvelope(at: t - back) != 0 {
                    quiet = false; break
                }
                back += 5
            }
            if quiet {
                return t
            }
            t += 5
        }
        Issue.record("No quiet window found in the first hour — spike model changed?")
        return epochSeconds
    }

    /// Start of the first spike plateau (constant envelope for ≥ 6 s beyond
    /// the scan hit): the envelope is flat there, so `targetRPM` is nearly
    /// constant and the first-order-lag law can be checked directly.
    private static func firstPlateauStart() -> TimeInterval {
        var t = epochSeconds
        while t < epochSeconds + 1800 {
            let envelope = MockSMCProvider.spikeEnvelope(at: t)
            if envelope > 0.7, envelope == MockSMCProvider.spikeEnvelope(at: t + 6) {
                var start = t
                while MockSMCProvider.spikeEnvelope(at: start - 0.25) == envelope {
                    start -= 0.25
                }
                return start
            }
            t += 0.5
        }
        Issue.record("No spike plateau found in the first 30 min — spike model changed?")
        return epochSeconds
    }

    // MARK: Determinism

    @Test("Two providers sharing a clock produce bit-identical readings")
    func providersWithSameClockAgree() async throws {
        let clock = TestClock(Self.epoch)
        let first = MockSMCProvider(now: clock.closure)
        let second = MockSMCProvider(now: clock.closure)
        for _ in 0 ..< 20 {
            let fansA = try await first.fans()
            let fansB = try await second.fans()
            #expect(fansA == fansB)
            let tempsA = try await first.temperatures()
            let tempsB = try await second.temperatures()
            #expect(tempsA == tempsB)
            clock.advance(by: 7.3)
        }
    }

    @Test("A frozen clock makes every read exactly reproducible")
    func frozenClockIsReproducible() async throws {
        let provider = MockSMCProvider(now: { Self.epoch })
        let fans = try await provider.fans()
        let temps = try await provider.temperatures()
        for _ in 0 ..< 5 {
            let fansAgain = try await provider.fans()
            let tempsAgain = try await provider.temperatures()
            #expect(fansAgain == fans)
            #expect(tempsAgain == temps)
        }
    }

    // MARK: Shape and bounds

    @Test("Sensors are the six expected M2-generation keys, in stable order")
    func sensorIdentity() async throws {
        let temps = try await MockSMCProvider(now: { Self.epoch }).temperatures()
        #expect(temps.map(\.key) == ["Tp01", "Tp1h", "Tg0f", "TH0x", "TB1T", "TaLP"])
        #expect(temps.map(\.label) == [
            "CPU P-cores",
            "CPU E-cores",
            "GPU",
            "SSD",
            "Battery",
            "Airflow Left",
        ])
    }

    @Test("Fans report the Mac14,9 identity and stay within [min, max]; temps stay within 20–110 °C")
    func boundsHoldAcrossTwoHours() async throws {
        let clock = TestClock(Self.epoch)
        let provider = MockSMCProvider(now: clock.closure)
        var checked = 0
        while clock.now.timeIntervalSince(Self.epoch) <= 7200 {
            let fans = try await provider.fans()
            #expect(fans.map(\.id) == [0, 1])
            #expect(fans.map(\.name) == ["Left", "Right"])
            #expect(fans.map(\.minRPM) == [2317, 2317])
            #expect(fans.map(\.maxRPM) == [6800, 6800])
            for fan in fans {
                #expect(fan.mode == .system)
                #expect(fan.actualRPM >= fan.minRPM && fan.actualRPM <= fan.maxRPM)
                #expect(fan.targetRPM >= fan.minRPM && fan.targetRPM <= fan.maxRPM)
            }
            for reading in try await provider.temperatures() {
                #expect(reading.celsius >= 20 && reading.celsius <= 110)
            }
            checked += 1
            clock.advance(by: 15)
        }
        #expect(checked > 400)
    }

    // MARK: Physical plausibility

    @Test("After a long quiet stretch the fans rest at minimum RPM")
    func fansRestAtMinimumWhenIdle() async throws {
        let quiet = Self.firstQuietTime()
        let fans = try await MockSMCProvider(now: { Date(timeIntervalSince1970: quiet) }).fans()
        for fan in fans {
            #expect(abs(fan.targetRPM - fan.minRPM) < 0.5)
            #expect(abs(fan.actualRPM - fan.minRPM) < 0.5)
        }
    }

    @Test("During a spike the hottest sensor is CPU or GPU and the fans spool up")
    func spikeHeatsCPUAndSpoolsFans() async throws {
        let plateau = Self.firstPlateauStart()
        let provider = MockSMCProvider(now: { Date(timeIntervalSince1970: plateau + 3) })
        let snapshot = try await provider.snapshot()
        let hottest = try #require(snapshot.hottest)
        #expect(["Tp01", "Tg0f"].contains(hottest.key))
        #expect(hottest.celsius > 80)
        for fan in snapshot.fans {
            let range = fan.maxRPM - fan.minRPM
            #expect(fan.targetRPM > fan.minRPM + 0.4 * range)
        }
    }

    // MARK: SoC power

    /// Simulated watts must stay inside the range measured on the real machine
    /// (19.6 W idle, ~52 W peak on a Mac14,9), rest at idle when nothing is
    /// running, and climb with the workload — so `icecube-diag --watch` and the
    /// diagnostics report are demonstrable with no hardware.
    @Test("Simulated power rests at idle, rises with load, and stays in range")
    func powerTracksTheWorkload() async throws {
        let quiet = Self.firstQuietTime()
        let idle = try await MockSMCProvider(now: { Date(timeIntervalSince1970: quiet) }).power()
        #expect(try #require(idle) == MockSMCProvider.idleWatts, "a quiet machine draws idle power")

        let plateau = Self.firstPlateauStart()
        let loaded = try await MockSMCProvider(now: { Date(timeIntervalSince1970: plateau + 3) }).power()
        #expect(try #require(loaded) > MockSMCProvider.idleWatts + 10, "a spike must be visible in watts")

        // Sweep an hour: never outside the measured envelope, never nil.
        for step in stride(from: 0.0, through: 3600, by: 7) {
            let watts = try await MockSMCProvider(
                now: { Date(timeIntervalSince1970: Self.epochSeconds + step) }
            ).power()
            let value = try #require(watts)
            #expect(value >= MockSMCProvider.idleWatts)
            #expect(value <= MockSMCProvider.peakWatts)
            #expect(SMCKeyMaps.isPlausiblePower(value), "the real provider's filter must accept it too")
        }
    }

    /// The first moment the fan target is pinned at minimum while the fan is
    /// still well above it — a cooldown, where the target is *exactly*
    /// constant and the gap decays by the lag law alone.
    private static func firstPinnedCooldown() -> TimeInterval {
        var t = epochSeconds
        while t < epochSeconds + 3600 {
            let fan = MockSMCProvider.fans(at: t)[0]
            if abs(fan.targetRPM - fan.minRPM) < 0.5, fan.actualRPM - fan.targetRPM > 700 {
                return t
            }
            t += 0.5
        }
        Issue.record("No pinned cooldown found in the first hour — spike model changed?")
        return epochSeconds
    }

    /// Moved from the spike plateau to the cooldown on 2026-09-01, when the
    /// die gained thermal mass.
    ///
    /// The old version measured the gap at `firstPlateauStart()` and its own
    /// comment carried the premise: *"the envelope is flat here, so the target
    /// is nearly constant."* That held only while temperature was a pure
    /// function of the workload envelope. Now a flat envelope means constant
    /// **power**, and the die keeps climbing toward the equilibrium that power
    /// implies — so the target climbs with it, by ~2,900 RPM over the first ten
    /// seconds of a plateau. The gap was no longer governed by the fan's lag at
    /// all, and the test failed by 1,771 RPM against a 104 RPM tolerance.
    ///
    /// A cooldown has the property the plateau used to fake: once the die has
    /// dropped back under the 60 °C demand floor the target is pinned at
    /// `minRPM` and cannot move, while the fan still has hundreds of RPM to
    /// coast. The target is now *exactly* constant rather than nearly, so the
    /// tolerance tightens from 10 % of the gap to 2 %.
    @Test("actualRPM chases targetRPM with the documented ~10 s first-order lag")
    func actualFollowsTargetWithLag() async throws {
        let start = Self.firstPinnedCooldown()
        let dt = 5.0
        let clock = TestClock(Date(timeIntervalSince1970: start))
        let provider = MockSMCProvider(now: clock.closure)

        let before = try await provider.fans()[0]
        clock.advance(by: dt)
        let after = try await provider.fans()[0]

        // The target is at the floor and stays there, so the whole of the gap
        // is the fan coasting down.
        #expect(abs(after.targetRPM - after.minRPM) < 0.5, "the target must not move during the measurement")
        let gapBefore = before.actualRPM - before.targetRPM
        #expect(gapBefore > 500)

        let gapAfter = after.actualRPM - after.targetRPM
        let expectedGap = gapBefore * exp(-dt / MockSMCProvider.fanTimeConstant)
        #expect(
            abs(gapAfter - expectedGap) < 0.02 * gapBefore,
            "gap \(gapBefore) → \(gapAfter), lag law predicts \(expectedGap)"
        )
    }

    @Test("Consecutive reads move actualRPM toward targetRPM, never away")
    func consecutiveReadsApproachTarget() async throws {
        let start = Self.firstPlateauStart()
        let clock = TestClock(Date(timeIntervalSince1970: start))
        let provider = MockSMCProvider(now: clock.closure)
        var previous = try await provider.fans()[0]
        for _ in 0 ..< 5 {
            clock.advance(by: 2)
            let current = try await provider.fans()[0]
            if previous.targetRPM - previous.actualRPM > 200 {
                #expect(current.actualRPM > previous.actualRPM)
            }
            previous = current
        }
    }

    // MARK: Settle capability (the °C/W demo path)

    /// The first sustained-load window on the timeline (a spike that fills
    /// its whole bucket), for tests that need a long flat plateau.
    private static func firstSustainedWindow() -> MockSMCProvider.SpikeWindow? {
        for offset in 0 ..< 200 {
            let bucket = (Self.epochSeconds / MockSMCProvider.spikeBucketLength).rounded(.down)
                + Double(offset)
            if let window = MockSMCProvider.spikeWindow(inBucket: bucket),
               window.duration == MockSMCProvider.spikeBucketLength - 24
            {
                return window
            }
        }
        return nil
    }

    /// CLAUDE.md ground rule 3: every feature must be demonstrable in
    /// simulated mode. Cooling efficiency needs the settle rule to pass —
    /// 20 s of steady die and power — and before the flat-hold damping the
    /// model never held still: ~1 % of ticks settled, in runs of a few
    /// seconds, so the °C/W readout read "—" in every demo and screenshot.
    /// The two RPM bands mirror THERMAL.md's real measurement table, which
    /// has exactly those two shapes: readings at rest and at speed.
    @Test("The simulated machine settles at idle and under sustained load, like the real one")
    func simulatedMachineSettles() {
        var tracker = CoolingEfficiency.Tracker()
        var settledTicks = 0
        var settledAtRest = false
        var atSpeedRun = 0
        var longestAtSpeedRun = 0
        // The fan's first-order lag, advanced incrementally: same law as
        // `laggedDemand`, cheap enough to run per second for three hours.
        var lagged = MockSMCProvider.demand(at: Self.epochSeconds)
        let ticks = 3 * 3600
        for step in 0 ..< ticks {
            let t = Self.epochSeconds + Double(step)
            let target = MockSMCProvider.demand(at: t)
            lagged = target + (lagged - target) * exp(-1.0 / MockSMCProvider.fanTimeConstant)
            tracker.ingest(SMCSnapshot(
                date: Date(timeIntervalSince1970: t),
                fans: [],
                temperatures: MockSMCProvider.temperatures(at: t),
                power: MockSMCProvider.power(at: t)
            ))
            let spec = MockSMCProvider.fanSpecs[0]
            let fraction = (spec.minRPM + lagged * (spec.maxRPM - spec.minRPM)) / spec.maxRPM
            guard tracker.isSettled else {
                atSpeedRun = 0
                continue
            }
            settledTicks += 1
            if fraction < 0.5 {
                settledAtRest = true
            }
            if fraction > 0.8 {
                atSpeedRun += 1
                longestAtSpeedRun = max(longestAtSpeedRun, atSpeedRun)
            } else {
                atSpeedRun = 0
            }
        }
        let fraction = Double(settledTicks) / Double(ticks)
        // 0.5 sits between the two measured states of this model: 0.39
        // settled with the damping deleted (the trailing-window fix alone
        // gets that far) and 0.69 with it in place. The floor is what makes
        // this test fail if the flat-hold ever quietly disappears.
        #expect(fraction > 0.5, "the machine must hold still often enough to demo °C/W; settled \(fraction)")
        #expect(settledAtRest, "a settled reading with the fans at rest")
        // A minute, not a blip: THERMAL.md's high-band rows are minute-long
        // holds, and only a sustained bucket can produce one — a 30–60 s
        // spike's plateau is eaten by the fan lag and the settle window.
        #expect(
            longestAtSpeedRun >= 60,
            "a minute-long settled hold at speed, like the real table; longest \(longestAtSpeedRun) s"
        )
    }

    /// Sustained loads exist so the fans can settle at speed, and are rare so
    /// the timeline still reads as a desktop, not a stress test.
    @Test("About one spiking bucket in seven holds its plateau for the whole bucket")
    func sustainedBucketsAreRare() {
        var spiking = 0
        var sustained = 0
        let firstBucket = (Self.epochSeconds / MockSMCProvider.spikeBucketLength).rounded(.down)
        for offset in 0 ..< 400 {
            guard let window = MockSMCProvider.spikeWindow(inBucket: firstBucket + Double(offset))
            else { continue }
            spiking += 1
            if window.duration == MockSMCProvider.spikeBucketLength - 24 {
                sustained += 1
                #expect(
                    window.plateauEnd - window.plateauStart > 120,
                    "a sustained plateau must outlast the fan lag plus the settle window"
                )
            }
        }
        let share = Double(sustained) / Double(spiking)
        #expect(share > 0.05 && share < 0.30, "roughly one in seven, got \(share)")
    }

    /// The damping must never put an edge in the temperature trace: within
    /// 10 s of an envelope transition the scale is exactly 1, so the ramps
    /// and their surroundings are untouched, and only a machine deep inside
    /// a steady stretch quiets down.
    @Test("The wander damps only deep inside a steady stretch, never near a transition")
    func wanderDampsOnlyAwayFromTransitions() throws {
        let window = try #require(Self.firstSustainedWindow(), "no sustained bucket in 200?")

        // 5 s before the spike starts: a transition is near, full wander.
        #expect(MockSMCProvider.wanderScale(at: window.start - 5) == 1)
        // Mid-rise: the envelope is moving, full wander.
        #expect(MockSMCProvider.wanderScale(at: window.start + 4) == 1)
        // Deep inside the plateau: damped to 15 %.
        let mid = (window.plateauStart + window.plateauEnd) / 2
        #expect(abs(MockSMCProvider.wanderScale(at: mid) - 0.15) < 1e-12)
        // Deep inside a long quiet stretch: damped the same way.
        let quiet = Self.firstQuietTime()
        if MockSMCProvider.envelopeSteadiness(at: quiet) > 25 {
            #expect(abs(MockSMCProvider.wanderScale(at: quiet) - 0.15) < 1e-12)
        }
    }

    // MARK: Composition

    @Test("snapshot() composes fans and temperatures from the same instant")
    func snapshotComposes() async throws {
        let provider = MockSMCProvider(now: { Self.epoch })
        let snapshot = try await provider.snapshot()
        let fans = try await provider.fans()
        let temperatures = try await provider.temperatures()
        #expect(snapshot.fans == fans)
        #expect(snapshot.temperatures == temperatures)
        #expect(snapshot.hottest != nil)
    }
}
