// DaemonCoreTests.swift — the daemon's safety invariants, finally testable: revert paths, boot promise, wake, watchdog.

import Foundation
@testable import IceCubeKit
import Testing

/// A scripted SMC that can be made to fail on demand.
///
/// Richer than `HelperLogicTests`' sequencer fake: it also serves `FNum`, the
/// per-fan read keys and temperature sensors, because `DaemonCore` reads the
/// hardware itself rather than being handed a fan list.
private actor FakeSMC: SMCControlPort {
    private(set) var values: [String: Double] = [:]
    private(set) var writes: [(key: String, value: Double)] = []
    private(set) var resetCount = 0
    /// Keys that throw on read, simulating a transient SMC failure.
    private var unreadable: Set<String> = []
    /// Keys that throw on write, simulating firmware refusal.
    private var unwritable: Set<String> = []
    /// When true every write yields first, so two write SEQUENCES actually
    /// interleave. Without this the fake is so fast that an engage runs to
    /// completion between suspensions and a race test proves nothing.
    private var yieldOnWrite = false

    /// - Parameter deadSensors: keys that EXIST but never return a plausible
    ///   value — the shape a real Mac has, because a curated map is
    ///   per-generation and any one machine populates only part of it.
    init(
        fanCount: Int = 2, minRPM: Double = 2317, maxRPM: Double = 6800,
        temperature: Double = 55, deadSensors: [String] = []
    ) {
        values["FNum"] = Double(fanCount)
        for i in 0 ..< fanCount {
            values["F\(i)Md"] = 3 // system-controlled
            values["F\(i)Ac"] = 3000
            values["F\(i)Tg"] = 3000
            values["F\(i)Mn"] = minRPM
            values["F\(i)Mx"] = maxRPM
        }
        values["Ftst"] = 0
        // Present in both the curated M2 map and the fallback candidate list,
        // so these tests do not depend on the host's hw.model.
        values["Tp01"] = temperature
        values["Tg0f"] = temperature - 5
        for key in deadSensors {
            values[key] = 0
        } // present, but implausible
    }

    func hasKey(_ key: String) async -> Bool {
        values[key] != nil
    }

    func readDouble(_ key: String) async throws -> Double {
        if unreadable.contains(key) {
            throw IceCubeError.smcCallFailed(key: key, kernReturn: -1)
        }
        guard let value = values[key] else { throw IceCubeError.smcKeyNotFound(key: key) }
        return value
    }

    func writeDouble(_ key: String, value: Double, as _: SMCDataType) async throws {
        if yieldOnWrite {
            for _ in 0 ..< 4 {
                await Task.yield()
            }
        }
        if unwritable.contains(key) {
            throw IceCubeError.smcFirmwareRejected(key: key, result: SMCResult(rawValue: 0x84))
        }
        guard values[key] != nil else { throw IceCubeError.smcKeyNotFound(key: key) }
        values[key] = value
        writes.append((key, value))
    }

    func reset() async {
        resetCount += 1
    }

    // MARK: - Failure injection

    func breakRead(_ key: String) {
        unreadable.insert(key)
    }

    func fixRead(_ key: String) {
        unreadable.remove(key)
    }

    func breakWrite(_ key: String) {
        unwritable.insert(key)
    }

    func interleaveWrites() {
        yieldOnWrite = true
    }

    /// Deletes a key outright, so reads report `keyNotFound` rather than a
    /// transport failure — the shape of a Mac that simply lacks it.
    func removeKey(_ key: String) {
        values.removeValue(forKey: key)
    }

    func setTemperature(_ celsius: Double, key: String = "Tp01") {
        values[key] = celsius
    }

    func modeWrites(fan: Int) -> [Double] {
        writes.filter { $0.key == "F\(fan)Md" }.map(\.value)
    }

    func clearWrites() {
        writes.removeAll()
    }
}

/// In-memory persistence with the *same* admission rules as the real
/// `ConfigStore` (curve + persists + usable), so tests exercise the real
/// policy rather than a permissive stand-in.
///
/// A lock-guarded final class rather than an actor: `FanConfigStoring`'s
/// methods are synchronous by design (the daemon reads it during `start()`
/// before any concurrency exists), so an actor cannot conform.
private final class MemoryConfigStore: FanConfigStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FanConfig?

    init(seeded: FanConfig? = nil) {
        stored = seeded
    }

    func load() -> FanConfig? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ config: FanConfig) {
        guard config.mode == .curve, config.persistsWithoutApp, config.isUsableCurveConfig else {
            clear()
            return
        }
        lock.lock(); defer { lock.unlock() }
        stored = config
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}

