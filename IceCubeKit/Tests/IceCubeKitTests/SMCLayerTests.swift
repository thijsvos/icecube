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

    /// The gap that made an M3 unusable, pinned against the document that
    /// described it.
    ///
    /// `docs/SMC-KEYS.md` has recorded since 2026-07-28 that M3's die sensors
    /// are `Te0*`/`Tf*`. The daemon's candidate list contained neither until
    /// 2026-08-07, so `SensorReader`'s `hasDie` guard could never pass on that
    /// hardware: it read as blind every tick and `SafetyMonitor` reverted every
    /// curve about six seconds after the user applied it — while the app showed
    /// correct temperatures throughout, because the app enumerates keys and the
    /// daemon cannot.
    ///
    /// Asserted on the **prefix**, not on individual keys: the suffixes are a
    /// sweep and nobody here has the hardware to pin them. What must not
    /// regress is that each documented die prefix is probed at all, and that
    /// `classify` still calls it a die when found — together, that is exactly
    /// what `hasDie` needs.
    @Test(
        "Every die prefix docs/SMC-KEYS.md names is probed, and classifies as a die",
        arguments: ["Tp", "Tg", "Te", "Tf"]
    )
    func documentedDiePrefixesAreProbedAndClassified(prefix: String) {
        let probed = SMCKeyMaps.fallbackCandidateSensors.filter { $0.key.hasPrefix(prefix) }
        #expect(!probed.isEmpty, "\(prefix)* is a documented die prefix the daemon cannot probe")
        for sensor in probed {
            #expect(
                SMCKeyMaps.isDieKey(sensor.key),
                "\(sensor.key) is probed but classifies as ambient, so it cannot satisfy hasDie"
            )
        }
    }

    /// `SensorReader` caches its admitted set only when it contains a die key,
    /// so a candidate list without one is the difference between working and
    /// silently reverting every curve.
    @Test("The fallback list can satisfy the daemon's die requirement")
    func fallbackContainsDieKeys() {
        let dieKeys = SMCKeyMaps.fallbackCandidateSensors.filter { SMCKeyMaps.isDieKey($0.key) }
        #expect(dieKeys.count > 50, "a thin die list is how an unmapped Mac ends up blind")
        #expect(
            Set(SMCKeyMaps.fallbackCandidateSensors.map(\.key)).count
                == SMCKeyMaps.fallbackCandidateSensors.count,
            "no duplicate candidates — each one costs a probe"
        )
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
    /// Reports get attached to GitHub issues and sit there. A v1 report filed
    /// before the write-path self-test existed must still decode once the
    /// schema moves on, or every historical bug report becomes unreadable the
    /// day the field is added.
    @Test("A v1 report from before the self-test existed still decodes")
    func v1ReportStillDecodes() throws {
        let v1 = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-01T12:00:00Z",
          "modelIdentifier": "Mac15,3",
          "osVersion": "26.0.0",
          "appVersion": "0.1.0",
          "simulated": false,
          "fans": [],
          "temperatures": [],
          "keys": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticsReport.self, from: Data(v1.utf8))
        #expect(report.schemaVersion == 1)
        #expect(report.writePath == nil)
        #expect(report.modelIdentifier == "Mac15,3")
    }

    /// And a report that DOES carry a verdict survives the same round-trip —
    /// this is the field a new-model issue is really about.
    @Test("A report carrying a write-path verdict round-trips intact")
    func writePathSurvivesRoundTrip() async throws {
        let provider = MockSMCProvider(now: { Date(timeIntervalSince1970: 1_753_000_000) })
        let verdict = WritePathReport(
            verdict: .notVerified, modeKeySuffix: "md", unlockBranch: "ftst",
            fanCount: 2, hasFtstKey: true, detail: "accepted but ignored"
        )
        let report = try await DiagnosticsReport.generate(
            provider: provider, isSimulated: true, appVersion: "test", writePath: verdict
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticsReport.self, from: report.jsonData())
        #expect(decoded.writePath?.verdict == .notVerified)
        #expect(decoded.writePath?.unlockBranch == "ftst")
    }

    @Test("A report generated from the mock round-trips through its own JSON")
    func reportRoundTrip() async throws {
        let provider = MockSMCProvider(now: { Date(timeIntervalSince1970: 1_753_000_000) })
        let report = try await DiagnosticsReport.generate(
            provider: provider, isSimulated: true, appVersion: "test"
        )
        #expect(report.simulated)
        // v3 added `decisions`; v4 added `watts` and `coolingResistance`.
        // Bumped deliberately, and this assertion is the thing that made each
        // change deliberate rather than accidental.
        #expect(report.schemaVersion == 4)
        // The mock reports power, so a report from it must carry watts — this
        // is the field the CLI's own comment had been asking for since v1.
        #expect(report.watts != nil, "a provider that reports power must put it in the report")
        #expect(report.writePath == nil, "the CLI has no daemon, so it cannot claim a verdict")
        #expect(
            report.decisions == nil,
            "and for the same reason it has no decision log — those come from the daemon"
        )
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

