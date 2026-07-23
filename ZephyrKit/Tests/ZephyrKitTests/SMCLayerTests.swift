// SMCLayerTests.swift — wire-struct ABI, key maps, polling stream, diagnostics report, mock key dump.

import Foundation
import Testing
@testable import ZephyrKit

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

@Suite("SMCPollingActor")
struct SMCPollingActorTests {
    @Test("The stream delivers snapshots immediately and keeps delivering")
    func deliversSnapshots() async {
        let provider = MockSMCProvider(now: { Date(timeIntervalSince1970: 1_753_000_000) })
        let poller = SMCPollingActor(provider: provider, interval: .milliseconds(5))
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
        let poller = SMCPollingActor(provider: provider, interval: .milliseconds(1))
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
