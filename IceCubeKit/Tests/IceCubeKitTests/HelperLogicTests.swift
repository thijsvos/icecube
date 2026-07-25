// HelperLogicTests.swift — write-sequencer branches (M1/M2, M3/M4 Ftst, M5) and SafetyMonitor rules.

import Foundation
@testable import IceCubeKit
import Testing

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
        guard let value = values[key] else { throw IceCubeError.smcKeyNotFound(key: key) }
        return value
    }

    func writeDouble(_ key: String, value: Double, as _: SMCDataType) async throws {
        guard values[key] != nil else { throw IceCubeError.smcKeyNotFound(key: key) }
        let isModeWrite = key.hasSuffix("Md") || key.hasSuffix("md")
        if generation == .m3, isModeWrite, value == 1 {
            // thermalmonitord holds mode 3 until Ftst == 1 and it settles.
            if values["Ftst"] != 1 || pendingRejections > 0 {
                if values["Ftst"] == 1 {
                    pendingRejections -= 1
                }
                throw IceCubeError.smcFirmwareRejected(key: key, result: SMCResult.badCommand)
            }
        }
        values[key] = value
        writes.append((key, value))
    }

    func writtenKeys() -> [String] {
        writes.map(\.key)
    }

    /// Simulates a key becoming unreachable, so reads and writes to it throw.
    func removeKey(_ key: String) {
        values[key] = nil
    }

    /// The sequencer never resets the port; `DaemonCoreTests` exercises that.
    func reset() async {}
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

    @Test("Curve target at fraction 0 resolves to Mn, not a sub-Mn quantized value (the Quiet-reverts-to-auto bug)")
    func quantizedTargetHoldsAtMinimum() {
        let fan = testFans[0] // Mn 2317, Mx 6800
        // A "Quiet" curve below its knee asks for fraction 0 → raw target == Mn
        // (2317). Quantizing to 50 RPM rounds that DOWN to 2300 (below Mn); the
        // write path then clamps up to 2317. If the loop stored 2300 and checked
        // read-back against it, it would mismatch every tick and revert to auto.
        let target = FanWriteSequencer.quantizedTarget(fraction: 0, fan: fan)
        #expect(target == 2317, "must resolve to Mn, not the sub-Mn quantized 2300")
        // The command must survive the write-path clamp unchanged, i.e. equal
        // exactly what reads back — this is the invariant the bug violated.
        #expect(FanWriteSequencer.clamp(target, to: fan) == target)
    }

    @Test("Curve target quantizes to 50 RPM and never lands outside the fan's range")
    func quantizedTargetQuantizesAndClamps() {
        let fan = testFans[0]
        for step in 0 ... 20 {
            let fraction = Double(step) / 20.0
            let target = FanWriteSequencer.quantizedTarget(fraction: fraction, fan: fan)
            #expect(target >= fan.minRPM && target <= fan.maxRPM)
            #expect(
                FanWriteSequencer.clamp(target, to: fan) == target,
                "the commanded target must equal what the write path sends (fraction \(fraction))"
            )
        }
        #expect(FanWriteSequencer.quantizedTarget(fraction: 1, fan: fan) == fan.maxRPM)
    }

    /// `Mn` and `Mx` are read with independent `try?`s that each fall back to
    /// 0 ("degrade per-key rather than losing the whole fan"), so a fan whose
    /// range is degenerate — or inverted — is a modelled outcome, not a
    /// hypothetical. `clamp` is the guard for it, and it is what every caller
    /// must go through: building `Mn ... Mx` as a ClosedRange directly TRAPS
    /// when Mn > Mx, which is a crash rather than a clamp.
    @Test("clamp survives a degenerate or inverted fan range instead of trapping")
    func clampDegenerateRange() {
        let inverted = Fan(
            id: 0, name: "Left", mode: .auto,
            actualRPM: 3000, targetRPM: 0, minRPM: 2317, maxRPM: 0
        )
        #expect(FanWriteSequencer.clamp(3000, to: inverted) == 0)
        #expect(FanWriteSequencer.clamp(0, to: inverted) == 0)

        let unread = Fan(
            id: 0, name: "Left", mode: .auto,
            actualRPM: 0, targetRPM: 0, minRPM: 0, maxRPM: 0
        )
        #expect(FanWriteSequencer.clamp(4000, to: unread) == 0)

        // A non-finite request must not propagate into a write either.
        let healthy = testFans[0]
        #expect(FanWriteSequencer.clamp(.nan, to: healthy) == healthy.minRPM)
        #expect(FanWriteSequencer.clamp(.infinity, to: healthy) == healthy.minRPM)
    }

    /// The asymmetric case that used to slip through every guard: `Mx` reads
    /// fine, `Mn` throws and falls back to 0. `maxRPM > minRPM` is TRUE for
    /// (0, 6800), so the old admission checks admitted the fan and the clamp
    /// range became `0...6800` — no floor at all — letting a commanded 0 RPM
    /// reach the wire from both the manual slider and a curve at fraction 0.
    @Test("A fan whose Mn alone failed to read is skipped, never driven at 0 RPM")
    func halfReadRangeIsSkipped() async throws {
        let halfRead = Fan(
            id: 0, name: "Left", mode: .system,
            actualRPM: 3000, targetRPM: 3000, minRPM: 0, maxRPM: 6800
        )
        #expect(!halfRead.hasUsableRange, "a missing floor must disqualify the fan")

        // The write path must not touch it, even when explicitly asked for 0.
        let firmware = FakeFirmware(generation: .m2, fans: [halfRead])
        let sequencer = FanWriteSequencer(port: firmware, sleep: instantSleep)
        let outcome = try await sequencer.engageManual(targets: [0: 0], fans: [halfRead])
        #expect(outcome.clampedTargets.isEmpty, "no target may be produced for an unusable fan")
        let writes = await firmware.writes.filter { $0.key.hasSuffix("Tg") }
        #expect(writes.isEmpty, "a 0-RPM target must never be written for a half-read fan")

        // The curve path maps fraction 0 to the floor, which is exactly the
        // value that does not exist here — so this fan must not be curved either.
        #expect(FanGuardian.curveTargets(for: [halfRead], dieCelsius: 60).isEmpty)
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

    /// The mode-0 write used to be an un-suppressed `try` between two `try?`s,
    /// so the first fan that refused it abandoned the loop — later fans kept
    /// their forced mode and `Ftst` stayed latched, while `DaemonCore`'s
    /// `try? await revertAllAuto(...)` swallowed the throw and logged "all fans
    /// auto". A revert must reach every fan even when one of them fails.
    @Test("One fan refusing mode 0 does not abandon the revert of the others")
    func revertIsBestEffortAcrossFans() async throws {
        let firmware = FakeFirmware(generation: .m2, fans: testFans)
        let sequencer = FanWriteSequencer(port: firmware, sleep: instantSleep)
        _ = try await sequencer.engageManual(targets: [0: 4000, 1: 4000], fans: testFans)
        // Fan 0's mode key disappears — every write to it now throws.
        await firmware.removeKey("F0Md")

        await #expect(throws: IceCubeError.self) {
            try await sequencer.revertAllAuto(fans: testFans)
        }
        // Fan 1 must still have been reverted and handed back.
        #expect(try await firmware.readDouble("F1Md") == 3, "later fans still revert")
        #expect(try await firmware.readDouble("F1Tg") == 2317, "later fans still park at Mn")
    }

    @Test("A machine with no mode key at all refuses manual mode")
    func noModeKey() async throws {
        // A `FakeFirmware` seeded with no fans has no `F{i}Md`/`F{i}md` key at
        // all, which is what makes `resolveModeKeySuffix` throw. (Two lines of
        // setup building a *healthy* firmware used to sit here unused, which
        // made the test read as though it exercised a key-present case too.)
        let broken = FakeFirmware(generation: .m2, fans: [])
        let sequencer = FanWriteSequencer(port: broken, sleep: instantSleep)
        await #expect(throws: IceCubeError.self) {
            _ = try await sequencer.engageManual(targets: [0: 4000], fans: testFans)
        }
    }
}

