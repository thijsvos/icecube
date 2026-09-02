// HelperManagerTests.swift — the app's side of the daemon relationship: handshake, self-heal, auto-resume, clean slate.

import Foundation
import IceCubeKit
import ServiceManagement
import Testing

// MARK: - Fakes

/// An in-memory `KeyValueStore`, so a test never touches the preferences
/// system.
///
/// This replaces `UserDefaults(suiteName: <uuid>)`, which was isolated per test
/// but wrote a real plist into ~/Library/Preferences that outlived the process.
/// 1,097 of them — 4.3 MB of empty `{}` files — had accumulated since the day
/// this suite was written. Cleaning up in `deinit` does not work: cfprefsd owns
/// the file and flushes the domain back at process exit, after any in-process
/// delete. Not touching it at all does.
@MainActor
final class MemoryDefaults: KeyValueStore {
    private var values: [String: Any] = [:]

    nonisolated init() {}

    func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    func integer(forKey defaultName: String) -> Int {
        values[defaultName] as? Int ?? 0
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func data(forKey defaultName: String) -> Data? {
        values[defaultName] as? Data
    }

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }
}

/// A scripted XPC channel. Records what the manager asked for, so a test can
/// assert on the conversation rather than only on the end state.
@MainActor
private final class FakeChannel: HelperChanneling {
    /// Stands in for `HelperClient.NotConnected`, which is private to the app.
    struct NotConnected: Error {}

    var onDisconnect: (() -> Void)?
    private(set) var isConnected = false

    /// What `version()` answers. Defaults to agreeing with the app.
    var reportedVersion = HelperConstants.protocolVersion
    /// When set, every call throws it — a daemon that is registered but dead.
    var failure: Error?
    var statusToReport = HelperStatus(mode: .auto)

    private(set) var appliedConfigs: [FanConfig] = []
    private(set) var setAllAutoCount = 0
    private(set) var heartbeats = 0
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    func connect() {
        connectCount += 1
        isConnected = true
    }

    func disconnect() {
        disconnectCount += 1
        isConnected = false
    }

    func version() async throws -> String {
        if let failure {
            throw failure
        }
        return reportedVersion
    }

    /// Thrown by `apply` only: the daemon refusing a write while every other
    /// call still answers, which is exactly what a parked daemon looks like.
    /// `failure` throws from every method and cannot express that shape.
    var applyFailure: Error?

    func apply(_ config: FanConfig) async throws {
        if let error = applyFailure ?? failure {
            throw error
        }
        appliedConfigs.append(config)
    }

    func setAllAuto() async throws {
        if let failure {
            throw failure
        }
        // Mirrors `HelperClient.call`, which guards `connection` and throws
        // before sending anything. This double used to answer happily while
        // disconnected, and that kindness is exactly why `unregister` shipped
        // without a `connect()`: the only test that could have caught it was
        // talking to a fake with no such requirement.
        guard isConnected else {
            throw NotConnected()
        }
        setAllAutoCount += 1
    }

    func heartbeat() {
        heartbeats += 1
    }

    func status() async throws -> HelperStatus {
        if let failure {
            throw failure
        }
        return statusToReport
    }

    /// What the daemon would answer. Defaults to a clean pass on the machine
    /// this project is developed on.
    var writePathToReport = WritePathReport(
        verdict: .verified, modeKeySuffix: "Md", unlockBranch: "direct", fanCount: 2
    )
    private(set) var selfTestCount = 0

    func selfTestWritePath() async throws -> WritePathReport {
        selfTestCount += 1
        if let failure {
            throw failure
        }
        return writePathToReport
    }
}

/// A scripted `SMAppService`. `register()` advances the status the way launchd
/// does, unless a test says otherwise.
@MainActor
private final class FakeRegistrar: DaemonRegistering {
    var status: SMAppService.Status = .notRegistered
    /// Status adopted by a successful `register()`.
    var statusAfterRegister: SMAppService.Status = .enabled
    var registerError: Error?
    var unregisterError: Error?

    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openedSettings = 0

    func register() throws {
        registerCount += 1
        if let registerError {
            throw registerError
        }
        status = statusAfterRegister
    }

    func unregister() async throws {
        unregisterCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }

    func openSettings() {
        openedSettings += 1
    }
}

/// A power source the test can flip by hand — no battery, and no dependence on
/// whether the CI runner happens to be plugged in (it always is).
@MainActor
private final class FakePowerSource: PowerSourceObserving {
    var isCharging = false
    var current: PowerProfilePolicy.PowerSource
    var onChange: (@MainActor () -> Void)?
    private(set) var startCalls = 0

    init(_ initial: PowerProfilePolicy.PowerSource = .wall) {
        current = initial
    }

    func start() {
        startCalls += 1
    }
}

/// A user the test can send away and bring back — no lock screen, and no
/// dependence on what state the CI runner's session happens to be in.
@MainActor
private final class FakePresence: PresenceObserving {
    var current: PresencePolicy.Presence
    var reason: String
    var onChange: (@MainActor () -> Void)?
    private(set) var startCalls = 0

    init(_ initial: PresencePolicy.Presence = .present, reason: String = "here") {
        current = initial
        self.reason = reason
    }

    func start() {
        startCalls += 1
    }
}

/// `DaemonRegistering` is a protocol, not a class, so a value copy would lose
/// the fake's recorded calls. This forwards to a shared reference.
@MainActor
private struct RegistrarProxy: DaemonRegistering {
    let inner: FakeRegistrar
    var status: SMAppService.Status {
        inner.status
    }

    func register() throws {
        try inner.register()
    }

    func unregister() async throws {
        try await inner.unregister()
    }

    func openSettings() {
        inner.openSettings()
    }
}

// MARK: - Tests

/// `HelperManager` is where two of this session's bugs lived, and neither could
/// be caught by a test: it hardcoded `SMAppService`, `HelperClient` and
/// `UserDefaults`, so merely constructing one talked to launchd and started a
/// 5 s timer. Those three are now injected and the timers moved behind
/// `start()`, which the app calls and these tests do not.
@Suite("HelperManager — registration, handshake and the clean slate")
@MainActor
struct HelperManagerTests {
    /// A store per test, in memory, so nothing touches the developer's real
    /// preferences and nothing is left on disk afterwards.
    private func makeDefaults() -> MemoryDefaults {
        MemoryDefaults()
    }

