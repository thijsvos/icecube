// HelperManager.swift — helper lifecycle: SMAppService registration, connection + handshake, heartbeat, status.

import AppKit
import Foundation
import IceCubeKit
import Observation
import os
import ServiceManagement

/// Everything the UI needs to know and do about the helper daemon:
/// registration with launchd (SMAppService), the pinned XPC connection with
/// its version handshake, the 5 s heartbeat that feeds the daemon watchdog,
/// and the daemon's reported status.
///
/// **Constructing one starts nothing.** Call ``start()`` to begin the
/// maintenance loop and the wake observer; the app does that once, and tests
/// drive ``maintainOnce()`` directly instead. This used to happen in `init`,
/// which meant merely *making* a manager talked to launchd and spawned a 5 s
/// timer — and is why this type had no tests at all until 2026-07-27, despite
/// being where two real bugs had already been found by hand.
///
/// The three system seams are injected for the same reason and default to the
/// production wiring, so `HelperManager()` still means the real daemon:
/// ``DaemonRegistering`` (SMAppService), ``HelperChanneling`` (the XPC
/// channel), and `UserDefaults` for the startup preference.
@Observable
final class HelperManager {
    /// Where the helper stands with launchd/Background Task Management.
    enum Registration: Equatable {
        case unknown
        case notRegistered
        /// Registered; the user must approve it in System Settings.
        case requiresApproval
        case enabled
    }

    /// The XPC channel's state, including the version handshake result.
    enum Connection: Equatable {
        case disconnected
        case connected(version: String)
        /// The daemon speaks another protocol version → re-register needed.
        case versionMismatch(helper: String)
    }

    private(set) var registration: Registration = .unknown
    private(set) var connection: Connection = .disconnected
    private(set) var status: HelperStatus?

    /// The daemon's decisions, accumulated past its own 20-entry cap.
    ///
    /// The daemon keeps 20 so `HelperStatus` stays small on the wire; the app
    /// polls every 5 s and merges, so the timeline covers the session rather
    /// than the last few seconds. Merged by `id` — the same decision arrives in
    /// several consecutive status payloads and must appear once.
    ///
    /// In memory only. Persisting it is a follow-up and belongs daemon-side,
    /// where the events are actually generated and where a reboot does not lose
    /// the overnight window that motivates it.
    private(set) var decisions: [DecisionEvent] = []

    /// Seeds a representative timeline when there is no daemon to supply one.
    ///
    /// Simulated mode swaps the SMC *provider*, not the helper — with no
    /// registered daemon there is no `HelperStatus`, so the timeline would be
    /// permanently empty and the feature undemonstrable. CLAUDE.md rule 3 says
    /// every feature must be demonstrable with no root, no helper and no real
    /// SMC, so simulated mode gets a plausible set of the daemon's real
    /// sentences rather than an empty box.
    ///
    /// Only ever called from the simulated composition root; a real install
    /// never synthesises a decision it did not make.
    func seedSimulatedDecisions(now: Date = Date()) {
        let script: [(TimeInterval, String)] = [
            (-540, "all fans auto (daemon start)"),
            (-535, "boot: resuming persisted curve config"),
            (-534, "curve engaged (persists without app: false)"),
            (-300, "guardian: die 78 °C and nothing cooling — driving the fans (built-in curve)"),
            (-240, "guardian: cooled to 61 °C — releasing the fans"),
            (-120, "the Mac is going to sleep — handing the fans back (keeping the curve config)"),
            (-90, "dark wake (0x39 [CDNP]) — the app checked in after a nap, but no display is powered"),
            (-30, "wake: resuming curve control (the system powered on — 0x1F [CDNVA])"),
        ]
        decisions = script.map { DecisionEvent(text: $0.1, date: now.addingTimeInterval($0.0)) }
    }

    /// Session cap. Roughly a day of ordinary activity at the rate the daemon
    /// speaks, and bounded so a long-running app cannot grow without limit.
    private static let decisionHistoryLimit = 500
    private(set) var lastError: String?

    /// A config the daemon declined because the Mac is parked for sleep, held
    /// until it can be re-sent. In memory only: it dies with the app, is never
    /// persisted, and never reaches `StartupPolicy`.
    private(set) var deferredConfig: FanConfig?
    /// When the deferral began, not when it was last retried, so the expiry
    /// below measures the age of the user's request.
    @ObservationIgnored private var deferredSince: ContinuousClock.Instant?
    /// Throttles the deferral log to one line per spell. The daemon now stays
    /// parked across dark wakes rather than unparking on the first heartbeat —
    /// eight minutes in the owner's log where it used to be seconds — so this
    /// 5 s loop can meet the refusal ~96 times in one closed lid where it used
    /// to meet it once. That change is also why this path became visible at
    /// all; it was always here, and always silent.
    @ObservationIgnored private var hasLoggedDeferral = false

    /// What to tell someone looking at the popover while a config waits for the
    /// Mac to finish waking up.
    ///
    /// Deliberately not ``lastError``: nothing has failed, there is nothing for
    /// the user to do, and `SetupModel` turns any non-empty `lastError` into
    /// "fan control is blocked".
    var deferralNotice: String? {
        deferredConfig == nil ? nil : Self.wakeNotice
    }

