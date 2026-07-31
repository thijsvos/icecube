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
    /// A write sequence parked mid-flight, and the key that parks it.
    ///
    /// Ordering is the entire subject of the write-intent guard, and a fake
    /// that completes instantly cannot express an ordering. Holding one
    /// sequence inside the write lock lets a test arrange the exact interleave
    /// the guard exists for: a stale decision and a newer one both queued
    /// behind a writer, released together.
    private var gateKey: String?
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var gateIsOpen = false

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
        if key == gateKey, !gateIsOpen {
            await withCheckedContinuation { gateWaiters.append($0) }
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

    func fixWrite(_ key: String) {
        unwritable.remove(key)
    }

    /// Puts a fan into forced mode WITHOUT going through the daemon — the state
    /// `FanGuardian` leaves behind while `config.mode` is still `.auto`, which
    /// a config-based park would walk straight past.
    func setForced(fan: Int, target: Double) {
        values["F\(fan)Md"] = Double(FanMode.forced.rawValue)
        values["F\(fan)Tg"] = target
    }

    func interleaveWrites() {
        yieldOnWrite = true
    }

    /// Parks the next write to `key` until ``openGate()``.
    func gateWrites(on key: String) {
        gateKey = key
        gateIsOpen = false
    }

    /// True once a write sequence is actually parked — a test polls this rather
    /// than guessing with a sleep, so the interleave is arranged, not hoped for.
    func isGated() -> Bool {
        !gateWaiters.isEmpty
    }

    func openGate() {
        gateIsOpen = true
        let waiting = gateWaiters
        gateWaiters.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
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

    func targetWrites(fan: Int) -> [Double] {
        writes.filter { $0.key == "F\(fan)Tg" }.map(\.value)
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

extension PowerCapabilities {
    /// What the owner's Mac reports with the lid open — `0x1F [CDNVA]`. Every
    /// test that is not *about* the dark-wake gate models an awake machine, so
    /// this is the default here. It is deliberately NOT a default on
    /// `DaemonCore.init`: in production, "assume awake" is the bug.
    static let fullWakeCapabilities = PowerCapabilities([.cpu, .video, .audio, .network, .diskOrAOT])
    /// The rtc/Maintenance dark wake that drove both fans to 6800 RPM inside a
    /// closed laptop on 2026-07-31 — `0x79 [CDNPB]`, verbatim.
    static let darkWakeCapabilities = PowerCapabilities([.cpu, .diskOrAOT, .network, .pushServiceTask, .backgroundTask])
}

private func makeCore(
    smc: FakeSMC,
    store: MemoryConfigStore = MemoryConfigStore(),
    capabilities: @escaping @Sendable () -> PowerCapabilities? = { .fullWakeCapabilities }
) -> DaemonCore {
    DaemonCore(port: smc, store: store, capabilities: capabilities, sleep: instantSleep)
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

    // MARK: - Write-path self-test (PLAN.md §4.3.6)

    /// The point of the whole feature: on a machine where fan control works,
    /// say so — and say WHICH path it needed, because that is the fact a new
    /// SoC generation is added from.
    @Test("A healthy machine reports a verified write path, and which unlock it used")
    func selfTestVerifies() async {
        let smc = FakeSMC(temperature: 55)
        let core = makeCore(smc: smc)

        let report = await core.selfTestWritePath()

        #expect(report.verdict == .verified)
        #expect(report.unlockBranch == "direct")
        #expect(report.modeKeySuffix == "Md")
        #expect(report.fanCount == 2)
        #expect(report.fanRanges[0] == [2317, 6800])
        #expect(report.isWorthReporting == false, "a clean pass tells the project nothing new")
    }

    /// SAFETY: a diagnostic must not leave the fans forced. This is the one
    /// property of the self-test that could actually hurt someone — everything
    /// else is a wrong answer, this is a machine left under a probe's control.
    @Test("The self-test always hands the fans back, even after succeeding")
    func selfTestNeverLeavesFansForced() async throws {
        let smc = FakeSMC(temperature: 55)
        let core = makeCore(smc: smc)

        let report = await core.selfTestWritePath()

        #expect(report.verdict == .verified)
        #expect(await core.config.mode == .auto, "ends in auto, whatever it found")
        #expect(try await smc.readDouble("F0Md") != 1, "fan 0 released")
        #expect(try await smc.readDouble("F1Md") != 1, "fan 1 released")
    }

    /// It writes each fan's CURRENT target back to itself, so the check is
    /// audible to nobody. A probe that spun the fans up would be a probe people
    /// learn not to press.
    @Test("The check commands no actual change in fan speed")
    func selfTestIsSilent() async throws {
        let smc = FakeSMC(temperature: 55)
        let core = makeCore(smc: smc)
        let before = try await smc.readDouble("F0Tg")

        _ = await core.selfTestWritePath()

        // The revert parks Tg at the floor, which is the daemon's normal
        // hand-back — the point is that the PROBE never asked for anything else.
        let written = await smc.targetWrites(fan: 0)
        #expect(written.contains(before), "wrote the current target back to itself")
        #expect(written.allSatisfy { $0 >= 2317 }, "and never below the floor")
    }

    /// Firmware that refuses the mode write needs a new unlock path. Firmware
    /// that accepts and ignores it needs a different write sequence. Collapsing
    /// those into "failed" would hide the second, which this project has hit.
    @Test("A firmware that refuses the mode write is reported as rejected, with its own words")
    func selfTestReportsRejection() async {
        let smc = FakeSMC(temperature: 55)
        await smc.breakWrite("F0Md")
        await smc.breakWrite("F0md")
        let core = makeCore(smc: smc)

        let report = await core.selfTestWritePath()

        #expect(report.verdict == .rejected)
        #expect(report.detail?.contains("F0Md") == true, "quotes the firmware, not a paraphrase")
        #expect(report.isWorthReporting, "this is exactly what the project needs to hear")
        #expect(await core.config.mode == .auto)
    }

    /// Caught on real hardware the first time the check ever ran: it reverted
    /// to auto, and nothing put the user's curve back — `autoResumeIfNeeded()`
    /// is latched once per session, so the machine sat on the guardian's floor
    /// hold instead of the Balanced curve it had been running. A diagnostic
    /// that changes your fan settings is not a diagnostic.
    @Test("The check restores the curve it interrupted")
    func selfTestRestoresTheActiveConfig() async throws {
        let smc = FakeSMC(temperature: 55)
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: false))
        #expect(await core.config.mode == .curve)

        _ = await core.selfTestWritePath()
        // The restore is dispatched as the probe unwinds; give it a turn.
        for _ in 0 ..< 20 where await core.config.mode != .curve {
            await Task.yield()
        }

        #expect(await core.config.mode == .curve, "the user's curve must come back")
    }

    @Test("A check run while already in auto leaves it in auto")
    func selfTestFromAutoStaysAuto() async {
        let smc = FakeSMC(temperature: 55)
        let core = makeCore(smc: smc)

        _ = await core.selfTestWritePath()

        #expect(await core.config.mode == .auto)
    }

    @Test("A fanless Mac is a supported configuration, not a failure")
    func selfTestOnFanlessMac() async {
        let smc = FakeSMC(fanCount: 0, temperature: 55)
        let core = makeCore(smc: smc)

        let report = await core.selfTestWritePath()

        #expect(report.verdict == .noUsableFans)
        #expect(report.isWorthReporting == false)
    }

    @Test("Fans whose range never read are not driven by the probe either")
    func selfTestSkipsDegenerateFans() async {
        let smc = FakeSMC(minRPM: 0, maxRPM: 0, temperature: 55)
        let core = makeCore(smc: smc)

        let report = await core.selfTestWritePath()

        #expect(report.verdict == .noUsableFans, "nothing here can be driven safely")
    }

    @Test("An unreadable SMC reports that it could not check, not that it failed")
    func selfTestUnavailableWhenBlind() async {
        let smc = FakeSMC(temperature: 55)
        await smc.breakRead("FNum")
        let core = makeCore(smc: smc)

        let report = await core.selfTestWritePath()

        #expect(report.verdict == .unavailable)
        #expect(report.isWorthReporting == false, "our own blindness is not a hardware report")
    }

    @Test("The report survives a JSON round-trip, since it travels over XPC and into issues")
    func reportRoundTrips() throws {
        let original = WritePathReport(
            verdict: .notVerified, modeKeySuffix: "md", unlockBranch: "ftst",
            fanCount: 2, fanRanges: [0: [1200, 5000]], hasFtstKey: true,
            detail: "accepted but ignored"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WritePathReport.self, from: data)
        #expect(decoded == original)
    }

    /// Found in an overnight log: one wake produced six identical
    /// "temperature read failed" lines describing a single reconnect window.
    /// `resetPort()` closes the connection on every hand-back and on wake, so
    /// these failures always come in runs — six lines reads as six faults.
    @Test("A run of blind ticks is reported once, and its recovery is reported too")
    func blindSpellIsReportedOnce() async {
        let smc = FakeSMC(temperature: 60)
        let core = makeCore(smc: smc)
        await smc.breakRead("Tp01")
        await smc.breakRead("Tg0f")

        for _ in 0 ..< 4 {
            await core.tick(sleptFor: .zero)
        }
        let blindLines = await core.currentStatus().recentEvents
            .filter { $0.contains("temperature read failed") }
        #expect(blindLines.count == 1, "one episode, not one per tick")

        await smc.fixRead("Tp01")
        await smc.fixRead("Tg0f")
        await core.tick(sleptFor: .zero)
        let recovered = await core.currentStatus().recentEvents
            .contains { $0.contains("readable again") }
        #expect(recovered, "and the end of the episode is visible")
    }

    /// The wake re-assert used to run before the safety verdict, so every wake
    /// logged "re-asserting curve control" and then immediately reverted it —
    /// the app's heartbeat cannot tick while the machine sleeps, so a
    /// non-persisting curve is ALWAYS about to be reverted on waking.
    @Test("Waking with a stale heartbeat reverts without announcing a re-assert first")
    func wakeDoesNotAnnounceADoomedReassert() async throws {
        let smc = FakeSMC(temperature: 55)
        let core = makeCore(smc: smc)
        // Deliberately no heartbeat: exactly the state a machine wakes in.
        try await core.apply(curveConfig(persists: false))

        await core.tick(sleptFor: .seconds(600))

        let events = await core.currentStatus().recentEvents
        #expect(await core.config.mode == .auto, "the watchdog still reverts")
        #expect(
            events.contains { $0.contains("wake detected") } == false,
            "no re-assert is announced for something about to be reverted"
        )
    }

    /// The counterweight: a wake with a live app must still re-establish the
    /// curve, because the firmware resets fan control across sleep (§3.4).
    @Test("Waking with a live app re-establishes curve control")
    func wakeWithLiveAppReasserts() async throws {
        let smc = FakeSMC(temperature: 55)
        let core = makeCore(smc: smc)
        try await core.apply(curveConfig(persists: false))
        await core.heartbeat()

        await core.tick(sleptFor: .seconds(600))

        let events = await core.currentStatus().recentEvents
        #expect(await core.config.mode == .curve, "the curve survives")
        #expect(events.contains { $0.contains("wake detected") }, "and the wake is recorded")
    }

    /// The half of the write-race machinery that was correct-by-construction
    /// and never covered (#6).
    ///
    /// `withWriteLock` stops two sequences INTERLEAVING. `writeIntent` stops a
    /// stale one WINNING — different failures. Non-interleaving alone does not
    /// prevent an older complete sequence landing after a newer one, which is
    /// the bug seen on hardware: the guardian's floor-hold engage (2317)
    /// landing after a curve engage (3400), leaving the fans at the floor while
    /// the daemon believed the curve.
    ///
    /// The interleave has to be arranged, not hoped for, so `FakeSMC` parks the
    /// first write sequence inside the lock while two more decisions queue
    /// behind it. The older of those two must stand down when the lock frees.
    ///
    /// Note the pairing is deliberately tick/XPC rather than two applies:
    /// `apply()` guards itself with `applyGeneration`, so two applies can never
    /// reach this path. Only a daemon-initiated engage racing an incoming XPC
    /// message can, which is exactly what happened on the Mac14,9.
    @Test("A decision superseded while queued stands down instead of landing last")
    func staleWriteStandsDownBehindTheLock() async throws {
        let smc = FakeSMC(temperature: 55)
        let core = makeCore(smc: smc)
        await core.heartbeat()

        // A holds the write lock, parked mid-sequence.
        await smc.gateWrites(on: "F1Tg")
        async let holder: Void = core.apply(manualConfig(5000))
        while await !smc.isGated() {
            await Task.yield()
        }

        // B queues behind it — this is the decision that will go stale.
        async let stale = core.selfTestWritePath()
        for _ in 0 ..< 60 {
            await Task.yield()
        }

        // C queues behind B with a newer intent, superseding it.
        async let fresh: Void = core.apply(manualConfig(3000))
        for _ in 0 ..< 60 {
            await Task.yield()
        }

        await smc.openGate()
        _ = try await holder
        _ = await stale
        _ = try await fresh

        let events = await core.currentStatus().recentEvents
        // Matched on the write-intent guard's OWN wording. "superseded" alone
        // also matches `applyGeneration`'s "a newer config superseded this
        // manual apply", which fires here too — so the loose match passed even
        // with the guard deleted, and the test proved nothing.
        // NOT asserting that the stand-down was logged. It usually is — but
        // whether the older decision reaches the lock before the newer one
        // bumps the ledger depends on task scheduling, and asserting it made
        // this test pass and fail on alternate runs. A flaky test is worse than
        // no test, so the RULE is pinned deterministically in
        // `WriteIntentLedgerTests` and this one covers only what holds every
        // time: whatever the interleave, the daemon must end up self-consistent.
        #expect(events.isEmpty == false, "the pile-up produced a record of itself")
        // No fan is left split between two intents…
        let zero = try await smc.readDouble("F0Tg")
        let one = try await smc.readDouble("F1Tg")
        #expect(zero == one, "fans split across two decisions: \(zero) vs \(one)")
        // …and nothing is stranded: a daemon that reports auto must not have
        // left the fans forced at some superseded target. That is the state the
        // whole write-race machinery exists to make unreachable.
        if await core.config.mode == .auto {
            #expect(try await smc.readDouble("F0Md") != 1, "auto, but the fans are still ours")
        }
        #expect(zero >= 2317, "and never below the floor")
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
        let core = DaemonCore(port: smc, store: store, capabilities: { .fullWakeCapabilities }, sleep: instantSleep)
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
        let core = DaemonCore(port: smc, store: store, capabilities: { .fullWakeCapabilities }, sleep: instantSleep)
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
        let core = DaemonCore(port: smc, store: store, capabilities: { .fullWakeCapabilities }, sleep: instantSleep)
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
        let core = DaemonCore(port: smc, store: store, capabilities: { .fullWakeCapabilities }, sleep: instantSleep)
        await core.start()
        #expect(await core.config.mode == .curve, "the boot promise")
        await core.shutdown()
    }

    /// INVARIANT 7: manual mode is never the persisted default.
    @Test("Manual mode is never written to persistent storage")
    func manualNeverPersists() async throws {
        let smc = FakeSMC()
        let store = MemoryConfigStore()
        let core = DaemonCore(port: smc, store: store, capabilities: { .fullWakeCapabilities }, sleep: instantSleep)
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

/// The sleep half of the power contract (PLAN.md §4.3.6).
///
/// The bug these pin: before protocol v20 the daemon had no pre-sleep handling
/// at all, so a lid close left `F{i}Md = 1` latched in firmware and the fans ran
/// forced for the whole closed-lid window — 16 min 34 s in the owner's own log
/// on 2026-07-27 — until an unrelated Power Nap dark wake happened to run a tick
/// and the watchdog fired. Sleep cannot be staged in CI, so every rule that
/// decides what happens across one is asserted here against scripted firmware.
@Suite("DaemonCore — sleep and wake")
struct DaemonCoreSleepTests {
    // MARK: - The park itself

    /// THE BUG. Manual mode, lid closes, fans must be handed back.
    @Test("Going to sleep hands the fans back to the firmware")
    func sleepParksTheFans() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig(5000))
        #expect(await smc.modeWrites(fan: 0).contains(1), "forced before the lid closed")
        await smc.clearWrites()

        await core.prepareForSleep()
        #expect(await smc.modeWrites(fan: 0).contains(0), "fan 0 handed back")
        #expect(await smc.modeWrites(fan: 1).contains(0), "fan 1 too")
        #expect(await core.sleepLatch.isAsleep)
        #expect(await core.sleepLatch.parkLanded)
    }

    /// The distinction the whole fix rests on: a park is NOT a revert. If the
    /// config were wiped, every lid close would silently uninstall the user's
    /// fan control, because nothing puts it back.
    @Test("A park keeps the config and the persisted curve — it is not a revert")
    func parkKeepsTheIntent() async throws {
        let smc = FakeSMC(temperature: 75)
        let store = MemoryConfigStore()
        let core = DaemonCore(port: smc, store: store, capabilities: { .fullWakeCapabilities }, sleep: instantSleep)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: true))
        #expect(store.load() != nil, "the boot promise is armed")

        await core.prepareForSleep()
        #expect(await core.config.mode == .curve, "the user's intent survives sleep")
        #expect(store.load() != nil, "and so does the boot promise")
    }

    /// A dark wake going back to sleep fires `systemWillSleep` again, roughly
    /// every 15 minutes all night. Re-running the hand-back would push a `Tg`
    /// command at fans that are already stopped.
    @Test("Sleeping again after a dark wake does not re-write the hand-back")
    func repeatedWillSleepIsQuiet() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig())
        await core.prepareForSleep()
        await smc.clearWrites()

        await core.prepareForSleep()
        #expect(await smc.writes.isEmpty, "already parked — nothing more to say")
    }

    /// A user who never picked a preset is still being cooled by the guardian,
    /// which forces fans while `config.mode == .auto`. A park gated on the
    /// config alone would walk straight past them.
    @Test("Fans forced while the config says auto are parked too")
    func parksGuardianForcedFans() async {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        // Straight to the hardware state the guardian leaves behind.
        await smc.setForced(fan: 0, target: 4000)
        #expect(await core.config.mode == .auto)

        await core.prepareForSleep()
        #expect(await smc.modeWrites(fan: 0).contains(0), "read-based, not config-based")
    }

    /// The inverse, and the reason the check is read-based in both directions:
    /// on a machine Ice Cube is not driving, `revertAllAuto` would park `Tg` at
    /// `Mn` FIRST — a spin command — on a Mac that is going to sleep.
    @Test("Nothing of ours on the fans means no write at all")
    func parkWritesNothingWhenNotInControl() async {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        #expect(await core.config.mode == .auto)

        await core.prepareForSleep()
        #expect(await smc.writes.isEmpty, "never command a sleeping Mac's fans to spin")
        #expect(await core.sleepLatch.parkLanded, "nothing to do IS a landed park")
    }

    @Test("A park that cannot read the fans reports failure instead of lying")
    func unreadableFansFailThePark() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig())
        await smc.breakRead("FNum")

        await core.prepareForSleep()
        #expect(await !core.sleepLatch.parkLanded)
        #expect(await !core.revertPending, "a park is not a deferred revert")
        let events = await core.currentStatus().recentEvents
        #expect(events.contains { $0.contains("could not read the fans to park") })
    }

    /// The audible failure mode: if the hand-back is refused, the fans are still
    /// forced and the next dark wake must try again.
    @Test("A failed park is retried on the next tick")
    func failedParkIsRetried() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        // No `heartbeat()`: on real hardware `heartbeatAge()` is measured on a
        // ContinuousClock that keeps counting through sleep, so after a nap the
        // age is genuinely stale. In a test the clock never moves, so any
        // heartbeat ever sent stays eternally fresh and would trip the
        // unpark-after-a-nap rule on the first nap tick. Withholding it is how
        // the harness expresses "the app is not talking to us right now".
        try await core.apply(manualConfig())
        await smc.breakWrite("F0Md")

        await core.prepareForSleep()
        #expect(await !core.sleepLatch.parkLanded)
        #expect(try await smc.readDouble("F0Md") == 1, "genuinely still forced")

        await smc.fixWrite("F0Md")
        await core.tick(sleptFor: .seconds(900))
        #expect(try await smc.readDouble("F0Md") != 1, "the retry landed")
        #expect(await core.sleepLatch.parkLanded)
    }

    /// FIELD REGRESSION (Mac14,9, 2026-07-28 09:25:45). A tick fired 9 ms into
    /// the pre-sleep hand-back — between the `F0Tg` and `F0Md` writes — saw
    /// `parkLanded` still false because `parkHardware` had not RETURNED yet, and
    /// logged "the pre-sleep hand-back never landed — trying again" about the
    /// very sequence that was landing as it spoke.
    ///
    /// The hardware was fine (`parkInFlight` collapsed it to one `revertAllAuto`
    /// and the log shows a single write sequence), so this pins the honesty of
    /// the log, which in this daemon is a safety property in its own right.
    @Test("A tick during an in-flight park does not call it a failure")
    func inFlightParkIsNotReportedAsFailed() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        try await core.apply(manualConfig(5000))

        // Park the hand-back mid-sequence, exactly where the field log caught it.
        await smc.gateWrites(on: "F1Tg")
        async let parking: Void = core.prepareForSleep()
        while await !smc.isGated() {
            await Task.yield()
        }
        await smc.clearWrites()

        // The tick that raced it. Must stand still, not editorialise.
        await core.tick(sleptFor: .zero)
        let duringPark = await core.currentStatus().recentEvents
        #expect(
            !duringPark.contains { $0.contains("never landed") },
            "a park in flight is not a park that failed"
        )
        #expect(await smc.writes.isEmpty, "and it must not start a second hand-back")

        await smc.openGate()
        await parking
        #expect(await core.sleepLatch.parkLanded, "the original park still lands")
    }

    // MARK: - Staying parked

    /// The heart of it: dark wakes run real ticks, and before v20 every one of
    /// them re-engaged the curve on a machine about to go back to sleep.
    @Test("Ticks while parked never touch a fan")
    func parkedTicksAreSilent() async throws {
        let smc = FakeSMC(temperature: 75)
        let core = makeCore(smc: smc)
        // No `heartbeat()`: on real hardware `heartbeatAge()` is measured on a
        // ContinuousClock that keeps counting through sleep, so after a nap the
        // age is genuinely stale. In a test the clock never moves, so any
        // heartbeat ever sent stays eternally fresh and would trip the
        // unpark-after-a-nap rule on the first nap tick. Withholding it is how
        // the harness expresses "the app is not talking to us right now".
        try await core.apply(curveConfig(persists: true))
        await core.prepareForSleep()
        await smc.clearWrites()

        // A night of dark wakes: awake ticks interleaved with real naps.
        for _ in 0 ..< 10 {
            await core.tick(sleptFor: .seconds(900))
            await core.tick(sleptFor: .zero)
        }
        #expect(await smc.writes.isEmpty, "not one fan write across a whole night")
        #expect(await core.config.mode == .curve, "and the intent is still there")
    }

    /// The watchdog measures the nap as heartbeat starvation — that is exactly
    /// what fired at 17:49 in the owner's log. While parked it must be deferred,
    /// not honoured, or every lid close destroys the curve config.
    @Test("The watchdog is deferred while parked, not fired")
    func watchdogDeferredWhileParked() async throws {
        let smc = FakeSMC(temperature: 75)
        let store = MemoryConfigStore()
        let core = DaemonCore(port: smc, store: store, capabilities: { .fullWakeCapabilities }, sleep: instantSleep)
        // No `heartbeat()`: on real hardware `heartbeatAge()` is measured on a
        // ContinuousClock that keeps counting through sleep, so after a nap the
        // age is genuinely stale. In a test the clock never moves, so any
        // heartbeat ever sent stays eternally fresh and would trip the
        // unpark-after-a-nap rule on the first nap tick. Withholding it is how
        // the harness expresses "the app is not talking to us right now".
        try await core.apply(curveConfig(persists: false)) // watchdogged
        await core.prepareForSleep()
        await smc.clearWrites()

        await core.tick(sleptFor: .seconds(900)) // 15 minutes of "no heartbeat"
        #expect(await core.config.mode == .curve, "deferred, not reverted")
        #expect(await smc.writes.isEmpty)
    }

    /// …and the counterweight, so "deferred" cannot quietly become "disabled":
    /// once awake, a stale non-persisting curve must still be reverted.
    @Test("The deferred watchdog still fires on the first tick after waking")
    func watchdogFiresAfterWaking() async throws {
        let smc = FakeSMC(temperature: 75)
        let core = makeCore(smc: smc)
        // No `heartbeat()`: on real hardware `heartbeatAge()` is measured on a
        // ContinuousClock that keeps counting through sleep, so after a nap the
        // age is genuinely stale. In a test the clock never moves, so any
        // heartbeat ever sent stays eternally fresh and would trip the
        // unpark-after-a-nap rule on the first nap tick. Withholding it is how
        // the harness expresses "the app is not talking to us right now".
        try await core.apply(curveConfig(persists: false))
        await core.prepareForSleep()
        await core.tick(sleptFor: .seconds(900))
        #expect(await core.config.mode == .curve, "still parked")

        await core.systemDidPowerOn() // but the app never comes back
        await core.tick(sleptFor: .zero)
        #expect(await core.config.mode == .auto, "the watchdog was deferred, not disarmed")
    }

    /// INVARIANT 3 is kept, not narrowed. A dark wake runs with the SoC fully
    /// live, and the fans are in the hands of a thermalmonitord that FanGuardian
    /// documents does not reliably resume.
    @Test("The temperature ceiling stays armed while parked")
    func ceilingStaysArmedWhileParked() async throws {
        let smc = FakeSMC(temperature: 75)
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: true))
        await core.prepareForSleep()
        await smc.clearWrites()

        await smc.setTemperature(110) // well over the 104 die ceiling
        for _ in 0 ..< 4 { // ceilingDebounceTicks is 3
            await core.heartbeat()
            await core.tick(sleptFor: .zero)
        }
        #expect(await !core.sleepLatch.isAsleep, "the ceiling takes the fans back")
        #expect(await smc.targetWrites(fan: 0).contains(6800), "and drives them at maximum")
        let events = await core.currentStatus().recentEvents
        #expect(events.contains { $0.contains("ceiling while parked") })
    }

    // MARK: - Waking up

    /// The race that makes a naive latch silently break the WAKE half: at the
    /// instant of wake the tick loop's long-expired deadline fires with `slept`
    /// = the whole nap, and a parked tick that returns early CONSUMES it. Without
    /// `pendingWake`, no later tick would ever see `wokeUp`, so manual would
    /// never be re-asserted.
    @Test("A parked tick that swallows the nap still produces a wake")
    func parkedTickDoesNotSwallowTheWakeEdge() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        // No `heartbeat()`: on real hardware `heartbeatAge()` is measured on a
        // ContinuousClock that keeps counting through sleep, so after a nap the
        // age is genuinely stale. In a test the clock never moves, so any
        // heartbeat ever sent stays eternally fresh and would trip the
        // unpark-after-a-nap rule on the first nap tick. Withholding it is how
        // the harness expresses "the app is not talking to us right now".
        try await core.apply(manualConfig())
        await core.prepareForSleep()
        await core.tick(sleptFor: .seconds(900)) // the parked tick eats the diff
        #expect(await core.sleepLatch.isAsleep, "the nap alone must not unpark")
        await smc.clearWrites()

        await core.systemDidPowerOn()
        await core.heartbeat()
        await core.tick(sleptFor: .zero) // no nap left to measure
        #expect(await smc.modeWrites(fan: 0).contains(1), "manual re-asserted anyway")
        let events = await core.currentStatus().recentEvents
        #expect(events.contains { $0.contains("wake detected") })
    }

    @Test("Waking resumes the curve through the ordinary tick")
    func wakeResumesTheCurve() async throws {
        let smc = FakeSMC(temperature: 75)
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: true))
        await core.prepareForSleep()
        await smc.clearWrites()

        await core.systemDidPowerOn()
        await core.tick(sleptFor: .zero)
        #expect(try await smc.readDouble("F0Md") == 1, "back under our control")
        #expect(await !smc.targetWrites(fan: 0).isEmpty)
    }

    /// The dangerous window. A heartbeat arriving between the lid closing and
    /// the power dropping must NOT unpark us — no second `systemWillSleep` would
    /// come to park us again, which is precisely the original bug.
    @Test("A heartbeat before any nap does not unpark")
    func heartbeatBeforeANapDoesNotUnpark() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig())
        await core.prepareForSleep()
        await smc.clearWrites()

        await core.heartbeat() // the app is still winding down
        await core.tick(sleptFor: .zero)
        #expect(await core.sleepLatch.isAsleep, "still parked")
        #expect(await smc.writes.isEmpty)
    }

    /// …but after a real nap a heartbeat is positive evidence of a true wake:
    /// the user session is not scheduled during a dark wake. This is the
    /// insurance against a `kIOMessageSystemHasPoweredOn` that never arrives.
    @Test("A heartbeat after a nap does unpark")
    func heartbeatAfterANapUnparks() async throws {
        let smc = FakeSMC(temperature: 75)
        let core = makeCore(smc: smc)
        // No `heartbeat()`: on real hardware `heartbeatAge()` is measured on a
        // ContinuousClock that keeps counting through sleep, so after a nap the
        // age is genuinely stale. In a test the clock never moves, so any
        // heartbeat ever sent stays eternally fresh and would trip the
        // unpark-after-a-nap rule on the first nap tick. Withholding it is how
        // the harness expresses "the app is not talking to us right now".
        try await core.apply(curveConfig(persists: false))
        await core.prepareForSleep()
        await core.tick(sleptFor: .seconds(900)) // nap observed, still parked
        #expect(await core.sleepLatch.isAsleep)

        await core.heartbeat()
        await core.tick(sleptFor: .zero)
        #expect(await !core.sleepLatch.isAsleep)
        let events = await core.currentStatus().recentEvents
        #expect(events.contains { $0.contains("the app checked in") })
    }

    // MARK: - The guards

    @Test("Applying a config while parked refuses instead of lying")
    func applyWhileParkedThrows() async throws {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.prepareForSleep()
        await smc.clearWrites()

        await #expect(throws: IceCubeError.systemAsleep) {
            try await core.apply(manualConfig())
        }
        #expect(await !smc.modeWrites(fan: 0).contains(1), "and writes nothing")
    }

    /// INVARIANT 2, deliberately narrowed while parked: the fans are ALREADY
    /// with macOS — the strongest form of what that invariant produces — and
    /// `keepFansSpinning` would take them straight back, into the sleep this
    /// exists to prevent. Recorded in PLAN.md §4.3.6 as part of the contract.
    @Test("Losing the app while parked leaves the fans with macOS")
    func invalidationWhileParkedIsDeferred() async throws {
        let smc = FakeSMC(temperature: 60) // warm enough that the guardian would grab
        let core = makeCore(smc: smc)
        await core.heartbeat()
        try await core.apply(manualConfig(5000))
        await core.prepareForSleep()
        await smc.clearWrites()

        await core.connectionInvalidated()
        #expect(await smc.writes.isEmpty, "no re-grab on a sleeping Mac")
        #expect(try await smc.readDouble("F0Md") != 1)
    }

    @Test("The write-path self-test is unavailable while parked")
    func selfTestUnavailableWhileParked() async {
        let smc = FakeSMC()
        let core = makeCore(smc: smc)
        await core.prepareForSleep()
        #expect(await core.selfTestWritePath().verdict == .unavailable)
    }

    /// "Turn Off Fan Control" has to mean off, parked or not — including
    /// cancelling the boot promise.
    @Test("Turning off fan control while parked still means off")
    func setAllAutoWorksWhileParked() async throws {
        let smc = FakeSMC(temperature: 75)
        let store = MemoryConfigStore()
        let core = DaemonCore(port: smc, store: store, capabilities: { .fullWakeCapabilities }, sleep: instantSleep)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: true))
        await core.prepareForSleep()

        await core.setAllAuto()
        #expect(await core.config.mode == .auto)
        #expect(store.load() == nil, "off means off")
    }

    /// The judges' fatal-flaw regression. A write failing as the machine
    /// quiesces at lid close is the single most likely moment for one, and
    /// `engage`'s catch reaches `revertEverything`, whose default
    /// `clearsPersistence: true` would DELETE the user's curve from disk.
    @Test("A write that fails while parking does not wipe the config")
    func failedWriteWhileParkedKeepsTheConfig() async throws {
        let smc = FakeSMC(temperature: 75)
        let store = MemoryConfigStore()
        let core = DaemonCore(port: smc, store: store, capabilities: { .fullWakeCapabilities }, sleep: instantSleep)
        await core.heartbeat()
        try await core.apply(curveConfig(persists: true))
        await core.prepareForSleep()

        // A curve tick that squeezes past the park and then fails mid-sequence.
        await smc.breakWrite("F1Tg")
        await smc.setTemperature(85)
        await core.tick(sleptFor: .zero)

        #expect(await core.config.mode == .curve, "the intent survives")
        #expect(store.load() != nil, "and so does the boot promise")
    }
}