    private func makeManager(
        registrar: FakeRegistrar,
        channel: FakeChannel,
        defaults: MemoryDefaults,
        blocker: String? = nil,
        power: FakePowerSource = FakePowerSource(),
        presence: FakePresence = FakePresence()
    ) -> HelperManager {
        HelperManager(
            service: RegistrarProxy(inner: registrar),
            client: channel,
            defaults: defaults,
            blocker: { blocker },
            powerSource: power,
            presence: presence
        )
    }

    // MARK: - Turning fan control off

    /// The uninstall path's entire job, and it could not do it.
    ///
    /// `unregister` is reachable from a disconnected app — the button stays
    /// enabled in that state deliberately, because the mach service is
    /// demand-launched and a registered daemon is still there to answer. But
    /// the hand-back went out through `HelperClient.call`, which throws
    /// `NotConnected` on a nil connection, so the one call that drops the fans
    /// to auto and clears the persisted curve never left the app. The user was
    /// then told to restart their Mac, about a daemon that had been reachable
    /// the whole time, while the curve survived to be resumed by the next
    /// install.
    @Test("Turning fan control off hands the fans back even from a disconnected app")
    func unregisterHandsBackWhileDisconnected() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel() // never connected, which is the point
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.unregister()

        #expect(
            channel.setAllAutoCount == 1,
            "the daemon must be dropped to auto before it is removed, or the fans are stranded"
        )
        #expect(registrar.unregisterCount == 1, "and the daemon still has to go away")
    }

    // MARK: - Registration status mapping

    /// `.notFound` is the trap. It is also what a never-registered daemon
    /// reports on a fresh machine, so reading it as a broken bundle tells a
    /// first-time user their install is damaged when nothing is wrong.
    @Test("A daemon macOS has never seen reads as not-registered, not as broken")
    func notFoundIsNotAFailure() {
        let registrar = FakeRegistrar()
        let channel = FakeChannel()
        registrar.status = .notFound
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        #expect(manager.registration == .notRegistered)
    }

    @Test("Every other SMAppService status maps straight through")
    func statusMapping() {
        let cases: [(SMAppService.Status, HelperManager.Registration)] = [
            (.notRegistered, .notRegistered),
            (.requiresApproval, .requiresApproval),
            (.enabled, .enabled),
        ]
        for (smStatus, expected) in cases {
            let registrar = FakeRegistrar()
            registrar.status = smStatus
            let manager = makeManager(
                registrar: registrar, channel: FakeChannel(), defaults: makeDefaults()
            )
            #expect(manager.registration == expected, "\(smStatus) should map to \(expected)")
        }
    }

    // MARK: - The preflight refusal

    /// SAFETY-OF-SETUP. Re-register is unregister-then-register, so tearing
    /// down a working registration we already know cannot be restored leaves
    /// the user with no fan control at all — strictly worse than before they
    /// clicked the button.
    @Test("A re-register that is certain to fail never tears down what works")
    func reregisterRefusesWhenBlocked() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(
            registrar: registrar, channel: channel, defaults: makeDefaults(),
            blocker: "This build isn’t code-signed."
        )

        await manager.reregister()

        #expect(registrar.unregisterCount == 0, "must not tear down a working registration")
        #expect(registrar.registerCount == 0)
        #expect(manager.lastError == "This build isn’t code-signed.")
        #expect(manager.registration == .enabled, "still registered")
    }

    /// Reinstalling the background service silently reset the user to Balanced.
    ///
    /// `reregister()` is unregister-then-register, and `unregister()` wiped the
    /// app's whole memory of fan control — `lastCurveConfig` AND
    /// `startupPreference`. Afterwards the fresh daemon reports `.auto`,
    /// `didAutoResume` has been cleared, and `autoResumeIfNeeded` asks
    /// `StartupPolicy.decide(daemonMode: .auto, preference: nil, storedCurve: nil,
    /// fallback: .balanced)` — which is the "user has never chosen" answer.
    ///
    /// It is not a rare path. `maintain()` self-heals automatically on
    /// `.versionMismatch`, and a `protocolVersion` bump is the *designed* upgrade
    /// path, so this fired on every app update that touched the daemon — and on
    /// every press of the Reinstall button XCODE_GUIDE.md §4.4 asks the owner for
    /// after each helper rebuild.
    @Test("Reinstalling the service keeps the curve the user chose")
    func reregisterKeepsTheUsersCurve() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let defaults = makeDefaults()
        let manager = makeManager(registrar: registrar, channel: FakeChannel(), defaults: defaults)

        let memory = FanControlMemory(defaults: defaults)
        var chosen = FanConfig(mode: .curve)
        chosen.sharedCurve = FanCurve.quiet
        memory.remember(applied: chosen)
        #expect(memory.lastCurve != nil, "precondition: the user picked a curve")

        await manager.reregister()

        #expect(memory.lastCurve != nil, "a reinstall is a repair, not a reset to Balanced")
    }

    /// The counterweight, and the reason this is a parameter rather than a
    /// deletion: turning fan control off IS meant to be a clean slate, so that
    /// re-enabling later cannot resurrect a curve from a forgotten session.
    @Test("Turning fan control off still forgets the curve")
    func unregisterForgetsTheUsersCurve() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let defaults = makeDefaults()
        let manager = makeManager(registrar: registrar, channel: FakeChannel(), defaults: defaults)

        let memory = FanControlMemory(defaults: defaults)
        var chosen = FanConfig(mode: .curve)
        chosen.sharedCurve = FanCurve.quiet
        memory.remember(applied: chosen)
        #expect(memory.lastCurve != nil, "precondition")

        await manager.unregister()

        #expect(memory.lastCurve == nil, "turning it off is a decision, and a clean slate")
    }

    @Test("A blocked register reports the blocker instead of calling launchd")
    func registerRefusesWhenBlocked() {
        let registrar = FakeRegistrar()
        let manager = makeManager(
            registrar: registrar, channel: FakeChannel(), defaults: makeDefaults(),
            blocker: "Ice Cube has to run from /Applications."
        )
        manager.register()
        #expect(registrar.registerCount == 0)
        #expect(manager.lastError == "Ice Cube has to run from /Applications.")
    }

    // MARK: - Re-register retry ladder

    /// launchd needs a moment to drop the old job, so the FIRST register after
    /// an unregister usually fails. Publishing that failure flashed "Fan control
    /// can't start" on the way to succeeding; only the last attempt is real.
    @Test("An early register failure is retried, and never shown as an error")
    func reregisterRetriesQuietly() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        // Fail the first two registers, then let it through.
        var attempts = 0
        let failing = FakeRegistrar()
        failing.status = .enabled
        let channel = FakeChannel()

        // A registrar whose first two register() calls leave it notRegistered.
        struct FlakyRegistrar: DaemonRegistering {
            let inner: FakeRegistrar
            let bump: () -> Int
            var status: SMAppService.Status {
                inner.status
            }

            func register() throws {
                inner.status = bump() >= 3 ? .enabled : .notRegistered
            }

            func unregister() async throws {
                try await inner.unregister()
            }

            func openSettings() {
                inner.openSettings()
            }
        }

        let manager = HelperManager(
            service: FlakyRegistrar(inner: failing, bump: { attempts += 1; return attempts }),
            client: channel,
            defaults: makeDefaults(),
            blocker: { nil }
        )

        await manager.reregister()

        #expect(attempts >= 3, "must keep retrying past the first failure")
        #expect(manager.registration == .enabled)
        #expect(manager.lastError == nil, "a retried-then-succeeded register is not an error")
        _ = registrar
    }

    @Test("When every retry fails, the user finally hears about it")
    func reregisterSurfacesFinalFailure() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        registrar.statusAfterRegister = .notRegistered // never takes
        let manager = makeManager(
            registrar: registrar, channel: FakeChannel(), defaults: makeDefaults()
        )

        await manager.reregister()

        #expect(registrar.registerCount == 6, "the full retry ladder")
        #expect(manager.lastError != nil, "a genuinely failed repair must be visible")
        #expect(manager.isReregistering == false, "the progress flag is always cleared")
    }

    // MARK: - The version handshake

    @Test("A daemon on our protocol version connects")
    func handshakeAgrees() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.maintainOnce()

        #expect(manager.connection == .connected(version: HelperConstants.protocolVersion))
        #expect(channel.heartbeats == 1, "a connected pass feeds the watchdog")
    }

    /// The whole point of the version discipline: replacing the app does not
    /// restart the running daemon, so a stale one must be repaired rather than
    /// talked to. The app can do that itself, so it should.
    @Test("An older daemon triggers a self-heal instead of asking the user")
    func versionMismatchSelfHeals() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        channel.reportedVersion = "1"
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.maintainOnce()

        #expect(registrar.unregisterCount == 1, "self-heal reinstalls the service")
        #expect(registrar.registerCount >= 1)
    }

    @Test("A registered daemon that never answers leaves the app disconnected, not crashed")
    func unreachableDaemonStaysDisconnected() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        channel.failure = IceCubeError.smcKeyNotFound(key: "n/a")
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.maintainOnce()

        #expect(manager.connection == .disconnected)
        #expect(channel.disconnectCount >= 1, "a failed handshake resets the channel")
    }

    @Test("Maintenance does nothing at all while the daemon is not registered")
    func maintenanceIdlesWhenUnregistered() async {
        let registrar = FakeRegistrar()
        registrar.status = .notRegistered
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.maintainOnce()

        #expect(manager.connection == .disconnected)
        #expect(channel.connectCount == 0, "no point dialling a service that isn't there")
    }

    // MARK: - Auto-resume on first connection

    /// The project's stated rule: a user who has never chosen a mode gets the
    /// Balanced curve, not macOS's Automatic. Absence of a preference means
    /// "give them the point of the app", not "do nothing".
    @Test("A user who never chose anything lands on the Balanced curve")
    func autoResumeAppliesDefaultCurve() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.maintainOnce()

        #expect(channel.appliedConfigs.count == 1)
        #expect(channel.appliedConfigs.first?.mode == .curve)
        #expect(channel.appliedConfigs.first?.sharedCurve == HelperManager.defaultStartupCurve)
    }

    @Test("Auto-resume happens once a session, not on every maintenance pass")
    func autoResumeIsOnceOnly() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.maintainOnce()
        let afterFirst = channel.appliedConfigs.count
        await manager.maintainOnce()
        await manager.maintainOnce()

        #expect(afterFirst == 1)
        #expect(channel.appliedConfigs.count == 1, "later passes must not re-apply")
    }

    /// `StartupPolicy` refuses to touch anything the daemon is already
    /// enforcing — a curve resumed at boot, or manual control in active use.
    @Test("Nothing is applied over a mode the daemon is already enforcing")
    func autoResumeLeavesAnActiveModeAlone() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        channel.statusToReport = HelperStatus(mode: .curve)
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.maintainOnce()

        #expect(channel.appliedConfigs.isEmpty, "the daemon's own curve must not be stomped")
    }

    // MARK: - Applying configs and remembering them

    @Test("A successful curve apply is remembered for the next launch")
    func applyRemembersCurve() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let defaults = makeDefaults()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: defaults)

        await manager.apply(FanConfig.curve(.cold, persists: false))

        #expect(defaults.data(forKey: "lastCurveConfig") != nil)
        #expect(defaults.string(forKey: "startupPreference") == "curve")
    }

    /// A curve the daemon REJECTED must not be stored, or the next launch
    /// silently applies fan control the user was just told had failed.
    @Test("A rejected apply is not remembered")
    func rejectedApplyIsNotRemembered() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        channel.failure = IceCubeError.smcKeyNotFound(key: "F0Md")
        let defaults = makeDefaults()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: defaults)

        await manager.apply(FanConfig.curve(.cold, persists: false))

        #expect(defaults.data(forKey: "lastCurveConfig") == nil)
        #expect(manager.lastError != nil, "and the user is told")
    }

    /// Manual is watchdogged and must never be what an app launch puts you in,
    /// so it deliberately leaves the stored preference untouched.
    @Test("Manual mode never becomes a startup preference")
    func manualIsNotAStartupMode() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let defaults = makeDefaults()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: defaults)

        await manager.applyManual(targets: [0: 4000])

        #expect(defaults.string(forKey: "startupPreference") == nil)
    }

    @Test("Only curve presets carry the keep-running flag")
    func onlyCurvesPersist() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.applyPreset(
            Preset(name: "Cold", kind: .cold, config: .curve(.cold)), persistCurve: true
        )
        #expect(channel.appliedConfigs.last?.persistsWithoutApp == true)
    }

    // MARK: - Turning fan control off

    /// The bug this pins, found by rehearsing a first run on 2026-07-26: turn
    /// fan control off, turn it straight back on, and the daemon sat in auto
    /// with no preset lit. `unregister()` cleared the stored preference — the
    /// "never chose" state, which this project answers with Balanced — but not
    /// the once-per-session latch, so the auto-resume that should have applied
    /// it returned immediately. The user got nothing until they relaunched, in
    /// the exact sequence someone follows when troubleshooting.
    @Test("Turning fan control off and on again re-applies the default curve")
    func unregisterClearsTheAutoResumeLatch() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.maintainOnce() // first connection: applies Balanced
        #expect(channel.appliedConfigs.count == 1)

        await manager.unregister()

        // Re-enable, exactly as the user would.
        registrar.status = .enabled
        channel.statusToReport = HelperStatus(mode: .auto)
        await manager.maintainOnce()

        #expect(
            channel.appliedConfigs.count == 2,
            "re-enabling must put the fans back on a curve, not leave them in auto"
        )
        #expect(channel.appliedConfigs.last?.mode == .curve)
    }

    /// Off has to mean off: a preference left behind would silently resurrect a
    /// curve the user dismissed, next time they turn the feature on.
    @Test("Turning fan control off wipes the stored curve and preference")
    func unregisterIsACleanSlate() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let defaults = makeDefaults()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: defaults)

        await manager.apply(FanConfig.curve(.cold, persists: false))
        #expect(defaults.data(forKey: "lastCurveConfig") != nil)

        await manager.unregister()

        #expect(defaults.data(forKey: "lastCurveConfig") == nil)
        #expect(defaults.string(forKey: "startupPreference") == nil)
        #expect(registrar.unregisterCount == 1)
    }

    /// The daemon cannot work this out for itself: unregistering and rebooting
    /// both arrive as SIGTERM, and shutdown deliberately KEEPS the persisted
    /// curve so a restart does not destroy the boot promise. Only the app knows
    /// the user asked to stop.
    @Test("Turning off tells the daemon to release the fans first")
    func unregisterTellsTheDaemonFirst() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        await manager.maintainOnce() // establish the connection

        await manager.unregister()

        #expect(channel.setAllAutoCount == 1)
        #expect(channel.disconnectCount >= 1)
    }

    /// Rewritten: this used to assert `setAllAutoCount == 0` with the comment
    /// "nothing to tell". But `.disconnected` is a statement about the app's last
    /// status refresh, not about whether a daemon exists — the mach service is
    /// demand-launched, so a *registered* daemon is reachable whether or not the
    /// app currently holds a connection.
    ///
    /// And `setAllAuto` is the ONLY thing that clears the daemon's persisted
    /// curve: it routes to `revertEverything(clearsPersistence: true)`, while
    /// `shutdown()` deliberately KEEPS the file so a reboot cannot destroy the
    /// boot promise. Skipping the call therefore left a boot promise on disk
    /// through an uninstall, for the next install to resume — with no preset lit,
    /// because `forgetEverything()` had just wiped the app's half of it.
    @Test("Turning off while disconnected still tells a registered daemon to let go")
    func unregisterWithoutConnection() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.unregister() // never connected

        #expect(channel.setAllAutoCount == 1, "a registered daemon is reachable on demand")
        #expect(registrar.unregisterCount == 1, "and the service still goes away")
    }

    /// The other half: "reachable on demand" is not "always worth calling". With
    /// no daemon registered there is genuinely nothing to tell, and
    /// `HelperClient.call` has no timeout — so an XPC send into a service that
    /// does not exist is the one thing that could wedge the uninstall.
    @Test("Turning off with no daemon registered does not try to talk to one")
    func unregisterWithNoDaemonRegistered() async {
        let registrar = FakeRegistrar()
        registrar.status = .notFound
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.unregister()

        #expect(channel.setAllAutoCount == 0, "nothing to tell — there is no daemon")
    }

    // MARK: - Write-path self-test

    @Test("The check reports what the daemon found and remembers it for the UI")
    func selfTestSurfacesTheVerdict() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        await manager.maintainOnce()

        let report = await manager.runWritePathSelfTest()

        #expect(report?.verdict == .verified)
        #expect(manager.writePathReport?.unlockBranch == "direct")
        #expect(manager.isSelfTesting == false, "the progress flag is always cleared")
    }

    @Test("The check does nothing while the daemon is unreachable")
    func selfTestRequiresAConnection() async {
        let registrar = FakeRegistrar()
        registrar.status = .notRegistered
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        let report = await manager.runWritePathSelfTest()

        #expect(report == nil)
        #expect(channel.selfTestCount == 0)
    }

    /// PLAN.md §7 lists this as the mitigation for "Apple changes SMC/BTM
    /// behaviour in a new macOS" — point updates have broken fan-control write
    /// paths before (15.3/15.4). The alternative is the user finding out because
    /// their Mac quietly runs hot.
    @Test("A macOS update triggers one automatic re-check")
    func selfTestRunsAfterAnOSChange() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let defaults = makeDefaults()
        defaults.set("25.0.0", forKey: "writePathVerifiedOS") // verified on an older macOS
        let manager = makeManager(registrar: registrar, channel: channel, defaults: defaults)

        await manager.maintainOnce()

        #expect(channel.selfTestCount == 1, "the OS moved, so the verdict is re-earned")
        #expect(defaults.string(forKey: "writePathVerifiedOS") == HostInfo.osVersion())
    }

    /// The counterweight: exercising the fan write path on every launch is wear
    /// and noise for an answer that almost never changes.
    @Test("An unchanged macOS is not re-checked")
    func selfTestSkippedWhenOSUnchanged() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let defaults = makeDefaults()
        defaults.set(HostInfo.osVersion(), forKey: "writePathVerifiedOS")
        let manager = makeManager(registrar: registrar, channel: channel, defaults: defaults)

        await manager.maintainOnce()
        await manager.maintainOnce()

        #expect(channel.selfTestCount == 0)
    }

    /// A failed check must not be recorded as a pass, or the automatic re-check
    /// would never fire again on a machine that actually needs looking at.
    @Test("A machine that fails the check is not remembered as verified")
    func failedSelfTestIsNotRecorded() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        channel.writePathToReport = WritePathReport(verdict: .rejected, detail: "refused")
        let defaults = makeDefaults()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: defaults)
        await manager.maintainOnce()

        _ = await manager.runWritePathSelfTest()

        #expect(manager.writePathReport?.verdict == .rejected)
        #expect(defaults.string(forKey: "writePathVerifiedOS") == nil, "not a pass")
        #expect(manager.writePathReport?.isWorthReporting == true)
    }

    // MARK: - Preset quick-switch (⌥-click)

    private var cycle: [Preset] {
        PresetStore.builtins
    }

    @Test("The quick-switch advances to the next preset and sends it")
    func quickSwitchAdvances() async {
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        await manager.maintainOnce()
        await manager.applyPreset(PresetStore.builtins[0], persistCurve: false) // Quiet
        let before = channel.appliedConfigs.count

        let applied = await manager.cyclePreset(in: cycle)

        #expect(applied?.kind == .balanced)
        #expect(channel.appliedConfigs.count == before + 1)
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.balanced)
    }

    /// The gesture has no UI of its own, so a click that silently does nothing is
    /// indistinguishable from the modifier not being detected. It must decline
    /// loudly (a log line) and tell the caller, not pretend.
    @Test("The quick-switch declines while the daemon is unreachable")
    func quickSwitchDeclinesWhenDisconnected() async {
        let registrar = FakeRegistrar(); registrar.status = .notRegistered
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        let before = channel.appliedConfigs.count

        let applied = await manager.cyclePreset(in: cycle)

        #expect(applied == nil)
        #expect(channel.appliedConfigs.count == before, "nothing may be sent while disconnected")
    }

    /// The gate, tested directly. Holding a real self-test open with a
    /// continuation and observing the manager mid-flight hung the test runner
    /// for ten minutes — the host-less-bundle hazard `project.yml` documents.
    @Test(
        "The quick-switch is refused when the daemon cannot act on it",
        arguments: [
            (connected: false, selfTesting: false, refused: true),
            (connected: false, selfTesting: true, refused: true),
            (connected: true, selfTesting: true, refused: true),
            (connected: true, selfTesting: false, refused: false),
        ]
    )
    func quickSwitchGate(_ c: (connected: Bool, selfTesting: Bool, refused: Bool)) {
        let refusal = HelperManager.quickSwitchRefusal(
            connected: c.connected, isSelfTesting: c.selfTesting
        )
        #expect((refusal != nil) == c.refused)
    }

    /// Every refusal must carry a reason the log can name. "declined" on its own
    /// is the shape of message this project has already been burned by twice.
    @Test("A refusal always says why")
    func refusalNamesItsReason() {
        #expect(
            HelperManager.quickSwitchRefusal(connected: false, isSelfTesting: false)
                == .daemonUnreachable
        )
        #expect(
            HelperManager.quickSwitchRefusal(connected: true, isSelfTesting: true)
                == .selfTestInFlight
        )
    }

    @Test("The quick-switch honours the injected keep-running preference")
    func quickSwitchHonoursPersistPreference() async {
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let channel = FakeChannel()
        let defaults = makeDefaults()
        defaults.set(true, forKey: "persistCurve")
        let manager = makeManager(registrar: registrar, channel: channel, defaults: defaults)
        await manager.maintainOnce()

        _ = await manager.cyclePreset(in: cycle)

        #expect(channel.appliedConfigs.last?.persistsWithoutApp == true)
    }

    /// Four clicks from a known start must come back to it, through the real
    /// apply path rather than only in `PresetCycle`'s arithmetic.
    @Test("Cycling the full length through the daemon returns to the start")
    func quickSwitchFullLoop() async {
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        await manager.maintainOnce()
        await manager.applyPreset(PresetStore.builtins[0], persistCurve: false) // Quiet

        var names: [String] = []
        for _ in 0 ..< cycle.count {
            await names.append(manager.cyclePreset(in: cycle)?.name ?? "declined")
        }

        #expect(names == ["Balanced", "Cold", "Max", "Quiet"])
    }

    // MARK: - Power-aware profiles

    private func enabledRule() -> PowerProfilePolicy.Rule {
        PowerProfilePolicy.Rule(isEnabled: true, onBattery: .quiet, onWall: .cold)
    }

    @Test("Unplugging switches to the battery preset")
    func unplugAppliesBatteryPreset() async {
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        manager.powerRule = enabledRule()
        await manager.maintainOnce()
        let before = channel.appliedConfigs.count

        await manager.powerSourceChanged(to: .battery)

        #expect(channel.appliedConfigs.count == before + 1)
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.quiet)
    }

    /// THE test for this feature. Between two power changes the user is free to
    /// pick whatever they like, and nothing may take it away — which is only
    /// true because the rule responds to transitions instead of enforcing a
    /// state. Ice Cube has shipped the enforcing kind of default before.
    @Test("A preset chosen by hand survives while the power source is unchanged")
    func manualPickSurvivesBetweenTransitions() async {
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        manager.powerRule = enabledRule()
        await manager.maintainOnce()

        await manager.powerSourceChanged(to: .battery) // → Quiet
        // The user disagrees and picks Max while still unplugged.
        await manager.applyPreset(
            Preset(name: "Max", kind: .max, config: .curve(.max)), persistCurve: false
        )
        let afterManualPick = channel.appliedConfigs.count

        // Anything that re-evaluates while still on battery must change nothing.
        for _ in 0 ..< 5 {
            await manager.powerSourceChanged(to: .battery)
        }

        #expect(channel.appliedConfigs.count == afterManualPick, "the manual pick was overridden")
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.max)
    }

    @Test("A disabled rule ignores the charger entirely")
    func disabledRuleIgnoresPowerChanges() async {
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        await manager.maintainOnce()
        let before = channel.appliedConfigs.count

        await manager.powerSourceChanged(to: .battery)
        await manager.powerSourceChanged(to: .wall)

        #expect(channel.appliedConfigs.count == before, "off means off")
    }

    @Test("Plugging back in switches to the wall preset")
    func replugAppliesWallPreset() async {
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        manager.powerRule = enabledRule()
        await manager.maintainOnce()

        await manager.powerSourceChanged(to: .battery)
        await manager.powerSourceChanged(to: .wall)

        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.cold)
    }

    /// The poll in `maintain()` guarantees a charger change is *noticed*; this
    /// wiring is what makes it noticed **now** instead of up to 5 s later. It is
    /// asserted separately because it has already been shipped broken once: the
    /// first version of the feature had only the instant path, it silently never
    /// fired, and nothing failed.
    @Test("start() wires the instant path instead of leaving it to the 5 s poll")
    func startWiresTheInstantPath() {
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let power = FakePowerSource(.wall)
        let manager = makeManager(
            registrar: registrar, channel: FakeChannel(), defaults: makeDefaults(), power: power
        )

        manager.start()

        #expect(power.startCalls == 1, "the monitor was never told to begin observing")
        #expect(power.onChange != nil, "nothing is listening — detection would wait for the poll")
    }

    /// A rule that silently failed to persist would read as "off" next launch,
    /// quietly abandoning something the user configured.
    @Test("The rule survives a manager rebuild")
    func rulePersists() {
        let defaults = makeDefaults()
        let first = makeManager(
            registrar: FakeRegistrar(), channel: FakeChannel(), defaults: defaults
        )
        first.powerRule = enabledRule()

        let second = makeManager(
            registrar: FakeRegistrar(), channel: FakeChannel(), defaults: defaults
        )
        #expect(second.powerRule == enabledRule())
    }

    @Test("Nothing is configured until the user turns it on")
    func defaultRuleIsOff() {
        let manager = makeManager(
            registrar: FakeRegistrar(), channel: FakeChannel(), defaults: makeDefaults()
        )
        #expect(manager.powerRule.isEnabled == false)
    }

    // MARK: - Away-aware profiles

    private func awayRule() -> PresencePolicy.Rule {
        PresencePolicy.Rule(isEnabled: true, whileAway: .cold)
    }

    /// A connected manager running Balanced, with the away rule on.
    private func awayFixture(
        presence: FakePresence = FakePresence()
    ) async -> (HelperManager, FakeChannel) {
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(
            registrar: registrar, channel: channel, defaults: makeDefaults(), presence: presence
        )
        manager.presenceRule = awayRule()
        await manager.maintainOnce()
        await manager.applyPreset(PresetStore.builtins[1], persistCurve: false) // Balanced
        return (manager, channel)
    }

    @Test("Leaving switches to the away preset")
    func leavingAppliesAwayPreset() async {
        let (manager, channel) = await awayFixture()
        let before = channel.appliedConfigs.count

        await manager.presenceChanged(to: .away)

        #expect(channel.appliedConfigs.count == before + 1)
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.cold)
    }

    @Test("Coming back puts the previous preset back")
    func returningRestores() async {
        let (manager, channel) = await awayFixture()

        await manager.presenceChanged(to: .away)
        await manager.presenceChanged(to: .present)

        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.balanced)
        #expect(manager.lastAwayTrip?.outcome == "put Balanced back")
    }

    /// THE test for the interaction the Settings caption promises: while the
    /// user is away the away preset holds, and a charger change becomes what
    /// they come back to rather than taking over now.
    @Test("A power change while away is noted for the return, not applied")
    func powerChangeWhileAwayIsDeferredToReturn() async {
        let (manager, channel) = await awayFixture()
        manager.powerRule = PowerProfilePolicy.Rule(isEnabled: true, onBattery: .quiet, onWall: .max)
        await manager.powerSourceChanged(to: .wall) // first decision: applies Max
        await manager.applyPreset(PresetStore.builtins[1], persistCurve: false) // user picks Balanced

        await manager.presenceChanged(to: .away)
        let afterLeaving = channel.appliedConfigs.count
        await manager.powerSourceChanged(to: .battery)

        #expect(channel.appliedConfigs.count == afterLeaving, "the away preset must keep holding")
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.cold)

        await manager.presenceChanged(to: .present)
        #expect(
            channel.appliedConfigs.last?.sharedCurve == FanCurve.quiet,
            "the power rule's pick is what you come back to"
        )
    }

    @Test("Coming back leaves alone a preset the user picked in the meantime")
    func returningYieldsToHandPick() async {
        let (manager, channel) = await awayFixture()

        await manager.presenceChanged(to: .away)
        await manager.applyPreset(PresetStore.builtins[3], persistCurve: false) // Max, by hand
        let afterHandPick = channel.appliedConfigs.count
        await manager.presenceChanged(to: .present)

        #expect(channel.appliedConfigs.count == afterHandPick)
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.max)
        #expect(manager.lastAwayTrip?.outcome?.hasPrefix("left Max alone") == true)
    }

    @Test("Polling while away or present changes nothing")
    func pollingIsInert() async {
        let (manager, channel) = await awayFixture()
        await manager.presenceChanged(to: .away)
        let whileAway = channel.appliedConfigs.count
        for _ in 0 ..< 5 {
            await manager.presenceChanged(to: .away)
        }
        #expect(channel.appliedConfigs.count == whileAway)

        await manager.presenceChanged(to: .present)
        let whileBack = channel.appliedConfigs.count
        for _ in 0 ..< 5 {
            await manager.presenceChanged(to: .present)
        }
        #expect(channel.appliedConfigs.count == whileBack)
    }

    @Test("A disabled away rule ignores the lock screen entirely")
    func disabledAwayRuleDoesNothing() async {
        let (manager, channel) = await awayFixture()
        manager.presenceRule = .suggested
        let before = channel.appliedConfigs.count

        await manager.presenceChanged(to: .away)
        await manager.presenceChanged(to: .present)

        #expect(channel.appliedConfigs.count == before, "off means off")
    }

    @Test("Manual mode is never taken over by the away rule")
    func manualIsLeftAlone() async {
        let (manager, channel) = await awayFixture()
        await manager.applyManual(targets: [0: 3000, 1: 3000])
        let before = channel.appliedConfigs.count

        await manager.presenceChanged(to: .away)
        await manager.presenceChanged(to: .present)

        #expect(channel.appliedConfigs.count == before)
        #expect(channel.appliedConfigs.last?.mode == .manual)
    }

    /// The instant path arrives before the reconnect on a wake. Left
    /// unconsumed, the next pass — which reconnects first and polls presence
    /// last — must act on it.
    @Test("A departure found while disconnected is retried once the daemon is back")
    func departureRetriesAfterReconnect() async {
        let presence = FakePresence()
        let (manager, channel) = await awayFixture(presence: presence)
        // What an XPC invalidation looks like from the app: the client drops
        // the connection and tells the manager so through `onDisconnect`.
        channel.disconnect()
        channel.onDisconnect?()
        #expect(manager.connection == .disconnected)
        let before = channel.appliedConfigs.count

        presence.current = .away
        await manager.presenceChanged(to: .away) // the notification, too early
        #expect(channel.appliedConfigs.count == before, "nothing can be sent while disconnected")

        await manager.maintainOnce() // reconnects, then polls presence
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.cold, "the transition was consumed too early")
    }

    /// The mirror image, and the one a mutation found untested: a return that
    /// arrives while the daemon is unreachable must not be consumed either —
    /// the memory of what to hand back has to survive until the reconnect.
    @Test("A return found while disconnected is retried once the daemon is back")
    func returnRetriesAfterReconnect() async {
        let presence = FakePresence()
        let (manager, channel) = await awayFixture(presence: presence)
        presence.current = .away
        await manager.presenceChanged(to: .away)
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.cold)
        channel.disconnect()
        channel.onDisconnect?()
        let before = channel.appliedConfigs.count

        presence.current = .present
        await manager.presenceChanged(to: .present) // the unlock, too early
        #expect(channel.appliedConfigs.count == before, "nothing can be sent while disconnected")

        await manager.maintainOnce() // reconnects, then polls presence
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.balanced, "the hand-back was lost")
        #expect(manager.lastAwayTrip?.outcome == "put Balanced back")
    }

    /// The notification is the fast path; the 5 s pass is the guarantee.
    @Test("The maintenance pass notices a departure the notification missed")
    func pollNoticesDeparture() async {
        let presence = FakePresence()
        let (manager, channel) = await awayFixture(presence: presence)

        presence.current = .away
        await manager.maintainOnce()
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.cold)

        presence.current = .present
        await manager.maintainOnce()
        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.balanced)
    }

    /// The away preset is borrowed, not chosen. If it were remembered as the
    /// user's last curve, a crash while away would relaunch into it.
    @Test("The away preset is not remembered as the user's choice")
    func awayPresetIsNotRemembered() async {
        let defaults = makeDefaults()
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: defaults)
        manager.presenceRule = awayRule()
        await manager.maintainOnce()
        await manager.applyPreset(PresetStore.builtins[1], persistCurve: false) // Balanced

        await manager.presenceChanged(to: .away)

        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.cold, "the fans did move")
        #expect(
            FanControlMemory(defaults: defaults).lastCurve?.sharedCurve == FanCurve.balanced,
            "but the remembered curve is still the user's"
        )
    }

    /// A daemon that refuses the away preset outright must not arm a return
    /// that would restore over a choice it never displaced.
    @Test("A refused departure leaves nothing to restore")
    func refusedDepartureRestoresNothing() async {
        let (manager, channel) = await awayFixture()
        channel.applyFailure = FakeChannel.NotConnected()
        await manager.presenceChanged(to: .away)
        channel.applyFailure = nil
        let before = channel.appliedConfigs.count

        await manager.presenceChanged(to: .present)

        #expect(channel.appliedConfigs.count == before)
        #expect(manager.lastAwayTrip?.outcome?.hasPrefix("could not switch") == true)
    }

    @Test("start() wires the presence instant path")
    func startWiresPresence() {
        let registrar = FakeRegistrar(); registrar.status = .enabled
        let presence = FakePresence()
        let manager = makeManager(
            registrar: registrar, channel: FakeChannel(), defaults: makeDefaults(), presence: presence
        )

        manager.start()

        #expect(presence.startCalls == 1, "the monitor was never told to begin observing")
        #expect(presence.onChange != nil, "nothing is listening — detection would wait for the poll")
    }

    @Test("The away rule survives a manager rebuild")
    func awayRulePersists() {
        let defaults = makeDefaults()
        let first = makeManager(registrar: FakeRegistrar(), channel: FakeChannel(), defaults: defaults)
        first.presenceRule = awayRule()

        let second = makeManager(registrar: FakeRegistrar(), channel: FakeChannel(), defaults: defaults)
        #expect(second.presenceRule == awayRule())
        #expect(
            makeManager(registrar: FakeRegistrar(), channel: FakeChannel(), defaults: makeDefaults())
                .presenceRule.isEnabled == false,
            "nothing is configured until the user turns it on"
        )
    }

    // MARK: - Errors

    @Test("An acknowledged error can be cleared")
    func clearError() {
        let registrar = FakeRegistrar()
        let manager = makeManager(
            registrar: registrar, channel: FakeChannel(), defaults: makeDefaults(),
            blocker: "nope"
        )
        manager.register()
        #expect(manager.lastError != nil)
        manager.clearError()
        #expect(manager.lastError == nil)
    }

    @Test("Opening approval settings goes through the service seam")
    func openApprovalSettings() {
        let registrar = FakeRegistrar()
        let manager = makeManager(
            registrar: registrar, channel: FakeChannel(), defaults: makeDefaults()
        )
        manager.openApprovalSettings()
        #expect(registrar.openedSettings == 1)
    }
}

