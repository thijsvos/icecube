// HelperLogicTests.swift — write-sequencer branches (M1/M2, M3/M4 Ftst, M5) and SafetyMonitor rules.

import Foundation
import Testing
@testable import ZephyrKit

/// A scripted fake SMC firmware. Generation behavior is configurable; every
/// write is recorded for assertions.
private actor FakeFirmware: SMCControlPort {
    enum Generation {
        case m2 // direct mode writes accepted, uppercase Md, Ftst exists
        case m3 // mode writes rejected 0x82 until Ftst == 1, uppercase Md
        case m5 // lowercase md, no Ftst key, direct writes accepted
    }

    let generation: Generation
    private(set) var values: [String: Double]
    private(set) var writes: [(key: String, value: Double)] = []
    /// m3: how many post-Ftst mode writes still get rejected (settling).
    var pendingRejections: Int

    init(generation: Generation, fans: [Fan], pendingRejections: Int = 2) {
        self.generation = generation
        self.pendingRejections = pendingRejections
        var v: [String: Double] = ["FNum": Double(fans.count)]
        for fan in fans {
            v["F\(fan.id)Ac"] = fan.actualRPM
            v["F\(fan.id)Tg"] = fan.targetRPM
            v["F\(fan.id)Mn"] = fan.minRPM
            v["F\(fan.id)Mx"] = fan.maxRPM
            v[generation == .m5 ? "F\(fan.id)md" : "F\(fan.id)Md"] = 3
        }
        if generation != .m5 {
            v["Ftst"] = 0
        }
        values = v
    }

    func hasKey(_ key: String) async -> Bool {
        values[key] != nil
    }

    func readDouble(_ key: String) async throws -> Double {
        guard let value = values[key] else { throw ZephyrError.smcKeyNotFound(key: key) }
        return value
    }

    func writeDouble(_ key: String, value: Double, as _: SMCDataType) async throws {
        guard values[key] != nil else { throw ZephyrError.smcKeyNotFound(key: key) }
        let isModeWrite = key.hasSuffix("Md") || key.hasSuffix("md")
        if generation == .m3, isModeWrite, value == 1 {
            // thermalmonitord holds mode 3 until Ftst == 1 and it settles.
            if values["Ftst"] != 1 || pendingRejections > 0 {
                if values["Ftst"] == 1 {
                    pendingRejections -= 1
                }
                throw ZephyrError.smcFirmwareRejected(key: key, result: SMCResult.badCommand)
            }
        }
        values[key] = value
        writes.append((key, value))
    }

    func writtenKeys() -> [String] {
        writes.map(\.key)
    }
}

private let testFans = [
    Fan(id: 0, name: "Left", mode: .system, actualRPM: 3000, targetRPM: 3000, minRPM: 2317, maxRPM: 6800),
    Fan(id: 1, name: "Right", mode: .system, actualRPM: 3000, targetRPM: 3000, minRPM: 2317, maxRPM: 6800),
]

/// Sleep injection that never actually waits.
private let instantSleep: @Sendable (Duration) async -> Void = { _ in }

@Suite("FanWriteSequencer")
struct FanWriteSequencerTests {
    @Test("M2-style firmware: direct branch, clamped targets, verified read-back")
    func directBranch() async throws {
        let firmware = FakeFirmware(generation: .m2, fans: testFans)
        let sequencer = FanWriteSequencer(port: firmware, sleep: instantSleep)
        let outcome = try await sequencer.engageManual(
            targets: [0: 4000, 1: 20000], // fan 1 requests an insane 20k RPM
            fans: testFans
        )
        #expect(outcome.branch == .direct)
        #expect(outcome.verified)
        #expect(outcome.clampedTargets == [0: 4000, 1: 6800], "20k must clamp to Mx")
        #expect(try await firmware.readDouble("F0Md") == 1)
        #expect(try await firmware.readDouble("F1Tg") == 6800)
    }

    @Test("Requests below the minimum clamp UP to Mn — a fan can never be commanded slower than its floor")
    func clampFloor() async throws {
        let firmware = FakeFirmware(generation: .m2, fans: testFans)
        let sequencer = FanWriteSequencer(port: firmware, sleep: instantSleep)
        let outcome = try await sequencer.engageManual(targets: [0: 0], fans: testFans)
        #expect(outcome.clampedTargets[0] == 2317)
        #expect(try await firmware.readDouble("F0Tg") == 2317)
    }