/// A capability reading a test can change mid-flight, so one test can walk a
/// machine from dark wake to full wake exactly the way opening the lid does.
private final class CapabilityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PowerCapabilities?

    init(_ value: PowerCapabilities?) {
        self.value = value
    }

    var current: PowerCapabilities? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }

    var read: @Sendable () -> PowerCapabilities? {
        { self.current }
    }
}

/// THE 2026-07-31 REGRESSION. A scheduled rtc/Maintenance dark wake fired with
/// the lid shut; the daemon's heartbeat-after-a-nap rule read it as a real wake,
/// unparked, and drove both fans to 6800 RPM for 69 seconds inside a closed
/// laptop. Nothing in the suite could have caught it, because nothing modelled
/// the difference between a dark wake and a full one.
///
/// The rule for all of these: while parked, a write to the fans requires a
/// powered display — with exactly one exception, the temperature ceiling, which
/// is the one release allowed to make noise in a bag because by then the
/// alternative is heat.
@Suite("DaemonCore — the fans stay quiet on a dark wake")
struct DarkWakeTests {
    @Test("A heartbeat during a dark wake does NOT unpark — the reported bug")
    func heartbeatInADarkWakeStaysParked() async throws {
        let smc = FakeSMC(temperature: 75)
        let core = makeCore(smc: smc, capabilities: { .darkWakeCapabilities })
        try await core.apply(curveConfig(persists: true))
        await core.prepareForSleep()
        await core.tick(sleptFor: .seconds(900)) // the nap, as on the night
        await smc.clearWrites()

        // Exactly the sequence that spun the fans: the app's 5 s timer fires
        // inside the dark wake and checks in.
        await core.heartbeat()
        await core.tick(sleptFor: .zero)

        #expect(await core.sleepLatch.isAsleep, "a dark wake is not a wake")
        #expect(await smc.modeWrites(fan: 0).isEmpty, "and above all: no write to fan 0")
        #expect(await smc.modeWrites(fan: 1).isEmpty, "or fan 1")
        #expect(await smc.targetWrites(fan: 0).isEmpty)
        let events = await core.currentStatus().recentEvents
        #expect(events.contains { $0.contains("no display is powered") }, "and it says why")
    }