@Suite("SafetyMonitor")
struct SafetyMonitorTests {
    private func temps(_ celsius: Double, key: String = "Tp01") -> [SensorReading] {
        [SensorReading(key: key, label: key, celsius: celsius)]
    }

    /// The watchdog takes an age, not two `Date`s, precisely so this cannot
    /// happen: with absolute wall-clock instants, a backwards NTP correction
    /// made `now.timeIntervalSince(lastHeartbeat)` negative, and a negative age
    /// is never greater than the timeout — silently deferring the revert the
    /// watchdog exists to guarantee, for as long as the clock stayed behind.
    /// A `Duration` measured on a monotonic clock cannot go backwards.
    @Test("Watchdog: a negative or zero age is treated as fresh, never as expired")
    func watchdogNonPositiveAge() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 4000])
        #expect(monitor.evaluate(
            heartbeatAge: .zero, config: manual, temperatures: temps(60)
        ) == .ok)
        // A caller can no longer hand us a negative age from a clock step, but
        // if one somehow arrives it must read as fresh, not as expired.
        #expect(monitor.evaluate(
            heartbeatAge: .seconds(-5), config: manual, temperatures: temps(60)
        ) == .ok)
    }

    @Test("Watchdog: a heartbeat that never arrived reverts immediately")
    func watchdogNeverHeard() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 4000])
        let verdict = monitor.evaluate(
            heartbeatAge: nil, config: manual, temperatures: temps(60)
        )
        guard case .revertToAuto = verdict else {
            Issue.record("no heartbeat ever received must revert; got \(verdict)")
            return
        }
    }

    @Test("Watchdog: the boundary is exclusive — exactly 15 s is still ok")
    func watchdogBoundary() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 4000])
        #expect(monitor.evaluate(
            heartbeatAge: .seconds(15), config: manual, temperatures: temps(60)
        ) == .ok)
        let verdict = monitor.evaluate(
            heartbeatAge: .milliseconds(15001), config: manual, temperatures: temps(60)
        )
        guard case .revertToAuto = verdict else {
            Issue.record("just past the timeout must revert; got \(verdict)")
            return
        }
    }

    @Test("Watchdog: manual mode reverts after 15 s without a heartbeat")
    func watchdogManual() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 4000])
        #expect(monitor.evaluate(
            heartbeatAge: .seconds(10),
            config: manual, temperatures: temps(60)
        ) == .ok)
        let verdict = monitor.evaluate(
            heartbeatAge: .seconds(16),
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
            heartbeatAge: .seconds(20),
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
            heartbeatAge: nil, config: persistent, temperatures: temps(60)
        ) == .ok)

        var monitor2 = SafetyMonitor()
        let ephemeral = FanConfig(mode: .curve, persistsWithoutApp: false)
        let verdict = monitor2.evaluate(
            heartbeatAge: .seconds(30),
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
        #expect(monitor.evaluate(heartbeatAge: .zero, config: manual, temperatures: temps(106)) == .ok)
        #expect(monitor.evaluate(heartbeatAge: .zero, config: manual, temperatures: temps(106)) == .ok)
        #expect(monitor.evaluate(heartbeatAge: .zero, config: manual, temperatures: temps(70)) == .ok)
        // Three consecutive hot ticks trigger.
        _ = monitor.evaluate(heartbeatAge: .zero, config: manual, temperatures: temps(106))
        _ = monitor.evaluate(heartbeatAge: .zero, config: manual, temperatures: temps(106))
        let verdict = monitor.evaluate(heartbeatAge: .zero, config: manual, temperatures: temps(106))
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
                heartbeatAge: .zero,
                config: manual,
                temperatures: temps(100, key: "Tp01")
            )
        }
        // 100 °C on a die sensor: below the 104 ceiling → never trips.
        #expect(monitor.evaluate(
            heartbeatAge: .zero,
            config: manual,
            temperatures: temps(100, key: "Tp01")
        ) == .ok)

        var monitor2 = SafetyMonitor()
        for _ in 0 ..< 2 {
            _ = monitor2.evaluate(
                heartbeatAge: .zero,
                config: manual,
                temperatures: temps(96, key: "TB1T")
            )
        }
        let verdict = monitor2.evaluate(
            heartbeatAge: .zero,
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
            _ = monitor.evaluate(heartbeatAge: .zero, config: manual, temperatures: temps(106))
        }
        // 101 °C: below the 104 ceiling but inside the release band → keep cooling.
        guard case .forceMaxCooling = monitor.evaluate(
            heartbeatAge: .zero, config: manual, temperatures: temps(101)
        ) else {
            Issue.record("must keep cooling inside the hysteresis band")
            return
        }
        // 98 °C: below ceiling − 5 → released.
        #expect(monitor.evaluate(heartbeatAge: .zero, config: manual, temperatures: temps(98)) == .ok)
    }

    @Test("Sensor failure: >3 consecutive failed reads in manual mode reverts; auto mode tolerates")
    func sensorFailures() {
        var monitor = SafetyMonitor()
        let manual = FanConfig(mode: .manual, manualTargets: [0: 4000])
        for _ in 0 ..< 3 {
            #expect(monitor.evaluate(heartbeatAge: .zero, config: manual, temperatures: nil) == .ok)
        }
        let verdict = monitor.evaluate(heartbeatAge: .zero, config: manual, temperatures: nil)
        guard case .revertToAuto = verdict else {
            Issue.record("4th failed read must revert; got \(verdict)")
            return
        }

        var monitor2 = SafetyMonitor()
        for _ in 0 ..< 10 {
            #expect(monitor2.evaluate(heartbeatAge: nil, config: .auto, temperatures: nil) == .ok)
        }
    }

    @Test("Auto mode: never reverts, never forces (nothing is held)")
    func autoModeInert() {
        var monitor = SafetyMonitor()
        for _ in 0 ..< 5 {
            #expect(monitor.evaluate(heartbeatAge: nil, config: .auto, temperatures: temps(108)) == .ok)
        }
    }
}
