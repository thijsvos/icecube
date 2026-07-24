// SMCLayerTests.swift — wire-struct ABI, key maps, polling stream, diagnostics report, mock key dump.

import Foundation
@testable import IceCubeKit
import Testing

/// The 80-byte ABI contract with AppleSMC. If any of these fail, a Swift
/// layout change broke the wire format and every SMC call would misbehave.
@Suite("SMCParamStruct ABI")
struct SMCParamStructABITests {
    @Test("The struct is exactly 80 bytes, matching the kernel's C layout")
    func totalSize() {
        #expect(MemoryLayout<SMCParamStruct>.size == 80)
        #expect(MemoryLayout<SMCParamStruct>.stride == 80)
    }

    @Test("Field offsets match the C struct: result 40, status 41, data8 42, data32 44, bytes 48")
    func fieldOffsets() {
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.key) == 0)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.result) == 40)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.status) == 41)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.data8) == 42)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.data32) == 44)
        #expect(MemoryLayout<SMCParamStruct>.offset(of: \.bytes) == 48)
    }

    @Test("dataBytes extracts the first N bytes and clamps silly counts")
    func dataBytesExtraction() {
        var param = SMCParamStruct()
        param.bytes.0 = 0xAB
        param.bytes.1 = 0xCD
        param.bytes.2 = 0xEF
        #expect(param.dataBytes(2) == [0xAB, 0xCD])
        #expect(param.dataBytes(0) == [])
        #expect(param.dataBytes(-1) == [])
        #expect(param.dataBytes(99).count == 32)
    }
}

/// `FanMode(smcValue:)` is the daemon's only decoder for the fan-mode key, and
/// the daemon may never trap. These are the readings that would have crashed
/// the old `UInt8(raw)` conversion.
@Suite("FanMode from raw SMC readings")
struct FanModeDecodingTests {
    @Test("Known modes decode, including from a wider-than-ui8 key")
    func knownModes() {
        #expect(FanMode(smcValue: 0) == .auto)
        #expect(FanMode(smcValue: 1) == .forced)
        #expect(FanMode(smcValue: 3) == .system)
        // A ui16/ui32-typed mode key still carries a small value.
        #expect(FanMode(smcValue: 3.0) == .system)
    }

    @Test("Implausible readings degrade to .system instead of trapping")
    func implausibleReadings() {
        // Each of these traps under `UInt8(raw)`.
        #expect(FanMode(smcValue: -1) == .system)
        #expect(FanMode(smcValue: 256) == .system)
        #expect(FanMode(smcValue: 65535) == .system)
        #expect(FanMode(smcValue: 4_294_967_295) == .system)
        #expect(FanMode(smcValue: .nan) == .system)
        #expect(FanMode(smcValue: .infinity) == .system)
        #expect(FanMode(smcValue: -.infinity) == .system)
    }

    @Test("In-range values that name no case degrade to .system")
    func unknownButInRange() {
        #expect(FanMode(smcValue: 2) == .system)
        #expect(FanMode(smcValue: 255) == .system)
    }

    @Test("Fractional readings truncate toward zero, as the old conversion did")
    func truncation() {
        #expect(FanMode(smcValue: 1.9) == .forced)
        #expect(FanMode(smcValue: 3.4) == .system)
        #expect(FanMode(smcValue: 0.6) == .auto)
    }
}

@Suite("SMCKeyMaps")
struct SMCKeyMapsTests {
    @Test("The owner's Mac14,9 gets the curated M2 map (CPU, GPU, airflow present)")
    func curatedMapForM2Pro() throws {
        let sensors = try #require(SMCKeyMaps.curatedSensors(forModel: "Mac14,9"))
        let keys = sensors.map(\.key)
        #expect(keys.contains("Tp01"))
        #expect(keys.contains("Tg0f"))
        #expect(keys.contains("TaLP"))
        #expect(Set(keys).count == keys.count, "no duplicate keys")
    }

    @Test("Unknown models get nil — the enumeration fallback takes over")
    func unknownModelFallsBack() {
        #expect(SMCKeyMaps.curatedSensors(forModel: "Mac99,1") == nil)
        #expect(SMCKeyMaps.curatedSensors(forModel: "iMac20,1") == nil)
    }