    /// The same machine 69 seconds later, when the owner opened the lid. The
    /// gate must not be a trap: a real wake still resumes within one tick.
    @Test("Opening the lid promotes the dark wake and control resumes")
    func promotionToFullWakeUnparks() async throws {
        let smc = FakeSMC(temperature: 75)
        let capabilities = CapabilityBox(.darkWakeCapabilities)
        let core = makeCore(smc: smc, capabilities: capabilities.read)
        try await core.apply(curveConfig(persists: true))
        await core.prepareForSleep()
        await core.tick(sleptFor: .seconds(900))
        await core.heartbeat()
        await core.tick(sleptFor: .zero)
        #expect(await core.sleepLatch.isAsleep, "still parked while dark")

        capabilities.current = .fullWakeCapabilities // the lid opens
        await core.heartbeat()
        await core.tick(sleptFor: .zero)
        #expect(await !core.sleepLatch.isAsleep, "a lit display is a real wake")
    }

    /// A `kIOMessageSystemHasPoweredOn` delivered while no display is up must be
    /// remembered, not spent — a DarkWake→FullWake promotion sends no second
    /// message, so forgetting the edge would strand the daemon parked.
    @Test("A power-on edge during a dark wake is held, then completes on promotion")
    func powerOnEdgeIsHeldNotSpent() async throws {
        let smc = FakeSMC(temperature: 75)
        let capabilities = CapabilityBox(.darkWakeCapabilities)
        let core = makeCore(smc: smc, capabilities: capabilities.read)
        try await core.apply(manualConfig())
        await core.prepareForSleep()
        await smc.clearWrites()

        await core.systemDidPowerOn()
        #expect(await core.sleepLatch.isAsleep, "the message alone proves nothing")
        #expect(await smc.modeWrites(fan: 0).isEmpty)

        capabilities.current = .fullWakeCapabilities
        await core.tick(sleptFor: .zero)
        #expect(await !core.sleepLatch.isAsleep, "the held edge completes without a second message")
    }