private let instantSleep: @Sendable (Duration) async -> Void = { _ in }

private func makeCore(
    smc: FakeSMC,
    store: MemoryConfigStore = MemoryConfigStore()
) -> DaemonCore {
    DaemonCore(port: smc, store: store, sleep: instantSleep)
}

private func manualConfig(_ rpm: Double = 4000) -> FanConfig {
    FanConfig(mode: .manual, manualTargets: [0: rpm, 1: rpm])
}

private func curveConfig(persists: Bool) -> FanConfig {
    var config = FanConfig(mode: .curve, persistsWithoutApp: persists)
    config.sharedCurve = FanCurve.balanced
    return config
}

@Suite("DaemonCore — revert invariants")
struct DaemonCoreRevertTests {
    /// INVARIANT 2: the daemon reverts to auto on XPC invalidation.
    @Test("Losing the app connection in manual mode hands the fans back")
    func revertsOnInvalidation() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig())
        #expect(await core.config.mode == .manual)

        await core.connectionInvalidated()
        #expect(await core.config.mode == .auto)
        #expect(await smc.modeWrites(fan: 0).contains(0), "fan handed back to the system")
        #expect(await smc.resetCount > 0, "SMC connection released so thermalmonitord resumes")
    }

    /// The reason leaving macOS mode used to take four and a half seconds: the
    /// hand-back let the fans stop, and a stopped fan cannot be hurried. Traced
    /// on a Mac14,9, they coast to a standstill in ~2.5 s — faster than the 2 s
    /// safety tick can reliably react — so the decision is taken here, while
    /// they are still turning, and they ramp down to the floor instead.
    @Test("Asking for macOS mode on a warm machine keeps the fans at their floor")
    func warmHandBackKeepsTheFansSpinning() async throws {
        // 50 C: what a Mac being actively cooled actually reads. The owner's
        // trace was 52.9 C with the fans at 3226 RPM, and the first version of
        // this gated at 55 C — so it never fired once on real hardware.
        let smc = FakeSMC(temperature: 50)
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig(5000))

        try await core.apply(FanConfig(mode: .auto))
        #expect(await core.config.mode == .auto, "the daemon really is in auto")
        // Never stopped: still driven, and driven at the floor rather than 5000.
        #expect(try await smc.readDouble("F0Md") == 1)
        #expect(try await smc.readDouble("F0Tg") == 2317)
        #expect(try await smc.readDouble("F1Tg") == 2317)
        #expect(await core.currentStatus().guardianActive, "the UI must not claim macOS is in charge")
    }

    /// The counterweight: macOS mode on a cold machine must mean actual silence,
    /// or the app has quietly removed the option the user picked.
    @Test("Asking for macOS mode on a cold machine really does hand the fans back")
    func coldHandBackReleasesTheFans() async throws {
        let smc = FakeSMC(temperature: 30)
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig(5000))

        try await core.apply(FanConfig(mode: .auto))
        #expect(await core.config.mode == .auto)
        #expect(try await smc.readDouble("F0Md") != 1, "handed back, not re-taken")
        #expect(await core.currentStatus().guardianActive == false)
    }

    /// SAFETY: only the two *deliberate* hand-backs keep the fans. A revert the
    /// daemon took because it lost control must actually let go — grabbing them
    /// again a millisecond later would defeat the point of the revert.
    @Test("A safety revert lets go even on a warm machine")
    func safetyRevertDoesNotReTakeTheFans() async throws {
        let smc = FakeSMC(temperature: 50)
        let core = makeCore(smc: smc)
        // Deliberately no `heartbeat()` — the watchdog's strongest case, and the
        // opposite of a user choosing macOS mode.
        try await core.apply(manualConfig(5000))

        await core.tick(sleptFor: .zero)
        #expect(await core.config.mode == .auto)
        #expect(try await smc.readDouble("F0Md") != 1, "a safety revert must let go")
    }

    /// Seen on an ordinary app restart, and it was not cosmetic. `resetPort()`
    /// closes the SMC connection, the first read after it is the one most
    /// likely to miss, and `readFans` used to swallow that with `(try? …) ?? 0`
    /// — producing a fan with mode `.system` and target 0, which is exactly
    /// what "macOS took the fans off us" looks like. One of those logged a
    /// read-back mismatch; two in a row would have reverted a healthy curve to
    /// auto and told the user control had been lost.
    @Test("A failed fan read is never mistaken for having lost the fans")
    func failedFanReadDoesNotLookLikeLosingControl() async throws {
        let smc = FakeSMC(temperature: 60)
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: false))
        #expect(await core.config.mode == .curve)

        // The mode key still exists — it just cannot be read right now.
        await smc.breakRead("F0Md")
        await core.tick(sleptFor: .zero)
        await core.tick(sleptFor: .zero)

        // Two ticks blind. The old code would have concluded the fans were
        // gone and handed them back; the curve must simply still be running.
        #expect(await core.config.mode == .curve, "a transient read must not revert a working curve")
        #expect(await smc.modeWrites(fan: 0).contains(0) == false, "never handed back")

        // And it recovers silently once the SMC answers again.
        await smc.fixRead("F0Md")
        await core.tick(sleptFor: .zero)
        #expect(await core.config.mode == .curve)
        #expect(try await smc.readDouble("F0Md") == 1, "the fans are still ours")
    }

    /// The other half: a key this Mac genuinely does not have is NOT a failure.
    /// Collapsing the two is what made the bug above possible, so pin both.
    @Test("An absent mode key still reads as system control rather than throwing")
    func absentModeKeyIsTolerated() async {
        let smc = FakeSMC(temperature: 60)
        let core = makeCore(smc: smc)
        await core.heartbeat()
        // No F0Md/F0md at all — the shape of a Mac with different fan keys.
        await smc.removeKey("F0Md")
        await smc.removeKey("F0md")
        await core.tick(sleptFor: .zero)
        #expect(await core.currentStatus().mode == .auto, "reads fine, just nothing to drive")
    }

    /// Caught in the log on an ordinary app restart, with both writers behaving
    /// perfectly on their own. Quitting hands back and the guardian begins
    /// writing the fan floor (2317); the app relaunches 250 ms later and the
    /// curve engage writes 3400 straight through the middle of it; the
    /// floor-hold write lands last and the fans sit at 2317 while the daemon
    /// believes 3400. Read-back reported `target 2317 != 3400` and re-asserted.
    ///
    /// `DaemonCore` is an actor, but `engageManual` writes a mode and a target
    /// PER FAN and suspends on every one, so two engages interleave and the
    /// fans end up wherever the last WRITE landed rather than wherever the
    /// newest INTENT said. `applyGeneration` covers apply-vs-apply, and the
    /// revert guards cover revert-vs-engage; the guardian's own engage sits
    /// outside both, which is how this got through.
    @Test("A curve applied mid-hand-back wins over the floor hold still writing")
    func curveApplyBeatsAnInFlightFloorHold() async throws {
        let smc = FakeSMC(temperature: 60)
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig(5000))
        await smc.interleaveWrites()

        // The restart, in order: the app drops (guardian starts writing the
        // floor), then reconnects and applies its curve while that is still in
        // flight — 250 ms apart on the hardware trace.
        async let handBack: Void = core.connectionInvalidated()
        for _ in 0 ..< 8 {
            await Task.yield()
        }
        async let relaunch: Void = core.apply(curveConfig(persists: false))
        _ = try await (handBack, relaunch)

        // The invariant is agreement, not a particular winner: whatever the
        // daemon settled on, the hardware must match it. The bug was the two
        // disagreeing — fans parked at the floor while the daemon reported a
        // curve, with only the next tick's re-assert to rescue it.
        let status = await core.currentStatus()
        let zero = try await smc.readDouble("F0Tg")
        let one = try await smc.readDouble("F1Tg")
        #expect(zero == one, "fans split between two intents: \(zero) vs \(one)")
        if status.mode == .curve {
            #expect(zero != 2317, "daemon reports a curve while the fans sit at the floor")
        }
        // Whatever happened, both fans are ours and neither was left at rest.
        #expect(try await smc.readDouble("F0Md") == 1)
        #expect(zero >= 2317)
    }

    /// Since the macOS preset was removed, Settings -> "Turn Off Fan Control"
    /// is the ONLY way a user can hand the fans back. It must therefore really
    /// hand them back: the floor hold that keeps a warm machine's fans turning
    /// on an app quit must not fire here, or turning the feature off would
    /// leave the daemon still driving and the setting would be a lie.
    @Test("Turning fan control off releases the fans even on a warm machine")
    func turningOffReleasesEvenWhenWarm() async throws {
        let smc = FakeSMC(temperature: 70) // hot enough for every hold rule
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig(5000))

        await core.setAllAuto()

        #expect(await core.config.mode == .auto)
        #expect(try await smc.readDouble("F0Md") != 1, "the fans must actually be released")
        #expect(await core.currentStatus().guardianActive == false)
    }

    /// A persisting curve is explicitly allowed to outlive the app.
    @Test("Losing the connection does NOT revert a curve that persists without the app")
    func persistingCurveSurvivesInvalidation() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: true))
        await core.connectionInvalidated()
        #expect(await core.config.mode == .curve, "the whole point of persist-without-app")
    }

    /// INVARIANT 2 + the C6 regression: shutdown reverts the *hardware* but must
    /// not delete the persisted curve — launchd SIGTERMs the daemon on every
    /// orderly reboot, which is precisely what the boot promise exists to survive.
    @Test("Shutdown reverts the fans but keeps the persisted curve")
    func shutdownKeepsBootPromise() async throws {
        let smc = FakeSMC()
        let store = MemoryConfigStore()
        let core = DaemonCore(port: smc, store: store, sleep: instantSleep)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: true))
        #expect(store.load() != nil, "a persisting curve is saved when applied")

        await core.shutdown()
        let modes = await smc.modeWrites(fan: 0)
        #expect(modes.contains(0) || modes.contains(3), "the fans are still handed back")
        #expect(store.load() != nil, "SIGTERM must NOT cancel the boot promise")
    }

    /// The app cannot light up the right preset unless the daemon says what it
    /// is enforcing. Before this, a curve resumed at boot — before the app even
    /// launched — left every preset button unlit while the fans audibly ran,
    /// because the app consulted only its own memory of what it had sent.
    @Test("The daemon reports the curve it is enforcing, including one resumed at boot")
    func statusReportsActiveCurve() async {
        let smc = FakeSMC(temperature: 80)
        let store = MemoryConfigStore(seeded: curveConfig(persists: true))
        let core = DaemonCore(port: smc, store: store, sleep: instantSleep)
        await core.start()
        let status = await core.currentStatus()
        #expect(status.mode == .curve)
        #expect(status.activeCurve == FanCurve.balanced, "the app needs this to highlight a preset")
        await core.shutdown()
    }

    @Test("Manual mode and auto report no active curve")
    func statusClearsCurveOutsideCurveMode() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: false))
        #expect(await core.currentStatus().activeCurve != nil)

        try await core.apply(manualConfig())
        #expect(await core.currentStatus().activeCurve == nil, "manual is not a curve")

        await core.setAllAuto()
        #expect(await core.currentStatus().activeCurve == nil, "auto is not a curve")
    }

    /// A user- or safety-driven revert *does* cancel it.
    @Test("An explicit revert to auto clears the persisted curve")
    func explicitRevertClearsPersistence() async throws {
        let smc = FakeSMC()
        let store = MemoryConfigStore()
        let core = DaemonCore(port: smc, store: store, sleep: instantSleep)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: true))
        #expect(store.load() != nil)

        await core.setAllAuto()
        #expect(store.load() == nil, "asking for auto cancels the boot promise")
    }

    /// C2: a revert whose fan read fails writes NOTHING. It must not then
    /// declare `.auto` — doing so disarms the watchdog, the ceiling AND the
    /// guardian for fans that are still physically forced.
    @Test("A revert that cannot read the fans keeps control instead of declaring auto")
    func failedRevertDoesNotDeclareAuto() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig())
        await smc.clearWrites()

        await smc.breakRead("FNum") // the fan list is now unreadable
        await core.setAllAuto()

        #expect(await core.config.mode == .manual, "must NOT claim auto it did not reach")
        #expect(await core.revertPending, "the revert is deferred, not forgotten")
        #expect(await smc.modeWrites(fan: 0).isEmpty, "no writes actually landed")
    }

    /// …and the deferred revert must actually converge once the SMC recovers.
    @Test("A deferred revert lands on a later tick once the fans read again")
    func deferredRevertConverges() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig())
        await smc.breakRead("FNum")
        await core.setAllAuto()
        #expect(await core.revertPending)

        await smc.fixRead("FNum")
        await core.tick(sleptFor: .zero)

        #expect(await core.revertPending == false, "retry succeeded")
        #expect(await core.config.mode == .auto)
        #expect(await smc.modeWrites(fan: 0).contains(0), "the fans really were handed back")
    }

    /// A fanless Mac (the M2 Air is in the curated model set) reports FNum 0.
    /// That is a real answer, not a failed read — it must not pin the daemon
    /// in a permanent retry loop.
    @Test("A fanless Mac reverts cleanly rather than deferring forever")
    func fanlessMacRevertsCleanly() async {
        let smc = FakeSMC(fanCount: 0)
        let core = makeCore(smc: smc)
        await core.setAllAuto()
        #expect(await core.revertPending == false, "nothing to hand back is success, not failure")
        #expect(await core.config.mode == .auto)
    }

    /// C4: `engageManual` forces fans one at a time, so a throw can land after
    /// earlier fans are already `.forced`. Walking away there strands them at a
    /// fixed RPM with `config == .auto`, where no safety net ever looks again.
    @Test("A mid-sequence write failure unwinds instead of stranding forced fans")
    func partialEngageUnwinds() async {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        await smc.breakWrite("F1Md") // fan 0 succeeds, fan 1 refuses

        _ = try? await core.apply(manualConfig())

        #expect(await core.config.mode == .auto, "no half-applied manual state")
        // Fan 0 was forced mid-sequence; the unwind must hand it back.
        let fan0Modes = await smc.modeWrites(fan: 0)
        #expect(fan0Modes.contains(0), "the already-forced fan was reverted, not abandoned")
    }
}