    @Test("M3-style firmware: 0x82 rejections escalate to the Ftst unlock branch")
    func ftstBranch() async throws {
        let firmware = FakeFirmware(generation: .m3, fans: testFans, pendingRejections: 3)
        let sequencer = FanWriteSequencer(port: firmware, sleep: instantSleep)
        let outcome = try await sequencer.engageManual(targets: [0: 4000], fans: testFans)
        #expect(outcome.branch == .ftst)
        #expect(outcome.verified)
        #expect(try await firmware.readDouble("Ftst") == 1, "unlock key written")
        #expect(try await firmware.readDouble("F0Md") == 1, "mode eventually stuck")
    }

    @Test("M5-style firmware: lowercase F{i}md probed and used, no Ftst")
    func m5LowercaseBranch() async throws {
        let firmware = FakeFirmware(generation: .m5, fans: testFans)
        let sequencer = FanWriteSequencer(port: firmware, sleep: instantSleep)
        let outcome = try await sequencer.engageManual(targets: [0: 5000], fans: testFans)
        #expect(outcome.branch == .direct)
        #expect(try await firmware.readDouble("F0md") == 1)
    }

    @Test("Revert parks targets at the fan minimum (NEVER 0), hands back to the system, clears Ftst")
    func revertSequence() async throws {
        let firmware = FakeFirmware(generation: .m3, fans: testFans, pendingRejections: 1)
        let sequencer = FanWriteSequencer(port: firmware, sleep: instantSleep)
        _ = try await sequencer.engageManual(targets: [0: 4000, 1: 4000], fans: testFans)
        try await sequencer.revertAllAuto(fans: testFans)
        // Field-corrected sequence: Tg parked at Mn (a 0-RPM target left real
        // fans stopped dead on Mac14,9), then mode 0, then mode 3 attempt.
        #expect(try await firmware.readDouble("F0Tg") == 2317, "target parked at minimum, not 0")
        #expect(try await firmware.readDouble("F1Tg") == 2317)
        #expect(try await firmware.readDouble("F0Md") == 3, "handed back to the system where accepted")
        #expect(try await firmware.readDouble("Ftst") == 0, "Ftst cleared after last fan reverts")
        let modeWrites = await firmware.writes.filter { $0.key == "F0Md" }.map(\.value)
        #expect(modeWrites.suffix(2) == [0, 3], "mode 0 then explicit mode-3 hand-back")
        let zeroTargets = await firmware.writes.filter { $0.key.hasSuffix("Tg") && $0.value == 0 }
        #expect(zeroTargets.isEmpty, "a 0-RPM target must never be written, not even on revert")
    }

    @Test("A machine with no mode key at all refuses manual mode")
    func noModeKey() async throws {
        let firmware = FakeFirmware(generation: .m2, fans: testFans)
        _ = try? await firmware.writeDouble("F0Md", value: 3, as: .uint8) // leave key present
        let broken = FakeFirmware(generation: .m2, fans: [])
        let sequencer = FanWriteSequencer(port: broken, sleep: instantSleep)
        await #expect(throws: ZephyrError.self) {
            _ = try await sequencer.engageManual(targets: [0: 4000], fans: testFans)
        }
    }
}

@Suite("SafetyMonitor")
struct SafetyMonitorTests {
    private let epoch = Date(timeIntervalSince1970: 1_753_000_000)

    private func temps(_ celsius: Double, key: String = "Tp01") -> [SensorReading] {
        [SensorReading(key: key, label: key, celsius: celsius)]
    }