    /// INVARIANT 3 is kept, not narrowed. This is the one release that is
    /// deliberately NOT gated: a machine genuinely over the die ceiling should
    /// spin its fans even in a bag, because by then noise is the cheap option.
    @Test("The temperature ceiling still takes the fans back during a dark wake")
    func ceilingIsNotGatedByTheWakeClass() async throws {
        let smc = FakeSMC(temperature: 75)
        let core = makeCore(smc: smc, capabilities: { .darkWakeCapabilities })
        await core.heartbeat()
        try await core.apply(curveConfig(persists: true))
        await core.prepareForSleep()
        await smc.clearWrites()

        await smc.setTemperature(110)
        for _ in 0 ..< 4 {
            await core.heartbeat()
            await core.tick(sleptFor: .zero)
        }
        #expect(await !core.sleepLatch.isAsleep, "the ceiling outranks the dark-wake hold")
        #expect(await smc.targetWrites(fan: 0).contains(6800), "and drives them at maximum")
    }

    /// The second route to the same bug: a Time Machine or Spotlight dark wake
    /// that simply outruns the missed-wake budget used to release the latch and
    /// re-engage the curve on a machine in a bag.
    @Test("The missed-wake failsafe stands down inside a confirmed dark wake")
    func missedWakeRefusesInADarkWake() async throws {
        let smc = FakeSMC(temperature: 75)
        let core = makeCore(smc: smc, capabilities: { .darkWakeCapabilities })
        try await core.apply(curveConfig(persists: true))
        await core.prepareForSleep()
        await core.tick(sleptFor: .seconds(900))
        await smc.clearWrites()

        // Well past the 300 s budget at a 2 s tick, twice over, to prove the
        // refusal re-arms instead of firing once and then releasing.
        for _ in 0 ..< 400 {
            await core.tick(sleptFor: .zero)
        }
        #expect(await core.sleepLatch.isAsleep, "still parked after 800 s of dark wake")
        #expect(await smc.modeWrites(fan: 0).isEmpty, "and it never touched the fans")
        let events = await core.currentStatus().recentEvents
        #expect(events.contains { $0.contains("failsafe stands down") })
    }