    @Test("Plausibility filter: dead sensors and silicon-impossible values rejected")
    func plausibilityBounds() {
        #expect(!SMCKeyMaps.isPlausibleTemperature(0))
        #expect(!SMCKeyMaps.isPlausibleTemperature(10))
        #expect(SMCKeyMaps.isPlausibleTemperature(10.5))
        #expect(SMCKeyMaps.isPlausibleTemperature(45))
        #expect(SMCKeyMaps.isPlausibleTemperature(119))
        #expect(!SMCKeyMaps.isPlausibleTemperature(120))
        #expect(!SMCKeyMaps.isPlausibleTemperature(-30))
    }
}

@Suite("SMCPoller")
struct SMCPollerTests {
    @Test("The stream delivers snapshots immediately and keeps delivering")
    func deliversSnapshots() async {
        let provider = MockSMCProvider(now: { Date(timeIntervalSince1970: 1_753_000_000) })
        let poller = SMCPoller(provider: provider, interval: .milliseconds(5))
        var received: [SMCPollEvent] = []
        for await event in poller.events() {
            received.append(event)
            if received.count == 3 {
                break
            }
        }
        #expect(received.count == 3)
        for event in received {
            guard case let .snapshot(snapshot) = event else {
                Issue.record("expected a snapshot, got \(event)")
                continue
            }
            #expect(snapshot.fans.count == 2)
            #expect(!snapshot.temperatures.isEmpty)
        }
    }

    @Test("Breaking out of the loop tears the polling task down (no runaway)")
    func terminationStopsPolling() async throws {
        let provider = MockSMCProvider(now: { Date(timeIntervalSince1970: 1_753_000_000) })
        let poller = SMCPoller(provider: provider, interval: .milliseconds(1))
        var count = 0
        for await _ in poller.events() {
            count += 1
            if count == 1 {
                break
            }
        }
        // Reaching here without hanging is the assertion; one extra beat to
        // let onTermination cancel the task.
        try await Task.sleep(for: .milliseconds(20))
        #expect(count == 1)
    }
}

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test("A report generated from the mock round-trips through its own JSON")
    func reportRoundTrip() async throws {
        let provider = MockSMCProvider(now: { Date(timeIntervalSince1970: 1_753_000_000) })
        let report = try await DiagnosticsReport.generate(
            provider: provider, isSimulated: true, appVersion: "test"
        )
        #expect(report.simulated)
        #expect(report.schemaVersion == 1)
        #expect(report.fans.count == 2)
        #expect(report.temperatures.count == 6)
        #expect(!report.keys.isEmpty)
        #expect(!report.modelIdentifier.isEmpty)

        let data = try report.jsonData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticsReport.self, from: data)
        // ISO-8601 truncates sub-second precision, so compare piecewise.
        #expect(decoded.keys == report.keys)
        #expect(decoded.fans == report.fans)
        #expect(decoded.temperatures == report.temperatures)
        #expect(decoded.modelIdentifier == report.modelIdentifier)
    }

    @Test("The mock's key dump mirrors its own sensors and fans, with honest wire bytes")
    func mockKeyDumpConsistency() async throws {
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_753_000_000) }
        let provider = MockSMCProvider(now: clock)
        let dump = try await provider.keyDump()
        let byKey: [String: SMCKeyDump] = Dictionary(uniqueKeysWithValues: dump.map { ($0.key, $0) })

        #expect(byKey["FNum"]?.value == 2)
        // Every simulated sensor appears as a flt key with matching value.
        for reading in try await provider.temperatures() {
            let entry = try #require(byKey[reading.key], "missing \(reading.key)")
            #expect(entry.type == "flt ")
            let value = try #require(entry.value)
            // flt is float32 on the wire: expect float-precision equality.
            #expect(abs(value - reading.celsius) < 0.001)
            #expect(entry.bytesHex.count == 8, "4 bytes → 8 hex chars")
        }
        // Fan speed keys agree with the fans() view of the same instant.
        for fan in try await provider.fans() {
            let actual = try #require(byKey["F\(fan.id)Ac"]?.value)
            #expect(abs(actual - fan.actualRPM) < 0.001)
            #expect(byKey["F\(fan.id)Md"]?.value == Double(fan.mode.rawValue))
        }
    }
}

