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
    private(set) var lastError: String?

    /// Clears a failure the user has acknowledged, so a retry starts from a
    /// clean slate rather than re-showing the previous attempt's message.
    func clearError() {
        lastError = nil
    }

    private let service = SMAppService.daemon(
        plistName: "io.github.thijsvos.icecube.helper.plist"
    )
    private let client = HelperClient()
    private let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "xpc")
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    /// The maintenance pass currently in flight, if any. Concurrent callers
    /// join it rather than being dropped — see ``maintainOnce()``.
    @ObservationIgnored private var maintenancePass: Task<Void, Never>?

    init() {
        client.onDisconnect = { [weak self] in
            self?.connection = .disconnected
            self?.status = nil
        }
        refreshRegistration()
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
        RegistrationPreflight.blocker(
            teamID: CodesignPinning.currentTeamID(),
            bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path
        )
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

    func unregister() async {
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
        if case .connected = connection {
            await run { try await self.client.setAllAuto() }
        }
        lastAppliedConfig = nil
        UserDefaults.standard.removeObject(forKey: Self.lastCurveKey)

        client.disconnect()
        do {
            try await service.unregister()
            lastError = nil
        } catch {
            lastError = "Unregister failed: \(error.localizedDescription)"
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
        await unregister()
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
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Fan control commands

    /// The last config this app sent (drives preset highlighting; the
    /// daemon's status remains the truth for what is actually enforced).
    private(set) var lastAppliedConfig: FanConfig?

    private static let lastCurveKey = "lastCurveConfig"
    /// Guards the once-per-session auto-resume of the last curve on launch.
    @ObservationIgnored private var didAutoResume = false

    func apply(_ config: FanConfig) async {
        let applied = await run {
            try await self.client.apply(config)
            self.lastAppliedConfig = config
        }
        // Remember a curve profile so a later launch can resume it; a
        // deliberate Auto forgets it (the user wants macOS in control).
        //
        // Only on SUCCESS. This write used to run unconditionally, outside the
        // error handling above — so a curve the daemon REJECTED (bad config, or
        // the connection dropping mid-call) was still stored, and
        // `autoResumeIfNeeded()` silently applied it on the next launch. The
        // user would get fan control they never successfully engaged, resumed
        // without any interaction, after being shown an error saying it failed.
        guard applied else { return }
        let defaults = UserDefaults.standard
        if config.mode == .curve, let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: Self.lastCurveKey)
        } else if config.mode == .auto {
            defaults.removeObject(forKey: Self.lastCurveKey)
        }
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
        await apply(config)
    }

    /// Re-applies the currently active curve with a new persist setting, so
    /// toggling "Keep running" takes effect immediately instead of only on the
    /// next preset click. No-op unless a curve is active.
    func setPersist(_ persist: Bool) async {
        guard var config = lastAppliedConfig, config.mode == .curve else { return }
        config.persistsWithoutApp = persist
        await apply(config)
    }

    func revertToAuto() async {
        await run {
            try await self.client.setAllAuto()
            self.lastAppliedConfig = .auto
        }
        UserDefaults.standard.removeObject(forKey: Self.lastCurveKey)
    }

    /// The last curve profile the app saved, with the current "Keep running"
    /// preference applied (not whatever flag was stored with it).
    private func storedCurveConfig() -> FanConfig? {
        guard let data = UserDefaults.standard.data(forKey: Self.lastCurveKey),
              var config = try? JSONDecoder().decode(FanConfig.self, from: data),
              config.mode == .curve else { return nil }
        config.persistsWithoutApp = UserDefaults.standard.bool(forKey: "persistCurve")
        return config
    }

    /// Once per session, on the first connection: if the daemon is idle in auto
    /// and we saved a curve, resume it so opening Ice Cube starts cooling instead
    /// of leaving the machine on macOS's quiet auto behavior. The APPLY is
    /// deliberately once-only; keeping the highlight in sync is `reconcileHighlight`.
    private func autoResumeIfNeeded() async {
        guard !didAutoResume, status != nil else { return }
        didAutoResume = true
        guard status?.mode == .auto, let stored = storedCurveConfig() else { return }
        await apply(stored)
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

    /// Runs `operation`, funnelling any throw into `lastError`.
    /// - Returns: whether it succeeded, so callers can avoid acting on a
    ///   command the daemon actually rejected.
    @discardableResult
    private func run(_ operation: () async throws -> Void) async -> Bool {
        do {
            try await operation()
            lastError = nil
            await refreshStatus()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
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
                return
            }
        }
        guard case .connected = connection else { return }
        client.heartbeat()
        await refreshStatus()
        await autoResumeIfNeeded()
        reconcileHighlight()
    }

    private func refreshStatus() async {
        status = try? await client.status()
    }
}