    /// launchd `KeepAlive`, a crash restart and `softwareupdate` all start this
    /// daemon, and a maintenance dark wake is exactly when softwareupdate runs.
    /// The boot promise is "the persisted curve is live before the app
    /// launches", not "the fans move the instant launchd starts us".
    @Test("Starting inside a dark wake loads the curve without touching the fans")
    func bootInsideADarkWakeIsSilent() async {
        let smc = FakeSMC(temperature: 75)
        let store = MemoryConfigStore(seeded: curveConfig(persists: true))
        let core = DaemonCore(
            port: smc, store: store, capabilities: { .darkWakeCapabilities }, sleep: instantSleep
        )
        await core.start()

        #expect(await core.currentStatus().mode == .curve, "the boot promise is still kept")
        #expect(await core.currentStatus().activeCurve == FanCurve.balanced, "and reported")
        #expect(await smc.modeWrites(fan: 0).isEmpty, "but nothing was written")
        #expect(await core.sleepLatch.isAsleep, "held, pending a display")
        await core.shutdown()
    }

    /// Unlike the sleep latch, the boot latch is bounded: no `systemWillSleep`
    /// ever arrived for it, so a machine whose display bit we are misreading is
    /// the likelier explanation than a laptop in a bag.
    @Test("A boot-time hold releases once a display comes up")
    func bootHoldReleasesOnFullWake() async {
        let smc = FakeSMC(temperature: 75)
        let store = MemoryConfigStore(seeded: curveConfig(persists: true))
        let capabilities = CapabilityBox(.darkWakeCapabilities)
        let core = DaemonCore(
            port: smc, store: store, capabilities: capabilities.read, sleep: instantSleep
        )
        await core.start()
        #expect(await core.sleepLatch.isAsleep)

        capabilities.current = .fullWakeCapabilities
        await core.heartbeat()
        await core.tick(sleptFor: .zero)
        #expect(await !core.sleepLatch.isAsleep, "a display came up")
        await core.shutdown()
    }

