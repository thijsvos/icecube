// MockSMCProviderTests.swift — proves the thermal simulation is deterministic, bounded, and physically consistent.

import Foundation
import Testing
@testable import ZephyrKit

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

    @Test("actualRPM chases targetRPM with the documented ~10 s first-order lag")
    func actualFollowsTargetWithLag() async throws {
        let start = Self.firstPlateauStart()
        let dt = 5.0
        let clock = TestClock(Date(timeIntervalSince1970: start))
        let provider = MockSMCProvider(now: clock.closure)

        let before = try await provider.fans()[0]
        clock.advance(by: dt)
        let after = try await provider.fans()[0]

        // At plateau start the fan is still far behind its target.
        let gapBefore = before.targetRPM - before.actualRPM
        #expect(gapBefore > 500)

        // The envelope is flat here, so the target is nearly constant and the
        // gap must shrink by ~e^(−dt/τ). Allow 10 % of the starting gap for
        // the sensors' background wander nudging the target.
        let gapAfter = after.targetRPM - after.actualRPM
        let expectedGap = gapBefore * exp(-dt / MockSMCProvider.fanTimeConstant)
        #expect(abs(gapAfter - expectedGap) < 0.10 * gapBefore)
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