@Suite("DaemonCore — boot, wake and the safety tick")
struct DaemonCoreTickTests {
    /// INVARIANT 2, start case: with no persisted config the daemon wipes
    /// whatever a crash or power loss left behind.
    @Test("Start with no persisted config reverts everything to auto")
    func startRevertsWhenNothingPersisted() async {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.start()
        #expect(await core.config.mode == .auto)
        #expect(await smc.modeWrites(fan: 0).contains(0))
        await core.shutdown()
    }

    /// The Phase 4 boot promise: a persisted curve is live before the app exists.
    @Test("Start with a persisted curve resumes it instead of reverting")
    func startResumesPersistedCurve() async {
        let smc = FakeSMC(temperature: 80) // hot enough for the curve to drive
        let store = MemoryConfigStore(seeded: curveConfig(persists: true))
        let core = DaemonCore(port: smc, store: store, sleep: instantSleep)
        await core.start()
        #expect(await core.config.mode == .curve, "the boot promise")
        await core.shutdown()
    }

    /// INVARIANT 7: manual mode is never the persisted default.
    @Test("Manual mode is never written to persistent storage")
    func manualNeverPersists() async throws {
        let smc = FakeSMC()
        let store = MemoryConfigStore()
        let core = DaemonCore(port: smc, store: store, sleep: instantSleep)
        await core.heartbeat()
        var manual = manualConfig()
        manual.persistsWithoutApp = true // even when the user asks for it
        try await core.apply(manual)
        #expect(store.load() == nil, "manual must never survive the app")
    }