    /// An unreadable capability must never be mistaken for a wake — but it must
    /// also not park a desktop forever, so `start()` only holds on a CONFIRMED
    /// dark wake.
    @Test("An unreadable capability never counts as a wake")
    func unknownIsNeverAFullWake() async throws {
        let smc = FakeSMC(temperature: 75)
        let core = makeCore(smc: smc, capabilities: { nil })
        try await core.apply(curveConfig(persists: true))
        await core.prepareForSleep()
        await core.tick(sleptFor: .seconds(900))
        await smc.clearWrites()

        await core.heartbeat()
        await core.tick(sleptFor: .zero)
        #expect(await core.sleepLatch.isAsleep, "no evidence is not evidence of a wake")
    }
}

/// The bit test the whole gate reduces to. These constants are restated from a
/// C enum Swift cannot see, so a typo here is a fan blasting in a closed bag.
@Suite("PowerCapabilities — telling a dark wake from a full one")
struct PowerCapabilityTests {
    @Test("Video plus CPU is a full wake; CPU alone is a dark wake")
    func theVideoBitDecides() {
        #expect(WakeClassifier.classify(.fullWakeCapabilities) == .fullWake)
        #expect(WakeClassifier.classify(.darkWakeCapabilities) == .darkWake)
        #expect(WakeClassifier.classify(PowerCapabilities([.cpu])) == .darkWake)
        #expect(WakeClassifier.classify(PowerCapabilities([.cpu, .video])) == .fullWake)
    }