    /// One sentence, in the register the rest of the app uses — no mode names,
    /// no XPC, no "daemon".
    static let wakeNotice = "Waking up — your fan settings will take effect in a moment."

    /// How long fixed-RPM targets stay worth re-sending.
    ///
    /// Curves have no expiry: bringing a curve back whenever the Mac comes back
    /// is the point of the app. Manual is the watchdogged mode, and
    /// resurrecting a fan speed the user set before an overnight sleep is the
    /// app deciding for them — the spirit of "manual is never the persisted
    /// default", even though nothing here is persisted.
    static let manualDeferralWindow = Duration.seconds(60)

    /// Whether a config that has been waiting `waiting` is still worth sending.
    ///
    /// Pure and static so the rule is testable without a 60-second sleep.
    static func shouldResend(_ config: FanConfig, waiting: Duration) -> Bool {
        config.mode != .manual || waiting <= manualDeferralWindow
    }

    /// Clears a failure the user has acknowledged, so a retry starts from a
    /// clean slate rather than re-showing the previous attempt's message.
    func clearError() {
        lastError = nil
    }

    private let service: any DaemonRegistering
    private let client: any HelperChanneling
    /// Where preferences live. Injected so tests get an isolated suite instead
    /// of scribbling on the developer's own `standard` defaults.
    private let defaults: any KeyValueStore
    /// What the app remembers about fan control between launches.
    private let memory: FanControlMemory
    /// Why registration cannot proceed, or nil.
    ///
    /// A closure because the real answer reads this process's code signature and
    /// bundle path — neither of which says anything useful inside a test bundle.
    /// The logic it wraps is covered by `RegistrationPreflightTests`.
    private let blocker: () -> String?
    /// Where the Mac is drawing power, for ``PowerProfilePolicy``.
    private let powerSource: any PowerSourceObserving
    // `HelperConstants.logSubsystem`, not the literal: under test this resolves
    // to a separate subsystem. These files are compiled into the test bundle, so
    // without it a `swift`/`xcodebuild test` run writes lines like "startup:
    // applying curve config" into the SAME log a real investigation reads —
    // which already cost two misdiagnoses this project.
    private let log = Logger(subsystem: HelperConstants.logSubsystem, category: "xpc")
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    /// The maintenance pass currently in flight, if any. Concurrent callers
    /// join it rather than being dropped — see ``maintainOnce()``.
    @ObservationIgnored private var maintenancePass: Task<Void, Never>?

    /// Defaults are the production wiring, so `HelperManager()` still means
    /// "the real daemon, the real XPC channel, the real preferences".
    // MARK: - Isolation introspection

    /// Whether the XPC channel is a stand-in rather than the real one.
    ///
    /// These three exist for `SimulatedIsolationTests`, which guards the defect
    /// that let a simulated launch drive the owner's real fans. Asserting on
    /// the seam's identity is the only way to prove the property — the manager
    /// deliberately cannot tell the difference in its own logic, and that is
    /// what makes it testable.
    var usesSimulatedChannel: Bool {
        client is SimulatedEnvironment.HelperChannel
    }

    /// Whether launchd registration is a stand-in rather than `SMAppService`.
    var usesSimulatedRegistrar: Bool {
        service is SimulatedEnvironment.Registrar
    }

    /// Whether the power watcher is a stand-in rather than real IOKit.
    var usesSimulatedPowerSource: Bool {
        powerSource is SimulatedEnvironment.PowerSource
    }

    init(
        service: any DaemonRegistering = SMAppServiceRegistrar(),
        client: any HelperChanneling = HelperClient(),
        defaults: any KeyValueStore = UserDefaults.standard,
        blocker: @escaping () -> String? = {
            RegistrationPreflight.blocker(
                teamID: CodesignPinning.currentTeamID(),
                bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path
            )
        },
        powerSource: any PowerSourceObserving = PowerSourceMonitor()
    ) {
        self.service = service
        self.client = client
        self.defaults = defaults
        memory = FanControlMemory(defaults: defaults)
        self.blocker = blocker
        self.powerSource = powerSource
        self.client.onDisconnect = { [weak self] in
            self?.connection = .disconnected
            self?.status = nil
        }
        refreshRegistration()
    }