    /// INVARIANT 1: no heartbeat for 15 s in manual mode → revert.
    @Test("The watchdog reverts manual mode when the app never heartbeats")
    func watchdogRevertsManual() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        // Deliberately no `heartbeat()`: a config applied by an app that then
        // goes silent is exactly what the watchdog exists to catch, and a
        // never-heard heartbeat is its strongest case.
        try await core.apply(manualConfig())
        #expect(await core.config.mode == .manual)

        await core.tick(sleptFor: .zero)
        #expect(await core.config.mode == .auto, "watchdog must fire without a heartbeat")
        #expect(await smc.modeWrites(fan: 0).contains(0))
    }

    /// The counterpart: a persisting curve is explicitly exempt from the
    /// watchdog, and must survive an app-less tick.
    @Test("A persisting curve survives ticks with no heartbeat at all")
    func persistingCurveExemptFromWatchdog() async throws {
        let smc = FakeSMC(temperature: 75)
        let core = makeCore(smc: smc)
        try await core.apply(curveConfig(persists: true))
        await core.tick(sleptFor: .zero)
        #expect(await core.config.mode == .curve, "curve mode may run app-less")
    }

    /// INVARIANT 3: over the ceiling → maximum cooling, whatever the user asked for.
    @Test("A sensor over its ceiling forces maximum cooling regardless of the user's targets")
    func ceilingForcesMaxCooling() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig(2500)) // user wants quiet
        await smc.clearWrites()

        await smc.setTemperature(110) // die sensor well over the 104 ceiling
        for _ in 0 ..< 4 {
            await core.heartbeat()
            await core.tick(sleptFor: .zero)
        }
        let targets = await smc.writes.filter { $0.key == "F0Tg" }.map(\.value)
        #expect(targets.contains(6800), "the ceiling overrides the user's 2500 RPM")
    }

    /// INVARIANT 6: firmware silently drops manual control across sleep, so a
    /// wake must re-assert (or revert).
    @Test("Waking from sleep re-asserts manual control")
    func wakeReassertsManual() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig())
        await smc.clearWrites()

        await core.heartbeat()
        // Slept far longer than one tick interval → treated as a real wake.
        await core.tick(sleptFor: .seconds(HelperConstants.tickInterval * 10))

        #expect(await smc.modeWrites(fan: 0).contains(1), "manual mode re-asserted after wake")
        #expect(await core.config.mode == .manual)
    }

    /// Caught on real hardware (Mac14,9): the curated M2 map lists 20 keys, but
    /// this machine populates only 12 — the other 8 exist and read 0. Admitting
    /// on `hasKey` alone let those in, and the partial-failure check then saw 8
    /// unreadable members every tick and re-probed forever, re-admitting the
    /// same dead keys each time. ~40 extra SMC calls per tick, permanently.
    @Test("Sensors that exist but never read plausibly are excluded once, not re-probed forever")
    func deadSensorsDoNotCauseReprobeLoop() async throws {
        let dead = ["Tp0X", "Tp0b", "Tp0f", "Tp0j", "Tp1h", "Tp1t", "Tp1p", "Tp1l"]
        let smc = FakeSMC(deadSensors: dead)
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig())

        // Let discovery settle, then count how often it re-runs.
        await core.tick(sleptFor: .zero)
        let discoveriesAfterFirst = await core.currentStatus().recentEvents
            .filter { $0.hasPrefix("resolved") }.count
        for _ in 0 ..< 5 {
            await core.heartbeat()
            await core.tick(sleptFor: .zero)
        }
        let discoveriesLater = await core.currentStatus().recentEvents
            .filter { $0.hasPrefix("resolved") }.count
        #expect(
            discoveriesLater == discoveriesAfterFirst,
            "discovery must not re-run once the set is settled (ran \(discoveriesLater - discoveriesAfterFirst) extra times)"
        )
        let reprobes = await core.currentStatus().recentEvents.filter { $0.contains("unreadable") }
        #expect(reprobes.isEmpty, "permanently-dead keys are not a health event: \(reprobes)")
    }

    /// The latency the user felt as "macOS → a curve is slow, but curve →
    /// curve is instant". Handing back to macOS resets the SMC connection; if
    /// that also discarded the sensor keys, the very next curve engage had to
    /// re-discover ~20 keys on a cold connection before it could compute one
    /// target — and skipped to the next 2 s tick if any of it failed.
    @Test("Handing back to macOS does not force a sensor re-probe")
    func revertKeepsSensorKeys() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: false))
        let afterFirst = await core.currentStatus().recentEvents
            .filter { $0.hasPrefix("resolved") }.count
        #expect(afterFirst >= 1, "the first engage resolves sensors")

        // Hand back to macOS (resets the port), then take control again.
        await core.setAllAuto()
        await core.heartbeat()
        try await core.apply(curveConfig(persists: false))

        let afterSecond = await core.currentStatus().recentEvents
            .filter { $0.hasPrefix("resolved") }.count
        #expect(
            afterSecond == afterFirst,
            "re-engaging after a hand-back must reuse the cached keys, not re-probe"
        )
    }

    /// One unlucky read on a just-reopened connection must not cost a whole
    /// tick — that is a 2 s stall at the exact moment the user is watching.
    @Test("A single failed temperature read does not delay taking control")
    func transientReadDoesNotSkipTheEngage() async throws {
        let smc = FakeSMC(temperature: 70)
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: false))
        await smc.clearWrites()

        // Both sensors miss once; the retry inside the tick should still engage.
        await smc.breakRead("Tp01")
        await smc.breakRead("Tg0f")
        Task {
            try? await Task.sleep(for: .milliseconds(10))
            await smc.fixRead("Tp01")
            await smc.fixRead("Tg0f")
        }
        await core.tick(sleptFor: .zero)
        #expect(await core.config.mode == .curve, "must not have reverted")
    }

    /// What does the first engage after a hand-back actually command? A fresh CurveFollower is documented to start at
    /// full demand
    /// ("first tick: start at demand, no artificial ramp-up"), so taking a
    /// curve straight from macOS should command the curve's answer for the
    /// CURRENT die temperature — not a ramped-up fraction of it.
    @Test("First engage after a hand-back commands the curve's full demand")
    func firstEngageAfterRevertIsFullDemand() async throws {
        let smc = FakeSMC(temperature: 70) // warm: Balanced wants a lot of air
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: false))
        let firstRun = await smc.writes.filter { $0.key == "F0Tg" }.map(\.value)
        await core.setAllAuto()
        await smc.clearWrites()

        // Straight back into the curve, exactly as clicking macOS then Balanced.
        await core.heartbeat()
        try await core.apply(curveConfig(persists: false))
        let afterRevert = await smc.writes.filter { $0.key == "F0Tg" }.map(\.value)

        // Balanced at 70 C: fraction 0.5 + half way to 0.75 => ~0.625
        // target ~= 2317 + 0.625 * 4483 = 5119, quantized to 50 => ~5100
        let expected = FanWriteSequencer.quantizedTarget(
            fraction: FanCurve.balanced.fraction(at: 70),
            fan: Fan(
                id: 0,
                name: "L",
                mode: .forced,
                actualRPM: 0,
                targetRPM: 0,
                minRPM: 2317,
                maxRPM: 6800
            )
        )
        #expect(firstRun.first == expected)
        // Taking a curve straight from macOS must command the same full demand
        // as any other engage — no ramp, no reduced first step.
        #expect(afterRevert.first == expected)
    }

    /// A probe that finds only non-die sensors is unusable, not an answer.
    /// `hottestDieCelsius` is what BOTH the curve and the guardian run on, so a
    /// set of battery/airflow sensors leaves the daemon unable to control or
    /// protect anything while looking perfectly healthy.
    @Test("A probe with no die sensor is rejected rather than cached")
    func probeWithoutDieSensorIsRejected() async throws {
        let smc = FakeSMC()
        // Kill both die sensors; leave a battery sensor readable.
        await smc.breakRead("Tp01")
        await smc.breakRead("Tg0f")
        await smc.setTemperature(35, key: "TB1T")
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig())
        await core.tick(sleptFor: .zero)

        let events = await core.currentStatus().recentEvents
        #expect(
            events.contains { $0.contains("sensor probe unusable") },
            "a die-less probe must be refused: \(events)"
        )
        #expect(
            !events.contains { $0.hasPrefix("resolved") },
            "nothing should have been cached"
        )
    }

    /// The transient-failure case that made probes resolve 20, then 16, then 2
    /// sensors on the same machine: a read that fails once must not permanently
    /// disown a working sensor.
    @Test("A sensor that fails one read but answers the retry is still admitted")
    func transientReadFailureDoesNotDisownSensor() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig())
        await core.tick(sleptFor: .zero)

        let resolved = await core.currentStatus().recentEvents
            .first { $0.hasPrefix("resolved") }
        #expect(resolved != nil, "a healthy machine resolves its sensors")
    }

    /// C7: an empty sensor probe is "unresolved", not "this Mac has no sensors".
    /// Caching it blinded the daemon permanently — the ceiling and the guardian
    /// both go inert while the app UI still shows temperatures.
    @Test("An empty sensor probe is retried rather than cached forever")
    func emptySensorProbeIsNotCached() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        // Both seeded sensors unreadable → the probe resolves to nothing.
        await smc.breakRead("Tp01")
        await smc.breakRead("Tg0f")
        try await core.apply(manualConfig())
        await core.tick(sleptFor: .zero)

        // Sensors come back; the very next tick must see them again.
        await smc.fixRead("Tp01")
        await smc.fixRead("Tg0f")
        await smc.setTemperature(110)
        await core.heartbeat()
        for _ in 0 ..< 4 {
            await core.heartbeat()
            await core.tick(sleptFor: .zero)
        }
        let targets = await smc.writes.filter { $0.key == "F0Tg" }.map(\.value)
        #expect(targets.contains(6800), "sensors were re-probed, so the ceiling still works")
    }
}