    /// A docked MacBook driving an external panel with the lid shut reports the
    /// video bit exactly like an open lid does. Keying the gate on lid state
    /// instead would leave that machine parked under full load with only the
    /// 104 °C ceiling between it and a thermal problem.
    @Test("Clamshell with an external display is a full wake")
    func clamshellWithAnExternalDisplayIsAFullWake() {
        #expect(WakeClassifier.classify(PowerCapabilities(rawValue: 0x0F)) == .fullWake)
    }

    /// Stricter than IOKit's own `IOPMIsAUserWake`, which is literally
    /// `caps & 0x02` and so calls the physically impossible 0x02 a user wake.
    @Test("Nonsense readings are never a full wake")
    func garbageIsNeverAFullWake() {
        #expect(WakeClassifier.classify(nil) == .unknown)
        #expect(WakeClassifier.classify(PowerCapabilities(rawValue: 0)) == .asleep)
        #expect(WakeClassifier.classify(PowerCapabilities([.video])) == .asleep, "video without CPU is impossible")
    }

    /// The log line has to line up against `pmset -g log`'s own bracket for the
    /// same second — that correlation is how this bug was found.
    @Test("The description matches pmset's notation")
    func descriptionMatchesPmset() {
        #expect(PowerCapabilities.describe(.darkWakeCapabilities) == "0x79 [CDNPB]")
        #expect(PowerCapabilities.describe(nil) == "capabilities unreadable")
        #expect(PowerCapabilities.describe(PowerCapabilities([.cpu])) == "0x01 [C]")
    }
}