    /// Starts the background work.
    ///
    /// Separate from `init` on purpose: constructing a manager used to spawn a 5
    /// s timer and a workspace observer, which meant merely *making* one had side
    /// effects — fine for the app, impossible for a test, and the reason this
    /// type had no tests at all until now.
    func start() {
        guard maintenanceTask == nil else { return }
        // Fast path. The 5 s poll in `maintain()` remains the guarantee — see
        // `PowerSourceMonitor` for why this is belt AND braces rather than a
        // failure to choose.
        powerSource.onChange = { [weak self] in
            guard let self else { return }
            Task { await self.powerSourceChanged(to: self.powerSource.current) }
        }
        powerSource.start()
        // One maintenance loop: keeps registration fresh (approval happens in
        // System Settings, outside our process), reconnects when enabled, and
        // drives heartbeat + status while connected.
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.maintainOnce()
                try? await Task.sleep(for: .seconds(HelperConstants.heartbeatInterval))
            }
        }
        // React to system wake immediately instead of waiting for the next 5 s
        // tick — reconnect + reconcile so the popover is correct the moment the
        // lid opens. Purely an app-side responsiveness hook; the daemon and its
        // safety timers are untouched.
        //
        // An AsyncSequence rather than addObserver: ending the `for await`
        // deregisters the observation, so cancelling a stored Task from a
        // nonisolated deinit is all the teardown it needs. The loop body also
        // runs in this type's MainActor isolation, so there is no hop.
        wakeTask = Task { [weak self] in
            let wakes = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didWakeNotification)
            // Element ignored: Notification is not Sendable.
            for await _ in wakes {
                await self?.maintainOnce()
            }
        }
    }

    deinit {
        // Task.cancel() is nonisolated and safe to call from deinit.
        maintenanceTask?.cancel()
        wakeTask?.cancel()
    }

    /// Runs one maintenance pass (reconnect + status + reconcile) and waits for
    /// it, without waiting for the 5 s loop — used on system wake and when the
    /// popover opens so the UI reflects reality promptly.
    ///
    /// Concurrent callers **join** the pass in flight rather than being
    /// dropped. The old `isMaintaining` flag returned early instead, so opening
    /// the popover while the loop's pass was mid-round-trip silently discarded
    /// the refresh — the exact staleness this hook exists to prevent.
    func maintainOnce() async {
        if let pass = maintenancePass {
            return await pass.value
        }
        // The task clears the reference as its OWN last statement, not after
        // `await pass.value` below. Clearing afterwards left a window where the
        // pass had finished but `maintenancePass` still pointed at it, so a
        // caller arriving in that window joined an already-completed task and
        // returned without refreshing anything — silently losing the very
        // refresh this hook exists to force. Because the assignment happens
        // inside the closure, the task's value is not observable until after
        // the reference is nil: a later caller always starts a fresh pass.
        let pass = Task {
            await self.maintain()
            self.maintenancePass = nil
        }
        maintenancePass = pass
        await pass.value
    }

    // MARK: - Registration (SMAppService)

    func refreshRegistration() {
        registration = switch service.status {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        // .notFound is ALSO what a never-registered daemon reports on a fresh
        // machine — it does not mean the bundle is broken. Treat it as "not
        // registered"; a genuinely broken bundle surfaces as a register() error.
        case .notFound: .notRegistered
        @unknown default: .unknown
        }
    }

    /// Why registration cannot succeed right now, or `nil` to go ahead.
    /// See ``RegistrationPreflight`` for why this is checked up front.
    private var registrationBlocker: String? {
        blocker()
    }

    /// Registers the daemon. On a fresh machine this triggers the one-time
    /// System Settings approval flow (XCODE_GUIDE.md §4).
    func register() {
        if let blocker = registrationBlocker {
            lastError = blocker
            log.error("register() blocked: \(blocker, privacy: .public)")
            refreshRegistration()
            return
        }
        do {
            try service.register()
            lastError = nil
        } catch {
            // Report what macOS actually said, including the OSStatus — the old
            // message blamed the app's location for every failure, which sent
            // the reader the wrong way when the real cause was code signing.
            let code = (error as NSError).code
            lastError = "Registration failed (\(code)): \(error.localizedDescription)"
            log.error(
                "register() failed (\(code, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
        refreshRegistration()
    }

    /// - Parameter forgettingIntent: whether to also erase the app's memory of
    ///   the curve the user chose.
    ///
    ///   True for **Turn Off Fan Control**, which is a decision: a clean slate,
    ///   so re-enabling later cannot silently resurrect a curve from a session
    ///   the user has long forgotten.
    ///
    ///   False for **re-registering**, which is a repair. `reregister()` calls
    ///   this as its first act, so wiping here meant every self-heal erased the
    ///   user's curve — and `maintain()` self-heals automatically on
    ///   `.versionMismatch`, which is the *designed* upgrade path
    ///   (`docs/RELEASING.md`). Every app update that bumped `protocolVersion`
    ///   therefore reset the user to Balanced, silently: with `lastCurveConfig`
    ///   and `startupPreference` both gone and `didAutoResume` cleared,
    ///   `StartupPolicy.decide` saw `preference: nil, storedCurve: nil` and fell
    ///   through to the fallback. That fallback exists for a user who has *never
    ///   chosen* — this made someone who had chosen indistinguishable from them.
    ///   The Reinstall button in Settings, which XCODE_GUIDE.md §4.4 tells the
    ///   owner to press after every helper rebuild, did the same thing.
    func unregister(forgettingIntent: Bool = true) async {
        // Tell the daemon to go to auto FIRST, which also clears its persisted
        // curve. Turning fan control off must mean off — not "paused until you
        // turn it on again".
        //
        // The daemon cannot work this out for itself: unregistering and
        // rebooting both arrive as SIGTERM, and shutdown deliberately KEEPS the
        // persisted curve so a restart doesn't destroy the boot promise. Only
        // the app knows the user asked to stop, so only the app can say so.
        // Without this, turning fan control off and on again silently resumed a
        // curve the user had already dismissed — with no preset lit, because
        // the app had no memory of a curve it never sent.
        //
        // Attempted whenever a daemon could exist, rather than only when the last
        // status refresh said `.connected`. The mach service is demand-launched,
        // so a disconnected app can still reach a registered daemon — and gating
        // on `.connected` meant turning fan control off while disconnected (a
        // state the button is fully enabled in) skipped the only call that clears
        // the persisted curve. It then survived the uninstall and was resumed by
        // the next install, with no preset lit because `forgetEverything()` below
        // had wiped the app's side of it.
        // Decided on fresh state: whether a daemon exists is the whole question,
        // and the cached value can predate the user opening this window.
        refreshRegistration()
        var handBackFailed = false
        if registration != .notRegistered {
            if case .failed = await run({ try await self.client.setAllAuto() }) {
                handBackFailed = true
            }
        }
        lastAppliedConfig = nil
        // Turning fan control off must also drop anything queued for the next
        // wake, or the app would resurrect a config the user just switched off.
        deferredConfig = nil
        deferredSince = nil
        if forgettingIntent {
            memory.forgetEverything()
        }
        // Turning the feature off is a clean slate, not a pause. Leaving a
        // preference behind would mean re-enabling later silently resurrects a
        // curve from a session the user has long forgotten.
        // …and the clean slate has to include the once-per-session latch, or
        // the slate is only half wiped.
        //
        // Found by rehearsing a first run (2026-07-26): turn fan control off,
        // turn it straight back on, and the daemon sat in auto with no preset
        // lit. `autoResumeIfNeeded()` runs on every healthy connection, so it
        // DID fire — and returned immediately, because `didAutoResume` had
        // latched at launch. The user is now in the "never chose" state this
        // project promises to answer with the Balanced curve, and instead got
        // nothing until they quit and relaunched. That is the exact sequence
        // someone follows when troubleshooting, which is the worst possible
        // moment to look broken.
        didAutoResume = false

        client.disconnect()
        do {
            try await service.unregister()
            lastError = nil
        } catch {
            lastError = "Unregister failed: \(error.localizedDescription)"
        }
        // Set LAST, because a successful unregister above clears `lastError` —
        // which is how a failed hand-back used to vanish. The daemon being gone
        // and the fans being back are two different facts, and this is the one
        // the user can still act on.
        if handBackFailed {
            lastError = "Fan control is off, but the background service did not confirm handing the "
                + "fans back to macOS. If they stay at one speed, restart your Mac."
        }
        refreshRegistration()
    }

    /// True while a re-register is in flight, so the UI can show progress and
    /// disable the button instead of flashing a misleading "not registered".
    private(set) var isReregistering = false

    /// The #1 dev trap: after a rebuild, launchd may still run the OLD helper
    /// copy. Unregister + register forces the fresh binary (XCODE_GUIDE §4.4).
    ///
    /// SMAppService needs launchd to finish dropping the old daemon before it
    /// will accept a fresh registration — registering too soon silently leaves
    /// the status at `.notRegistered` (the "click Re-register twice" bug). We
    /// retry `register()` with a short backoff so a single click does the whole
    /// job, and only surface an error once the retries are exhausted.
    func reregister() async {
        // SAFETY-OF-SETUP: never tear down a working registration we already
        // know we cannot restore. Re-register is unregister-then-register, so a
        // register that was always going to fail (unsigned build, wrong
        // location) would leave the user with no helper and no fan control —
        // strictly worse than before they clicked, and for a reason the old
        // error message actively misdirected them about.
        if let blocker = registrationBlocker {
            lastError = blocker
            log.error("reregister() refused: \(blocker, privacy: .public)")
            return
        }
        isReregistering = true
        defer { isReregistering = false }
        // A repair, not a decision — so the user's chosen curve survives it.
        // See `unregister(forgettingIntent:)` for what wiping it here cost.
        await unregister(forgettingIntent: false)
        // An unregister hiccup is not final — the retries below may still
        // succeed, so it must not be shown as a failure yet.
        lastError = nil

        // Only the LAST attempt's failure is real. Publishing each one flashed
        // "Fan control can't start" in the setup window for a fraction of a
        // second on the way to succeeding — the retry loop exists precisely
        // because the first attempt usually fails (launchd needs a moment to
        // drop the old job), so its failure is expected, not newsworthy.
        var lastAttemptError: String?
        for attempt in 0 ..< 6 {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 300 : 500))
            register()
            // register() refreshes `registration`; anything past notRegistered
            // (requiresApproval or enabled) means launchd accepted the new job.
            if registration != .notRegistered {
                lastError = nil
                return
            }
            lastAttemptError = lastError
            lastError = nil
        }
        lastError = lastAttemptError
            ?? "Ice Cube couldn’t finish updating. Try again in a moment."
    }

    func openApprovalSettings() {
        service.openSettings()
    }

    // MARK: - Fan control commands

    /// The last config this app sent (drives preset highlighting; the
    /// daemon's status remains the truth for what is actually enforced).
    private(set) var lastAppliedConfig: FanConfig?

    /// Guards the once-per-session auto-resume of the last curve on launch.
    @ObservationIgnored private var didAutoResume = false

    @discardableResult
    func apply(_ config: FanConfig) async -> CommandOutcome {
        let outcome = await run {
            try await self.client.apply(config)
            self.lastAppliedConfig = config
        }
        switch outcome {
        case .deferredUntilWake:
            // Held, not dropped. Nothing else in the app re-sends a config
            // after wake — `autoResumeIfNeeded` latches once per session, and
            // `reconcileHighlight` moves the app's label to match the daemon
            // rather than the other way round — so without this queue a curve
            // refused during a park is simply never applied again until the
            // user happens to click a preset.
            if deferredConfig != config { // assigned only on change: no view churn
                deferredConfig = config
                deferredSince = ContinuousClock.now
            }
            return outcome
        case .failed:
            // A real rejection retires the queue: the user has been told, and
            // re-sending something the daemon refused on its merits would loop.
            deferredConfig = nil
            deferredSince = nil
            return outcome
        case .ok:
            deferredConfig = nil
            deferredSince = nil
        }
        // Remember a curve profile so a later launch can resume it; a
        // deliberate Auto forgets it (the user wants macOS in control).
        //
        // Only on SUCCESS, and a deferral is not success. This write used to
        // run unconditionally, outside the error handling above — so a curve
        // the daemon REJECTED (bad config, or the connection dropping mid-call)
        // was still stored, and `autoResumeIfNeeded()` silently applied it on
        // the next launch. The user would get fan control they never
        // successfully engaged, resumed without any interaction, after being
        // shown an error saying it failed.
        memory.remember(applied: config)
        return .ok
    }

    /// Re-sends a config the daemon declined while the Mac was parked.
    ///
    /// Cheap by construction: `DaemonCore.apply` refuses at its first guard
    /// while parked, writing nothing and touching no SMC, so retrying every
    /// 5 s through a long park costs one XPC round trip per pass.
    private func retryDeferredApply() async {
        guard let config = deferredConfig, let since = deferredSince else { return }
        guard Self.shouldResend(config, waiting: ContinuousClock.now - since) else {
            log.notice("deferred \(config.mode.rawValue, privacy: .public) config expired before the Mac woke")
            deferredConfig = nil
            deferredSince = nil
            return
        }
        // `apply` re-queues it if the Mac is still parked and clears it when it
        // lands, so this needs no state of its own.
        await apply(config)
    }

    func applyManual(targets: [Int: Double]) async {
        await apply(FanConfig(mode: .manual, manualTargets: targets))
    }

    /// Applies a preset, honouring the app-wide "keep running" setting.
    ///
    /// One place owns the rule that **only curve mode may persist without the
    /// app** — it used to be copied verbatim into the popover's preset row and
    /// the Settings picker, which is one copy too many for a safety-adjacent
    /// rule.
    func applyPreset(_ preset: Preset, persistCurve: Bool) async {
        var config = preset.config
        if config.mode == .curve {
            config.persistsWithoutApp = persistCurve
        }
        // Timestamped either side of the call so click-to-command latency can be
        // measured from the log. Without this, the daemon's own timestamps
        // cannot be told apart from the user's time between two clicks — which
        // is exactly the ambiguity that made "is it slow?" unanswerable.
        let started = ContinuousClock.now
        log.notice("preset: sending \(preset.name, privacy: .public)")
        let outcome = await apply(config)
        let ms = (ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000
        // Report what HAPPENED, not merely that we got here. This line used to
        // say "applied" whatever came back, so a preset the daemon refused —
        // because the Mac was parked for sleep, or because the connection was
        // not up — logged exactly like one that reached the fans. Caught with a
        // disconnected app logging "Balanced applied in 2 ms" while the daemon
        // recorded nothing at all. A daemon whose every write must be auditable
        // cannot have an app that narrates writes it never made; the same
        // mistake is what protocol v19 exists to fix on the other side.
        switch outcome {
        case .ok:
            log.notice("preset: \(preset.name, privacy: .public) applied in \(ms, privacy: .public) ms")
        case .deferredUntilWake:
            log.notice(
                "preset: \(preset.name, privacy: .public) held — the Mac is asleep; it will be sent on wake"
            )
        case .failed:
            log.error("preset: \(preset.name, privacy: .public) was refused after \(ms, privacy: .public) ms")
        }
    }

    /// The app-wide "keep the curve running when I quit" preference.
    ///
    /// Reads the **injected** suite. `powerSourceChanged(to:)` used to reach for
    /// `UserDefaults.standard` here instead, which quietly undid the point of
    /// injecting it: under test that read the developer's own preference, so
    /// the power rule's assertions depended on a setting outside the test.
    /// Why a quick-switch was declined, or nil when it may proceed.
    ///
    /// Pure and static so the rule can be tested directly. The obvious
    /// alternative — hold a self-test open with a continuation and observe the
    /// manager mid-flight — was tried and **hung the test runner for ten
    /// minutes**, which is precisely the host-less-bundle hazard `project.yml`
    /// already documents. Extracting the decision costs one function and needs
    /// no concurrency at all.
    enum QuickSwitchRefusal: String {
        case daemonUnreachable = "the daemon is unreachable"
        /// A self-test drives the fans directly and restores the interrupted
        /// config when it finishes (PLAN.md §4.3.6). A preset landing mid-test
        /// would be undone a moment later by that restore — which reads to the
        /// user as the click being ignored, after the fans have moved twice.
        case selfTestInFlight = "a self-test holds the fans"
    }

    static func quickSwitchRefusal(connected: Bool, isSelfTesting: Bool) -> QuickSwitchRefusal? {
        if !connected {
            return .daemonUnreachable
        }
        if isSelfTesting {
            return .selfTestInFlight
        }
        return nil
    }

    /// Switches to the next preset in `cycle` — the ⌥-click quick-switch
    /// (PLAN.md §1.1).
    ///
    /// Goes through ``applyPreset(_:persistCurve:)`` rather than `apply` so the
    /// gesture cannot become a second path with its own idea of the persist
    /// rule; it is the same call the popover's buttons make.
    ///
    /// - Returns: the preset applied, or `nil` when the gesture was declined —
    ///   which is not a failure. There is genuinely nothing to switch to while
    ///   the daemon is unreachable or a write-path self-test holds the fans, and
    ///   the caller uses nil to decide whether to say anything to the user.
    @discardableResult
    func cyclePreset(in cycle: [Preset]) async -> Preset? {
        if let refusal = Self.quickSwitchRefusal(
            connected: {
                if case .connected = connection {
                    true
                } else {
                    false
                }
            }(),
            isSelfTesting: isSelfTesting
        ) {
            // Bound to a local first. `os.Logger`'s interpolation is an
            // autoclosure, so `self.` is required inside it — and swiftformat's
            // redundant-self rule strips it back out, which fails the build in a
            // way that reads as a mistake rather than a tooling collision.
            let reason = refusal.rawValue
            log.notice("quick-switch: declined — \(reason, privacy: .public)")
            return nil
        }
        guard let next = PresetCycle.next(after: lastAppliedConfig, in: cycle) else { return nil }
        log.notice("quick-switch: \(next.name, privacy: .public)")
        await applyPreset(next, persistCurve: memory.persistsCurveWithoutApp)
        // `applyPreset` swallows failures into `lastError`; report honestly
        // rather than claiming a switch that did not happen.
        return lastError == nil ? next : nil
    }

    /// Re-applies the currently active curve with a new persist setting, so
    /// toggling "Keep running" takes effect immediately instead of only on the
    /// next preset click. No-op unless a curve is active.
    func setPersist(_ persist: Bool) async {
        guard var config = lastAppliedConfig, config.mode == .curve else { return }
        config.persistsWithoutApp = persist
        await apply(config)
    }

    /// The last curve profile the app saved, with the current "Keep running"
    /// preference applied (not whatever flag was stored with it).
    private func storedCurveConfig() -> FanConfig? {
        guard let config = memory.lastCurve, config.mode == .curve else { return nil }
        return config
    }

    /// Once per session, on the first connection: put the fans into whatever
    /// the user last chose — or, if they have never chosen, a Balanced curve
    /// rather than macOS's Automatic.
    ///
    /// Automatic is not a neutral starting point. It is macOS's own policy,
    /// which lets the machine get hot and then spins the fans hard; nobody
    /// installs a fan-control app to get that. So absence of a preference now
    /// means "give them the point of the app", not "do nothing".
    ///
    /// The apply is deliberately once-only, and `StartupPolicy` refuses to
    /// touch anything the daemon is already enforcing — a curve resumed at
    /// boot, or manual control in active use. Keeping the highlight in step
    /// afterwards is `reconcileHighlight`.
    private func autoResumeIfNeeded() async {
        guard !didAutoResume, let status else { return }
        didAutoResume = true
        let decision = StartupPolicy.decide(
            daemonMode: status.mode,
            preference: storedPreference(),
            storedCurve: storedCurveConfig(),
            fallback: Self.defaultStartupCurve
        )
        guard case let .apply(config) = decision else { return }
        log.notice("startup: applying \(config.mode.rawValue, privacy: .public) config")
        await apply(config)
    }

    /// The curve a user who has never chosen gets. Balanced by name and by
    /// intent: quieter than macOS at idle, and ramping before the die is hot
    /// rather than after.
    static let defaultStartupCurve = FanCurve.balanced

    /// What the user last deliberately selected, or `nil` if they never have.
    ///
    /// Stored separately from the curve itself because deleting the curve is
    /// how "Automatic" used to be recorded, which made a deliberate Automatic
    /// indistinguishable from a fresh install.
    private func storedPreference() -> StartupPolicy.Preference? {
        memory.storedPreference
    }

    /// Records a deliberate choice. Manual is not a startup mode — it is
    /// watchdogged and must never be what an app launch puts you in — so it
    /// leaves the stored preference untouched.
    // MARK: - Power-aware profiles

    private static let powerRuleKey = "powerProfileRule"
    /// The source at the last decision. `nil` until the first one, which is why
    /// launching already unplugged still honours the rule.
    @ObservationIgnored private var lastPowerSource: PowerProfilePolicy.PowerSource?

    /// The user's battery/wall preset mapping. Off until they configure it.
    var powerRule: PowerProfilePolicy.Rule {
        get {
            guard let data = defaults.data(forKey: Self.powerRuleKey),
                  let rule = try? JSONDecoder().decode(
                      PowerProfilePolicy.Rule.self, from: data
                  )
            else { return .suggested }
            return rule
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.powerRuleKey)
            }
        }
    }

    /// Applies the mapped preset when — and only when — the power source
    /// actually changed. See ``PowerProfilePolicy`` for why that distinction is
    /// the whole safety of the feature rather than an optimisation.
    func powerSourceChanged(to source: PowerProfilePolicy.PowerSource) async {
        let decision = PowerProfilePolicy.decide(
            source: source, previous: lastPowerSource, rule: powerRule
        )
        let previous = lastPowerSource
        if previous != source {
            // Logged on every real transition, whether or not a rule acts on
            // it. The first version of this feature logged only when it
            // switched a preset, so when it silently never fired at all there
            // was nothing in the log to say whether the power change had even
            // been noticed.
            log.notice(
                "power source: \(previous?.rawValue ?? "unknown", privacy: .public) -> \(source.rawValue, privacy: .public)"
            )
        }
        lastPowerSource = source
        guard case let .apply(kind) = decision,
              let preset = PresetStore.builtins.first(where: { $0.kind == kind })
        else { return }
        log.notice("power rule: switching to \(preset.name, privacy: .public)")
        await applyPreset(preset, persistCurve: memory.persistsCurveWithoutApp)
    }

    // MARK: - Write-path self-test (PLAN.md §4.3.6)

    /// The macOS build the write path was last confirmed working on.
    private static let verifiedOSKey = "writePathVerifiedOS"
    /// The most recent verdict, for the Settings UI. Not persisted: a verdict is
    /// only as good as the OS and hardware it was taken on.
    private(set) var writePathReport: WritePathReport?
    private(set) var isSelfTesting = false

    /// Runs the write-path self-test and keeps the verdict for display.
    ///
    /// Safe to offer as a button: the daemon writes each fan's current target
    /// back to itself and reverts, so nothing changes speed. See
    /// `DaemonCore.selfTestWritePath()`.
    @discardableResult
    func runWritePathSelfTest() async -> WritePathReport? {
        guard !isSelfTesting, case .connected = connection else { return nil }
        isSelfTesting = true
        defer { isSelfTesting = false }
        do {
            let report = try await client.selfTestWritePath()
            writePathReport = report
            lastError = nil
            if report.verdict == .verified {
                defaults.set(report.osVersion, forKey: Self.verifiedOSKey)
            }
            log.notice(
                "write-path self-test: \(report.verdict.rawValue, privacy: .public) (\(report.unlockBranch ?? "n/a", privacy: .public))"
            )
            return report
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Re-checks the write path once after macOS changes underneath us.
    ///
    /// PLAN.md §7 lists this as the mitigation for "Apple changes SMC/BTM
    /// behaviour in a new macOS" — point updates have broken fan-control write
    /// paths before (15.3/15.4). The alternative is the user discovering it
    /// themselves, by their Mac quietly running hot.
    ///
    /// Deliberately NOT on every launch: the verdict only changes when the OS
    /// or the hardware does, and exercising the write path on every boot is
    /// wear and noise for information that is almost always the same.
    private func selfTestAfterOSChangeIfNeeded() async {
        let current = HostInfo.osVersion()
        guard defaults.string(forKey: Self.verifiedOSKey) != current else { return }
        guard writePathReport == nil else { return } // already checked this session
        log.notice("write-path self-test: macOS changed since the last check — re-verifying")
        await runWritePathSelfTest()
    }

    /// Keep the active-preset highlight in step with the mode the daemon is
    /// ACTUALLY enforcing — on every status refresh, not just at launch.
    /// Idempotent when already consistent (no view churn).
    ///
    /// Without this, closing the lid leaves the popover with NO preset lit: a
    /// non-persistent curve gets reverted to auto by the daemon during sleep
    /// (stale-heartbeat watchdog / XPC invalidation), but the app still remembers
    /// the curve, which matches neither the curve preset nor Auto once the daemon
    /// is back on auto.
    private func reconcileHighlight() {
        guard let mode = status?.mode else { return }
        let reconciled = PresetHighlight.reconcile(
            daemonMode: mode,
            current: lastAppliedConfig,
            storedCurve: storedCurveConfig(),
            manualTargets: status?.appliedTargets ?? [:]
        )
        if lastAppliedConfig != reconciled {
            // Auditable: makes the sleep/wake highlight correction visible in the
            // unified log. Values are pulled into locals first so the os_log
            // autoclosure needs no `self.` (which swiftformat would strip).
            let was = lastAppliedConfig?.mode.rawValue ?? "none"
            let now = reconciled?.mode.rawValue ?? "none"
            log.notice(
                "highlight reconciled — daemon=\(mode.rawValue, privacy: .public), was=\(was, privacy: .public), now=\(now, privacy: .public)"
            )
            lastAppliedConfig = reconciled // set only on change → no view churn
        }
    }

    /// What happened to a command the app sent the daemon.
    ///
    /// Three outcomes rather than a Bool, because the daemon has a third
    /// answer: it can decline a write it would be wrong to make — the Mac is
    /// parked for sleep — without anything being broken. Collapsing that into
    /// `false` is what put a raw NSError in the popover after a lid close.
    enum CommandOutcome: Equatable {
        case ok
        /// Declined for now. Try again; say nothing alarming.
        case deferredUntilWake
        case failed
    }

    /// Runs `operation`, sorting a throw into "tell the user" and "try later".
    @discardableResult
    private func run(_ operation: () async throws -> Void) async -> CommandOutcome {
        do {
            try await operation()
            lastError = nil
            hasLoggedDeferral = false
            await refreshStatus()
            return .ok
        } catch let error where WireError.isDeferredUntilWake(error) {
            // Logged once per spell, not once per 5 s pass — the same rule the
            // daemon's own wake logging follows, and for the same reason.
            if !hasLoggedDeferral {
                hasLoggedDeferral = true
                log.notice("command deferred — the Mac is asleep; it will be re-sent on wake")
            }
            return .deferredUntilWake
        } catch {
            // Now readable, because `HelperService` wires the description into
            // userInfo before the reply. Before that it was always the
            // "(IceCubeKit.IceCubeError error N.)" fallback.
            lastError = error.localizedDescription
            return .failed
        }
    }

    // MARK: - The maintenance loop

    private func maintain() async {
        refreshRegistration()
        guard registration == .enabled else {
            connection = .disconnected
            return
        }
        if !client.isConnected {
            client.connect()
            do {
                let version = try await client.version()
                connection = version == HelperConstants.protocolVersion
                    ? .connected(version: version)
                    : .versionMismatch(helper: version)
            } catch {
                connection = .disconnected
                client.disconnect() // clean slate; next loop retries (5 s backoff)
                await selfHealIfWedged()
                return
            }
        }
        if case .versionMismatch = connection {
            // The running service is older than this app. There is exactly one
            // correct response and the app can perform it, so asking the user
            // to press a button would be asking them to do our job.
            await selfHeal(reason: "running service is an older version")
            return
        }
        guard case .connected = connection else { return }
        // A healthy connection ends the episode: a later wedge is a NEW fault
        // and deserves its own repair. Resetting only here — never on a failed
        // attempt — is what stops a service that cannot start from being
        // reinstalled every 20 s forever.
        if hasSelfHealed {
            log.notice("self-heal: recovered")
        }
        unreachableSince = nil
        hasSelfHealed = false
        client.heartbeat()
        await refreshStatus()
        // Before the startup decision: what the user (or a power rule) actually
        // asked for outranks what `StartupPolicy` would infer for them.
        await retryDeferredApply()
        await autoResumeIfNeeded()
        await powerSourceChanged(to: powerSource.current)
        await selfTestAfterOSChangeIfNeeded()
        reconcileHighlight()
    }

    /// How long the service may be registered-but-unreachable before the app
    /// repairs it without being asked.
    ///
    /// Generous: launchd can be slow to start a service on a busy machine, and
    /// re-registering during normal startup would be churn, not healing.
    private static let wedgedThreshold: TimeInterval = 20
    /// When the current unreachable stretch began.
    @ObservationIgnored private var unreachableSince: Date?
    /// One automatic repair per app session. A repair that does not take is a
    /// real fault the user must see — retrying forever would hide it, and would
    /// restart a root service every 20 s indefinitely.
    @ObservationIgnored private var hasSelfHealed = false

    /// Repairs a service that is registered but has stopped answering.
    ///
    /// The case that makes this necessary rather than nice: replacing the app
    /// while its service is still running invalidates that running copy's code
    /// signature, so every message is refused (errSecCSReqFailed) and the
    /// handshake can never complete. That is not exotic — it is what a normal
    /// update does when someone drags a new version into Applications over a
    /// running one. The user did nothing wrong, the app knows precisely what is
    /// wrong and precisely how to fix it, so it should just fix it.
    private func selfHealIfWedged() async {
        guard registration == .enabled else {
            unreachableSince = nil
            return
        }
        let start = unreachableSince ?? Date()
        unreachableSince = start
        guard Date().timeIntervalSince(start) >= Self.wedgedThreshold else { return }
        await selfHeal(reason: "service registered but unreachable for \(Int(Self.wedgedThreshold))s")
    }

    private func selfHeal(reason: String) async {
        guard !hasSelfHealed, !isReregistering else { return }
        hasSelfHealed = true
        log.notice("self-heal: reinstalling background service — \(reason, privacy: .public)")
        await reregister()
        unreachableSince = nil
        // No verdict here. `reregister()` returns once launchd has accepted the
        // job, but the version handshake only completes on a LATER maintain
        // pass — so `connection` is still `.disconnected` at this instant and
        // checking it reported a repair that had in fact worked as a failure.
        // The connected branch in `maintain()` reports recovery instead; if it
        // never runs, the setup window's `.connectionStuck` step offers the
        // manual button.
    }

    private func refreshStatus() async {
        status = try? await client.status()
        mergeDecisions(status?.recentDecisions)
    }

    /// Folds a status payload's decisions into the session timeline.
    ///
    /// Assigned only when something is genuinely new: the popover renders this,
    /// and reassigning an identical array every 5 s would invalidate the view
    /// for nothing. `nil` means a daemon that predates v23, which is not an
    /// error — it simply contributes nothing.
    /// Called with decisions this app has **never seen before**.
    ///
    /// A callback rather than a direct call into `AlertManager`, because this
    /// type is already 985 lines and owns the daemon lifecycle — it has no
    /// business knowing what a notification is. `AppState` connects the two.
    ///
    /// The freshness is the whole value: the same decision arrives in several
    /// consecutive status payloads, so anything acting on `decisions` wholesale
    /// would fire once every 5 s for as long as the daemon kept repeating it.
    var onFreshDecisions: (([DecisionEvent]) -> Void)?

    private func mergeDecisions(_ incoming: [DecisionEvent]?) {
        guard let incoming, !incoming.isEmpty else { return }
        let known = Set(decisions.map(\.id))
        let fresh = incoming.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        decisions.append(contentsOf: fresh)
        if decisions.count > Self.decisionHistoryLimit {
            decisions.removeFirst(decisions.count - Self.decisionHistoryLimit)
        }
        onFreshDecisions?(fresh)
    }
}
