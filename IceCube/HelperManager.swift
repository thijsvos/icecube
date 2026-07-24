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
@MainActor
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

    private let service = SMAppService.daemon(
        plistName: "io.github.thijsvos.icecube.helper.plist"
    )
    private let client = HelperClient()
    private let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "xpc")
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Guards against overlapping maintenance passes (the 5 s loop vs. an
    /// on-demand refresh from wake / popover-open).
    @ObservationIgnored private var isMaintaining = false

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
                await self?.maintain()
                try? await Task.sleep(for: .seconds(HelperConstants.heartbeatInterval))
            }
        }
        // React to system wake immediately instead of waiting for the next 5 s
        // tick — reconnect + reconcile so the popover is correct the moment the
        // lid opens. Purely an app-side responsiveness hook; the daemon and its
        // safety timers are untouched.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    deinit {
        maintenanceTask?.cancel()
        // `wakeObserver` is intentionally left registered: HelperManager lives
        // for the whole app lifetime, and its block captures only a weak self,
        // so it becomes inert on teardown. (A non-Sendable NSObjectProtocol
        // can't be removed from a nonisolated deinit under Swift 6 anyway.)
    }

    /// Runs one maintenance pass right now (reconnect + status + reconcile)
    /// without waiting for the loop — used on system wake and when the popover
    /// opens so the UI reflects reality promptly. A pass already in flight is
    /// skipped, so it's cheap and safe to call repeatedly.
    func refreshNow() {
        Task { await maintain() }
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

    /// Registers the daemon. On a fresh machine this triggers the one-time
    /// System Settings approval flow (XCODE_GUIDE.md §4).
    func register() {
        do {
            try service.register()
            lastError = nil
        } catch {
            // The classic causes: not running from /Applications, or the
            // free-account limitation the Phase 0.5 spike exists to probe.
            lastError = "Registration failed: \(error.localizedDescription) — "
                + "make sure Ice Cube runs from /Applications (XCODE_GUIDE §4)."
            log.error("register() failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshRegistration()
    }

    func unregister() async {
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
        isReregistering = true
        defer { isReregistering = false }
        await unregister()
        for attempt in 0 ..< 6 {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 300 : 500))
            register()
            // register() refreshes `registration`; anything past notRegistered
            // (requiresApproval or enabled) means launchd accepted the new job.
            if registration != .notRegistered {
                lastError = nil
                return
            }
        }
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
        await run {
            try await self.client.apply(config)
            self.lastAppliedConfig = config
        }
        // Remember a curve profile so a later launch can resume it; a
        // deliberate Auto forgets it (the user wants macOS in control).
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

    private func run(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            lastError = nil
            await refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - The maintenance loop

    private func maintain() async {
        if isMaintaining {
            return
        } // don't let the loop and an on-demand refresh overlap
        isMaintaining = true
        defer { isMaintaining = false }
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