/// The daemon has a third answer besides yes and no: it can decline a write it
/// would be wrong to make, because the Mac is parked for sleep. Collapsing that
/// into a failure is what put `The operation couldn't be completed.
/// (IceCubeKit.IceCubeError error 7.)` in the popover after a lid close, in
/// orange, permanently, until an unrelated success happened to clear it.
///
/// Two things had to be true for that to be the whole bug, and both are pinned
/// here: the user must not be alarmed, and the config must not be lost.
@MainActor
@Suite("HelperManager — a config the Mac was too asleep to take")
struct DeferredApplyTests {
    /// Copies of the factories in `HelperManagerTests`, which are private to
    /// that suite.
    private func makeDefaults() -> MemoryDefaults {
        MemoryDefaults()
    }

    private func makeManager(
        registrar: FakeRegistrar, channel: FakeChannel, defaults: MemoryDefaults
    ) -> HelperManager {
        HelperManager(
            service: RegistrarProxy(inner: registrar),
            client: channel,
            defaults: defaults,
            blocker: { nil },
            powerSource: FakePowerSource()
        )
    }

    private func asleep() -> Error {
        WireError.wire(IceCubeError.systemAsleep)
    }

    private func coldCurve() -> FanConfig {
        FanConfig(mode: .curve, persistsWithoutApp: false, sharedCurve: .cold)
    }

