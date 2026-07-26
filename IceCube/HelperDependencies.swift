// HelperDependencies.swift — the two system seams HelperManager talks through, so its logic can be tested.

import Foundation
import IceCubeKit
import ServiceManagement

/// The XPC channel to the daemon, as ``HelperManager`` needs it.
///
/// Extracted so the manager's logic — the version handshake, the self-heal
/// ladder, the once-per-session auto-resume — can be exercised without a root
/// daemon, a signed bundle, or a Mac. ``HelperClient`` is the only production
/// conformance and is unchanged; it already had exactly this shape.
protocol HelperChanneling: AnyObject {
    /// Called when the connection drops (helper crashed, unregistered, …).
    var onDisconnect: (() -> Void)? { get set }
    var isConnected: Bool { get }
    func connect()
    func disconnect()
    func version() async throws -> String
    func apply(_ config: FanConfig) async throws
    func setAllAuto() async throws
    func heartbeat()
    func status() async throws -> HelperStatus
}

extension HelperClient: HelperChanneling {}

/// Registration with launchd via `SMAppService`, as ``HelperManager`` needs it.
///
/// `status` deliberately stays `SMAppService.Status` rather than being mapped
/// to something friendlier at the seam: the mapping is itself worth testing.
/// `.notFound` in particular does NOT mean a broken bundle — it is also what a
/// never-registered daemon reports on a fresh machine, and reading it as a
/// failure is a mistake this project has already made once.
protocol DaemonRegistering {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
    /// Opens System Settings → Login Items, where approval happens.
    func openSettings()
}

/// The real thing: the launchd daemon declared by the bundled plist.
struct SMAppServiceRegistrar: DaemonRegistering {
    private let service = SMAppService.daemon(
        plistName: "io.github.thijsvos.icecube.helper.plist"
    )

    var status: SMAppService.Status {
        service.status
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