@Suite("SensorStabilizer — the list never jumps")
struct SensorStabilizerTests {
    private let sensors = [
        SMCKeyMaps.SensorDescriptor(key: "Tp01", label: "CPU P-core 1"),
        SMCKeyMaps.SensorDescriptor(key: "Tg0f", label: "GPU 1"),
        SMCKeyMaps.SensorDescriptor(key: "TB1T", label: "Battery 1"),
    ]

    @Test("A glitched read holds the last good value instead of dropping the row")
    func holdsLastGoodOnGlitch() {
        let seeded = ["Tp01": 55.0, "Tg0f": 48.0, "TB1T": 33.0]
        // Tick: Tp01 missing entirely, Tg0f implausible (0), TB1T fresh.
        let (readings, cache) = SensorStabilizer.stabilize(
            sensors: sensors,
            freshValues: ["Tg0f": 0.0, "TB1T": 34.0],
            lastGood: seeded
        )
        #expect(readings.map(\.key) == ["Tp01", "Tg0f", "TB1T"], "full list, stable order")
        #expect(readings.map(\.celsius) == [55.0, 48.0, 34.0], "held, held, fresh")
        #expect(cache == ["Tp01": 55.0, "Tg0f": 48.0, "TB1T": 34.0])
    }

    @Test("List length and order are identical across good and bad ticks")
    func stableAcrossTicks() {
        var cache = ["Tp01": 55.0, "Tg0f": 48.0, "TB1T": 33.0]
        var lengths: Set<Int> = []
        var orders: Set<[String]> = []
        let ticks: [[String: Double]] = [
            ["Tp01": 60, "Tg0f": 50, "TB1T": 33], // all fresh
            ["Tp01": 61], // two missing
            [:], // everything missing
            ["Tp01": 0, "Tg0f": 130, "TB1T": 33.5], // two implausible
        ]
        for fresh in ticks {
            let result = SensorStabilizer.stabilize(sensors: sensors, freshValues: fresh, lastGood: cache)
            cache = result.lastGood
            lengths.insert(result.readings.count)
            orders.insert(result.readings.map(\.key))
        }
        #expect(lengths == [3], "every tick publishes all 3 sensors")
        #expect(orders.count == 1, "order never changes")
    }

    @Test("Fresh plausible values always win over the cache")
    func freshWins() {
        let (readings, _) = SensorStabilizer.stabilize(
            sensors: sensors,
            freshValues: ["Tp01": 70, "Tg0f": 65, "TB1T": 35],
            lastGood: ["Tp01": 55, "Tg0f": 48, "TB1T": 33]
        )
        #expect(readings.map(\.celsius) == [70, 65, 35])
    }
}

@Suite("Sticky hottest — the badge doesn't flicker")
struct StickyHottestTests {
    private func snapshot(_ values: [(String, Double)]) -> SMCSnapshot {
        SMCSnapshot(
            date: Date(timeIntervalSince1970: 1_753_000_000),
            fans: [],
            temperatures: values.map { SensorReading(key: $0.0, label: $0.0, celsius: $0.1) }
        )
    }

    @Test("Within the hysteresis band the previous sensor keeps the title")
    func sticksWithinBand() {
        let snap = snapshot([("Tp01", 65.4), ("Tp09", 65.9)])
        let shown = snap.hottest(stickingTo: "Tp01")
        #expect(shown?.key == "Tp01")
        #expect(shown?.celsius == 65.4, "the value shown is the sticky sensor's real reading")
    }

    @Test("A decisively hotter sensor takes over")
    func switchesBeyondBand() {
        let snap = snapshot([("Tp01", 60.0), ("Tg0f", 75.0)])
        #expect(snap.hottest(stickingTo: "Tp01")?.key == "Tg0f")
    }

    @Test("No previous sensor, or a vanished one, falls back to the true max")
    func fallsBackToTrueMax() {
        let snap = snapshot([("Tp01", 60.0), ("Tg0f", 61.0)])
        #expect(snap.hottest(stickingTo: nil)?.key == "Tg0f")
        #expect(snap.hottest(stickingTo: "Txxx")?.key == "Tg0f")
        #expect(snapshot([]).hottest(stickingTo: "Tp01") == nil)
    }
}