    @Test("A config refused because the Mac is asleep is not shown as an error")
    func sleepRefusalIsNotAnError() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        channel.applyFailure = asleep()
        let defaults = makeDefaults()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: defaults)

        await manager.apply(coldCurve())

        #expect(manager.lastError == nil, "nothing has gone wrong")
        #expect(manager.deferralNotice != nil, "but the user is told something is pending")
        #expect(manager.lastAppliedConfig == nil, "we did not apply it")
        #expect(defaults.data(forKey: "lastCurveConfig") == nil, "and must not remember it as applied")
    }

    /// The functional half. Nothing else in the app re-sends a config after a
    /// wake, so without the queue a curve refused during a park is simply never
    /// applied — the fans keep running whatever they were on.
    @Test("The refused config is re-sent once the Mac is awake")
    func deferredConfigIsResentOnWake() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        channel.applyFailure = asleep()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.apply(coldCurve())
        #expect(channel.appliedConfigs.isEmpty)

        channel.applyFailure = nil // the Mac wakes
        await manager.maintainOnce()

        #expect(channel.appliedConfigs.last?.sharedCurve == FanCurve.cold, "re-sent without being asked")
        #expect(manager.deferralNotice == nil, "and the notice clears itself")
        #expect(manager.lastAppliedConfig != nil)
    }

    /// `FanControlSection` shows `lastError` when non-nil and only *otherwise*
    /// falls through to `deferralNotice`. So a failure followed by a lid close
    /// used to keep a red error on screen and suppress "Waking up — your fan
    /// settings will take effect in a moment", which is the one message the
    /// deferral path exists to deliver.
    @Test("A deferral clears an older error instead of letting it hide the wake notice")
    func deferralClearsAStaleError() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        // First a genuine failure, which the user should see.
        channel.applyFailure = WireError.wire(IceCubeError.smcKeyNotFound(key: "F0Md"))
        await manager.apply(coldCurve())
        #expect(manager.lastError != nil, "precondition: a real failure is on screen")

        // Then the lid closes and the next command is merely deferred.
        channel.applyFailure = asleep()
        await manager.apply(coldCurve())

        #expect(manager.lastError == nil, "a deferral is not a failure, and must not leave one standing")
        #expect(manager.deferralNotice != nil, "the wake notice is what the user needs to read now")
    }

    /// `StatusItemController.quickSwitch` flashes the returned preset's name in
    /// the menu bar. Keying that on `lastError` meant a preset merely *queued*
    /// for a sleeping Mac was announced as a switch the fans never made.
    @Test("A quick-switch deferred until wake is not reported as a switch")
    func quickSwitchDeferredUntilWakeReportsNothing() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        // Connect FIRST. `cyclePreset` declines outright while the daemon is
        // unreachable, so without this the test would pass on the refusal guard
        // and never reach the line it is meant to pin.
        await manager.maintainOnce()
        #expect(
            manager.connection == .connected(version: HelperConstants.protocolVersion),
            "precondition: the quick-switch is allowed to proceed"
        )

        channel.applyFailure = asleep()
        let switched = await manager.cyclePreset(in: PresetStore.builtins)

        #expect(manager.lastError == nil, "and it is genuinely not an error")
        #expect(switched == nil, "but nothing reached the fans, so nothing may be announced")
    }

    /// The other half: a guard that reports nothing for everything is not a fix.
    @Test("A quick-switch that lands is still reported")
    func quickSwitchThatLandsIsReported() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())
        await manager.maintainOnce()
        #expect(
            manager.connection == .connected(version: HelperConstants.protocolVersion),
            "precondition: the quick-switch is allowed to proceed"
        )

        let switched = await manager.cyclePreset(in: PresetStore.builtins)

        #expect(switched != nil, "a preset that reached the fans must still be announced")
    }

    @Test("A genuine failure is still reported, and never re-sent behind the user's back")
    func realFailuresAreNotDeferred() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        channel.applyFailure = WireError.wire(IceCubeError.smcKeyNotFound(key: "F0Md"))
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.apply(coldCurve())

        #expect(manager.lastError != nil, "a real rejection is the user's business")
        #expect(manager.deferralNotice == nil, "and is not queued for a retry loop")
        #expect(manager.deferredConfig == nil)
    }

    /// Now that the message survives the wire, this is what the user actually
    /// reads — so it must not name a key, a mode, or a module.
    @Test("A reported failure reads as a sentence, not as a type name")
    func reportedFailuresAreReadable() async {
        let registrar = FakeRegistrar()
        registrar.status = .enabled
        let channel = FakeChannel()
        channel.applyFailure = WireError.wire(IceCubeError.smcKeyNotFound(key: "F0Md"))
        let manager = makeManager(registrar: registrar, channel: channel, defaults: makeDefaults())

        await manager.apply(coldCurve())

        let message = manager.lastError ?? ""
        #expect(message == IceCubeError.smcKeyNotFound(key: "F0Md").errorDescription)
        #expect(!message.contains("IceCubeKit"), "the exact leak from the owner's screenshot")
        #expect(!message.contains("couldn’t be completed"))
    }

    /// Curves come back whenever the Mac does — that is the app. A fixed RPM
    /// set before an overnight sleep is a decision that has expired, and
    /// resurrecting it is the app choosing manual control on the user's behalf.
    @Test("A deferred config is re-sent, unless it is stale manual control")
    func manualDeferralsExpire() {
        let curve = FanConfig(mode: .curve, persistsWithoutApp: false, sharedCurve: .cold)
        let manual = FanConfig(mode: .manual, manualTargets: [0: 4000])
        #expect(HelperManager.shouldResend(curve, waiting: .seconds(60)))
        #expect(HelperManager.shouldResend(curve, waiting: .seconds(21600)), "a curve never expires")
        #expect(HelperManager.shouldResend(manual, waiting: .seconds(10)))
        #expect(!HelperManager.shouldResend(manual, waiting: .seconds(120)), "an old fixed RPM does")
    }

    @Test("The wake notice says what is happening without naming a mechanism")
    func theNoticeSpeaksEnglish() {
        let notice = HelperManager.wakeNotice
        #expect(!notice.isEmpty)
        for jargon in ["daemon", "XPC", "SMC", "curve", "config", "helper", "error"] {
            #expect(!notice.lowercased().contains(jargon.lowercased()), "'\(jargon)' is our word, not theirs")
        }
    }
}