/// Which sensors a Mac *has* must not depend on which millisecond the app
/// launched in. This is the rule that decides it, and it has been wrong once:
/// admitting a key only when its first reading looked plausible turned a
/// power-gated CPU cluster — which reports a frozen 6.70/4.63 °C sentinel — into
/// "this Mac has no P-cores", permanently, for that process. Five consecutive
/// `icecube-diag` runs on one idle Mac14,9 resolved 20, 16, 20, 16, 20 of the
/// same 20 keys.
@Suite("SensorAdmission — membership comes from existence, never from a value")
struct SensorAdmissionTests {
    private static let candidates = [
        SMCKeyMaps.SensorDescriptor(key: "Tp01", label: "CPU P-core 1"),
        SMCKeyMaps.SensorDescriptor(key: "Tp05", label: "CPU P-core 2"),
        SMCKeyMaps.SensorDescriptor(key: "Tg0f", label: "GPU 1"),
        SMCKeyMaps.SensorDescriptor(key: "TB2T", label: "Battery 2"),
    ]

    private func admit(_ probes: [String: SensorAdmission.Probe]) -> [String] {
        SensorAdmission.admit(candidates: Self.candidates, probes: probes).map(\.key)
    }

    /// The whole point: a gated cluster still reads, it just reads nonsense.
    /// The admission rule never sees a value, so it cannot be fooled by one.
    @Test("A key the firmware knows is admitted whatever it would read")
    func existenceIsEnough() {
        #expect(
            admit([
                "Tp01": .present(type: "flt "), "Tp05": .present(type: "flt "),
                "Tg0f": .present(type: "flt "), "TB2T": .present(type: "flt "),
            ]) == ["Tp01", "Tp05", "Tg0f", "TB2T"]
        )
    }

    /// An absent key throws on probe — measured, 13 of 13 absent candidates on
    /// every attempt — which is what makes existence safe to trust. Mac14,9
    /// carries curated keys for a second battery and extra GPU dies that only
    /// an M2 Max populates; those must stay out.
    @Test("A key this model does not have is refused")
    func absentKeysAreRefused() {
        #expect(admit(["Tp01": .present(type: "flt "), "TB2T": .absent]) == ["Tp01"])
    }

    /// A candidate nobody probed is not a candidate we may admit. Silently
    /// treating a missing probe as present would let a transport failure
    /// fabricate sensors.
    @Test("A candidate with no probe result at all is refused")
    func unprobedKeysAreRefused() {
        #expect(admit([:]).isEmpty)
    }

    /// `flag` and `{fds` exist and answer, but carry no temperature. Admitting
    /// one would put a permanent junk row in the list — the failure the old
    /// value-based rule was reaching for, kept without the lottery.
    @Test("A key whose wire type cannot carry a temperature is refused")
    func undecodableTypesAreRefused() {
        #expect(admit(["Tp01": .present(type: "flag"), "Tp05": .present(type: "{fds")]).isEmpty)
        #expect(admit(["Tp01": .present(type: "ui16"), "Tp05": .present(type: "fpe2")]).count == 2)
    }

    /// A type string the codec has never heard of is refused rather than
    /// guessed at: we would have no way to decode its bytes.
    @Test("An unrecognized wire type is refused")
    func unknownTypesAreRefused() {
        #expect(admit(["Tp01": .present(type: "zzzz")]).isEmpty)
    }

    /// The popover, the charts and the Sensors window all render this order.
    /// Deriving it from the probe dictionary would swap one per-launch lottery
    /// for another, since dictionary iteration order is not stable.
    @Test("Admitted sensors keep the candidate list's order, not the dictionary's")
    func orderFollowsTheCandidateList() {
        let probes = Dictionary(
            uniqueKeysWithValues: Self.candidates.map { ($0.key, SensorAdmission.Probe.present(type: "flt ")) }
        )
        for _ in 0 ..< 50 {
            #expect(admit(probes) == Self.candidates.map(\.key))
        }
    }
}
