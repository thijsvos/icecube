// HelperManager.swift — helper lifecycle: SMAppService registration, connection + handshake, heartbeat, status.

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

    /// The #1 dev trap: after a rebuild, launchd may still run the OLD helper
    /// copy. Unregister + register forces the fresh binary (XCODE_GUIDE §4.4).
    func reregister() async {
        await unregister()
        register()
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

    /// On the first connection of a session, reconcile the app with the daemon
    /// using the stored curve profile:
    /// - daemon idle in **auto**: resume the curve so opening Ice Cube starts
    ///   cooling instead of leaving the machine on macOS's quiet auto behavior;
    /// - daemon already running a **curve** (a persisted profile from boot):
    ///   restore `lastAppliedConfig` (without re-applying) so the UI knows which
    ///   preset is active and highlights it — otherwise the popover says "curve
    ///   active" but no preset button lights up.
    private func autoResumeIfNeeded() async {
        guard !didAutoResume, let mode = status?.mode else { return }
        didAutoResume = true
        guard mode == .auto || mode == .curve else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.lastCurveKey),
              var config = try? JSONDecoder().decode(FanConfig.self, from: data),
              config.mode == .curve else { return }
        // Honor the current "Keep running" preference, not whatever flag was
        // stored with the curve (shares the "persistCurve" @AppStorage key).
        config.persistsWithoutApp = UserDefaults.standard.bool(forKey: "persistCurve")
        if mode == .auto {
            await apply(config) // daemon idle → resume (starts cooling)
        } else {
            lastAppliedConfig = config // already running it → just restore the highlight
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
    }

    private func refreshStatus() async {
        status = try? await client.status()
    }
}
