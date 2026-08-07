// SensorReaderTests.swift — the daemon's eyes: what counts as a sensor, what counts as blindness, and the retries
// between.

import Foundation
@testable import IceCubeKit
import Testing

/// The daemon's only source of hardware truth, and until 2026-08-07 it had
/// **no tests at all** — 290 lines at 50 % coverage, sitting under every safety
/// rule in the app.
///
/// Nothing here needed a seam. `SensorReader` takes `any SMCControlPort` and an
/// injected `sleep`, and `DaemonCoreTests`' `FakeSMC` already conforms; the only
/// change required was dropping `private` from it. That it went untested this
/// long was not a design constraint, just a gap.
///
/// The distinction the whole type turns on: **`nil` readings mean blindness,
/// `[]` never happens.** `SafetyMonitor` counts blind ticks toward a revert, so
/// returning an empty array instead of `nil` would hold manual control forever
/// on a machine that can no longer see its own temperature.
@Suite("SensorReader — what the daemon can see, and when it admits it cannot")
struct SensorReaderTests {
    /// Instant, so retry budgets cost nothing. Matches `DaemonCoreTests`.
    static let noSleep: @Sendable (Duration) async -> Void = { _ in }

    static func reader(_ smc: FakeSMC) -> SensorReader {
        SensorReader(port: smc, sleep: noSleep)
    }

    // MARK: - Fans

    @Test("A fanless Mac reads zero fans rather than failing")
    func zeroFansIsNotAnError() async throws {
        let smc = FakeSMC(fanCount: 0)
        #expect(try await Self.reader(smc).readFans().isEmpty)
    }

    /// `Int(exactly:)` on a NaN returns nil, and the `?? 0` behind it means a
    /// garbled `FNum` reads as a fanless Mac rather than trapping. Trapping is
    /// what CLAUDE.md forbids outright in daemon code paths.
    @Test("A garbled fan count degrades to zero fans instead of trapping")
    func nonFiniteFanCountIsSurvivable() async throws {
        let smc = FakeSMC()
        await smc.setTemperature(.nan, key: "FNum")
        #expect(try await Self.reader(smc).readFans().isEmpty)
    }

    @Test("An implausible fan count is refused", arguments: [65.0, -1.0, 999.0])
    func implausibleFanCountThrows(count: Double) async throws {
        let smc = FakeSMC()
        await smc.setTemperature(count, key: "FNum")
        await #expect(throws: IceCubeError.self) { try await Self.reader(smc).readFans() }
    }

    /// Apple Silicon spells the mode key `F0Md` on most generations and `F0md`
    /// on at least one. The probe tries both, in that order.
    @Test("The mode key is found under either spelling")
    func modeKeyCasingIsProbed() async throws {
        let upper = FakeSMC()
        await upper.setTemperature(1, key: "F0Md")
        #expect(try await Self.reader(upper).readFans().first?.mode == .forced)

        let lower = FakeSMC()
        await lower.removeKey("F0Md")
        await lower.setTemperature(1, key: "F0md")
        #expect(try await Self.reader(lower).readFans().first?.mode == .forced)
    }

    @Test("A Mac with neither mode-key spelling reports the firmware's own mode")
    func missingModeKeyIsSystem() async throws {
        let smc = FakeSMC()
        await smc.removeKey("F0Md")
        await smc.removeKey("F0md")
        #expect(try await Self.reader(smc).readFans().first?.mode == .system)
    }

    /// The distinction that matters, and the reason `readOptional` exists at
    /// all: a mode key that is **absent** means this Mac spells it differently,
    /// while one that is **present but unreadable** means the read failed. The
    /// first is a fact; the second used to be swallowed as `mode 0`, which is
    /// exactly what "macOS took the fans off us" looks like — and two of those
    /// in a row reverts a healthy curve.
    @Test("A mode key that exists but will not read is an error, not a mode")
    func unreadableModeKeyThrows() async throws {
        let smc = FakeSMC()
        await smc.breakRead("F0Md")
        await #expect(throws: IceCubeError.self) { try await Self.reader(smc).readFans() }
    }

    @Test("A fan's range and speeds come through intact")
    func fanFieldsAreRead() async throws {
        let smc = FakeSMC(fanCount: 2, minRPM: 2317, maxRPM: 6800)
        let fans = try await Self.reader(smc).readFans()
        #expect(fans.count == 2)
        #expect(fans[0].minRPM == 2317)
        #expect(fans[0].maxRPM == 6800)
        #expect(fans[0].hasUsableRange)
    }

    // MARK: - Temperature discovery

    @Test("A healthy Mac resolves its sensors and says how many")
    func discoveryResolvesAndReports() async throws {
        let read = await Self.reader(FakeSMC()).readTemperatures()
        let readings = try #require(read.readings)
        #expect(!readings.isEmpty)
        #expect(read.notices.contains { $0.contains("resolved") }, "the daemon logs what it settled on")
    }