    @Test("Watchdog: manual mode reverts after 15 s without a heartbeat")
    func watchdogManual() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 4000])
        #expect(monitor.evaluate(
            now: epoch, lastHeartbeat: epoch.addingTimeInterval(-10),
            config: manual, temperatures: temps(60)
        ) == .ok)
        let verdict = monitor.evaluate(
            now: epoch, lastHeartbeat: epoch.addingTimeInterval(-16),
            config: manual, temperatures: temps(60)
        )
        guard case .revertToAuto = verdict else {
            Issue.record("expected revert, got \(verdict)")
            return
        }
    }

    @Test("Watchdog: manual mode is watchdogged even with persist-without-app on")
    func manualAlwaysWatchdogged() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 4000], persistsWithoutApp: true)
        let verdict = monitor.evaluate(
            now: epoch, lastHeartbeat: epoch.addingTimeInterval(-20),
            config: manual, temperatures: temps(60)
        )
        guard case .revertToAuto = verdict else {
            Issue.record("manual mode must always be watchdogged; got \(verdict)")
            return
        }
    }

    @Test("Watchdog: persistent curve mode survives without heartbeats; non-persistent doesn't")
    func curvePersistence() {
        var monitor = SafetyMonitor()
        let persistent = FanConfig(mode: .curve, persistsWithoutApp: true)
        #expect(monitor.evaluate(
            now: epoch, lastHeartbeat: nil, config: persistent, temperatures: temps(60)
        ) == .ok)

        var monitor2 = SafetyMonitor()
        let ephemeral = FanConfig(mode: .curve, persistsWithoutApp: false)
        let verdict = monitor2.evaluate(
            now: epoch, lastHeartbeat: epoch.addingTimeInterval(-30),
            config: ephemeral, temperatures: temps(60)
        )
        guard case .revertToAuto = verdict else {
            Issue.record("non-persistent curve must be watchdogged; got \(verdict)")
            return
        }
    }

    @Test("Ceiling: needs N consecutive hot ticks (debounce), then forces cooling")
    func ceilingDebounce() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 2500])
        // Two hot ticks: still ok (debounce). A cool tick resets the count.
        #expect(monitor.evaluate(now: epoch, lastHeartbeat: epoch, config: manual, temperatures: temps(106)) == .ok)
        #expect(monitor.evaluate(now: epoch, lastHeartbeat: epoch, config: manual, temperatures: temps(106)) == .ok)
        #expect(monitor.evaluate(now: epoch, lastHeartbeat: epoch, config: manual, temperatures: temps(70)) == .ok)
        // Three consecutive hot ticks trigger.
        _ = monitor.evaluate(now: epoch, lastHeartbeat: epoch, config: manual, temperatures: temps(106))
        _ = monitor.evaluate(now: epoch, lastHeartbeat: epoch, config: manual, temperatures: temps(106))
        let verdict = monitor.evaluate(now: epoch, lastHeartbeat: epoch, config: manual, temperatures: temps(106))
        guard case .forceMaxCooling = verdict else {
            Issue.record("expected forced cooling, got \(verdict)")
            return
        }
    }

    @Test("Ceiling: die sensors trip at 104 °C, non-die sensors already at 95 °C")
    func perClassCeilings() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 2500])
        for _ in 0 ..< 3 {
            _ = monitor.evaluate(
                now: epoch,
                lastHeartbeat: epoch,
                config: manual,
                temperatures: temps(100, key: "Tp01")
            )
        }
        // 100 °C on a die sensor: below the 104 ceiling → never trips.
        #expect(monitor.evaluate(
            now: epoch,
            lastHeartbeat: epoch,
            config: manual,
            temperatures: temps(100, key: "Tp01")
        ) == .ok)

        var monitor2 = SafetyMonitor()
        for _ in 0 ..< 2 {
            _ = monitor2.evaluate(
                now: epoch,
                lastHeartbeat: epoch,
                config: manual,
                temperatures: temps(96, key: "TB1T")
            )
        }
        let verdict = monitor2.evaluate(
            now: epoch,
            lastHeartbeat: epoch,
            config: manual,
            temperatures: temps(96, key: "TB1T")
        )
        guard case .forceMaxCooling = verdict else {
            Issue.record("96 °C battery must force cooling; got \(verdict)")
            return
        }
    }

    @Test("Ceiling: cooling holds through the hysteresis band and releases 5 °C below")
    func ceilingHysteresis() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 2500])
        for _ in 0 ..< 3 {
            _ = monitor.evaluate(now: epoch, lastHeartbeat: epoch, config: manual, temperatures: temps(106))
        }
        // 101 °C: below the 104 ceiling but inside the release band → keep cooling.
        guard case .forceMaxCooling = monitor.evaluate(
            now: epoch, lastHeartbeat: epoch, config: manual, temperatures: temps(101)
        ) else {
            Issue.record("must keep cooling inside the hysteresis band")
            return
        }
        // 98 °C: below ceiling − 5 → released.
        #expect(monitor.evaluate(now: epoch, lastHeartbeat: epoch, config: manual, temperatures: temps(98)) == .ok)
    }

    @Test("Sensor failure: >3 consecutive failed reads in manual mode reverts; auto mode tolerates")
    func sensorFailures() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 4000])
        for _ in 0 ..< 3 {
            #expect(monitor.evaluate(now: epoch, lastHeartbeat: epoch, config: manual, temperatures: nil) == .ok)
        }
        let verdict = monitor.evaluate(now: epoch, lastHeartbeat: epoch, config: manual, temperatures: nil)
        guard case .revertToAuto = verdict else {
            Issue.record("4th failed read must revert; got \(verdict)")
            return
        }

        var monitor2 = SafetyMonitor()
        for _ in 0 ..< 10 {
            #expect(monitor2.evaluate(now: epoch, lastHeartbeat: nil, config: .auto, temperatures: nil) == .ok)
        }
    }

    @Test("Auto mode: never reverts, never forces (nothing is held)")
    func autoModeInert() {
        var monitor = SafetyMonitor()
        for _ in 0 ..< 5 {
            #expect(monitor.evaluate(now: epoch, lastHeartbeat: nil, config: .auto, temperatures: temps(108)) == .ok)
        }
    }
}