    /// The guard at the centre of the M3 bug fixed in #79.
    ///
    /// Without a die-class sensor the daemon cannot run the temperature ceiling
    /// or the curve, so admitting an airflow-only set would be worse than
    /// admitting none: it would look like it was working. It refuses, says so,
    /// and leaves the set unresolved so the next tick probes again.
    @Test("A sensor set with no die key is refused, and re-probed next tick")
    func airflowOnlyIsNotAcceptable() async {
        let smc = FakeSMC()
        await smc.removeKey("Tp01")
        await smc.removeKey("Tg0f")
        // Seeding an airflow key is what makes this the *airflow-only* case
        // rather than the empty case. Without it `present` is empty, the
        // `!present.isEmpty` guard fires first, and the die requirement is never
        // reached — mutation testing caught exactly that: deleting the die guard
        // left this test green.
        await smc.setTemperature(40, key: "TaLP")

        let first = await Self.reader(smc).readTemperatures()
        #expect(first.readings == nil, "no die sensor means blind, not 'a few sensors'")
        #expect(
            first.notices.contains { $0.contains("SAFETY:") && $0.contains("die: false") },
            "and it must say why"
        )
    }

    /// The other half: an unresolved set is not a permanent verdict. A cluster
    /// that was power-gated at probe time must be picked up once it reports.
    @Test("A Mac that resolves nothing this tick can resolve next tick")
    func unresolvedIsNotFinal() async {
        let smc = FakeSMC()
        await smc.removeKey("Tp01")
        await smc.removeKey("Tg0f")
        await smc.setTemperature(40, key: "TaLP") // airflow-only, as above
        let reader = Self.reader(smc)

        #expect(await reader.readTemperatures().readings == nil)

        await smc.setTemperature(55, key: "Tp01")
        let second = await reader.readTemperatures()
        #expect(second.readings?.isEmpty == false, "the die sensor is back, so the daemon can see again")
    }

    @Test("An empty probe is refused rather than cached as an answer")
    func emptyProbeIsRefused() async {
        let smc = FakeSMC()
        for key in ["Tp01", "Tg0f", "TaLP"] {
            await smc.removeKey(key)
        }
        let read = await Self.reader(smc).readTemperatures()
        #expect(read.readings == nil)
    }

    // MARK: - Reading

    /// A die sensor reading above silicon limits is clamped and **kept**, not
    /// dropped. Dropping it would take the hottest point in the machine out of
    /// the ceiling calculation at exactly the moment it matters.
    @Test("An impossible reading is clamped to the ceiling, not discarded")
    func hotReadingIsClampedNotDropped() async throws {
        let smc = FakeSMC()
        await smc.setTemperature(130, key: "Tp01")
        let readings = try #require(await Self.reader(smc).readTemperatures().readings)
        let die = try #require(readings.first { $0.key == "Tp01" })
        #expect(die.celsius == 120, "clamped to the plausibility ceiling")
    }

    /// The mirror, and the asymmetry is deliberate: a reading at or below 10 °C
    /// is a dead or unpopulated sensor, so it is dropped — and **not counted as
    /// missing**, because a sensor that is reliably silent must not keep
    /// triggering the re-probe.
    @Test("A dead-cold reading is dropped without counting as a failure")
    func coldReadingIsDroppedQuietly() async throws {
        let smc = FakeSMC()
        await smc.setTemperature(0, key: "Tg0f")
        let read = await Self.reader(smc).readTemperatures()
        let readings = try #require(read.readings)
        #expect(!readings.contains { $0.key == "Tg0f" }, "0 °C is not a temperature")
        #expect(
            !read.notices.contains { $0.contains("unreadable") },
            "and it must not be reported as a failed read, or the set re-probes forever"
        )
    }

    /// The contract `SafetyMonitor` depends on. Every sensor unreadable is
    /// blindness — `nil` — and never `[]`, because an empty array reads as "this
    /// Mac has no sensors" and would hold manual control on a machine that can
    /// no longer see itself.
    @Test("Losing every sensor is blindness, not an empty list")
    func totalFailureIsNilNotEmpty() async {
        let smc = FakeSMC()
        let reader = Self.reader(smc)
        _ = await reader.readTemperatures() // resolve the set first

        for key in ["Tp01", "Tg0f", "TaLP"] {
            await smc.breakRead(key)
        }
        let read = await reader.readTemperatures()
        #expect(read.readings == nil, "nil is what SafetyMonitor counts; [] would be silence")
    }

    /// A transient miss on one sensor must not cost the tick. The daemon keeps
    /// the readings it got.
    @Test("One unreadable sensor does not blind the daemon")
    func partialFailureStillReports() async throws {
        let smc = FakeSMC()
        let reader = Self.reader(smc)
        _ = await reader.readTemperatures()

        await smc.breakRead("Tg0f")
        let readings = try #require(await reader.readTemperatures().readings)
        #expect(readings.contains { $0.key == "Tp01" }, "the sensors that answered still count")
    }

    // MARK: - Retries

    /// A transport failure is not an answer about membership, so the probe
    /// retries before concluding a key is absent — and the injected sleep is
    /// what makes that free to test. A key that misses once and then answers
    /// must be admitted.
    @Test("A key that misses once is still admitted")
    func transientMissDoesNotExcludeAKey() async throws {
        let smc = FakeSMC()
        await smc.scriptReads("Tp01", [nil, 55])
        let readings = try #require(await Self.reader(smc).readTemperatures().readings)
        #expect(readings.contains { $0.key == "Tp01" }, "one bad read must not disown a real sensor")
    }

    /// And the counterweight: a key that never answers is not admitted, and the
    /// retry budget is finite so a dead machine cannot hang the tick.
    @Test("A key that never answers is not admitted, and the probe terminates")
    func permanentFailureTerminates() async {
        let smc = FakeSMC()
        await smc.breakRead("Tp01")
        await smc.breakRead("Tg0f")
        let read = await Self.reader(smc).readTemperatures()
        #expect(read.readings == nil)
    }
}
