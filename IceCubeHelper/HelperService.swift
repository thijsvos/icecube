// HelperService.swift — the XPC listener: code-signing pinning on every connection, thin bridge to DaemonCore.

import Foundation
import IceCubeKit
import os

/// Accepts XPC connections from the app (and nothing else) and forwards the
/// tiny ``HelperProtocol`` surface to ``DaemonCore``.
/// `Sendable`, not `@unchecked`: this is a final class whose only superclass
/// is NSObject and whose stored properties are both immutable and Sendable (an
/// actor and an os.Logger), which is exactly what checked conformance allows.
/// The escape hatch bought nothing: a future mutable stored property is now a
/// compile error rather than a silent race at the daemon's XPC front door. The
/// `let core = core` bindings below stay — those avoid an implicit strong
/// `self` capture in escaping closures, which is a capture-semantics rule
/// independent of Sendable.
final class HelperService: NSObject, NSXPCListenerDelegate, HelperProtocol, Sendable {
    private let core: DaemonCore
    private let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "xpc")

    init(core: DaemonCore) {
        self.core = core
    }

    // MARK: - NSXPCListenerDelegate (the security gate)

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Pin callers to OUR team + the app's identifier (TN3127 dev variant).
        // The Team ID comes from our own signature at runtime.
        if let requirement = CodesignPinning.requirementForPeer(identifier: HelperConstants.appBundleID) {
            connection.setCodeSigningRequirement(requirement)
            log.info("connection accepted with pinning: \(requirement, privacy: .public)")
        } else {
            // Unsigned helper (ad-hoc/dev CI): code-signing pinning is
            // impossible.
            #if DEBUG
                // Don't accept ANY local process — at least require the caller
                // to be a real console user rather than a system daemon.
                //
                // This used to compare against `getuid()`, but *we* are the root
                // daemon, so that read as "the caller must be root" — the exact
                // opposite of the intent, and it rejected the very app it exists
                // to admit. Root and the system-service range are what we want to
                // exclude here; the app runs as the logged-in user (uid >= 501).
                guard connection.effectiveUserIdentifier >= 501 else {
                    log.fault("DEBUG: rejecting XPC from a system uid (\(connection.effectiveUserIdentifier))")
                    return false
                }
                log.fault("DEBUG build without a Team ID — accepting same-user XPC WITHOUT pinning. Never ship this.")
            #else
                log.fault("release helper is unsigned — rejecting all XPC connections")
                return false
            #endif
        }

        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        let core = core
        connection.invalidationHandler = {
            // §4.3: invalidation with a non-persistent config → revert.
            Task { await core.connectionInvalidated() }
        }
        connection.resume()
        return true
    }

    // MARK: - HelperProtocol

    func getVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperConstants.protocolVersion)
    }

    func apply(configData: Data, reply: @escaping @Sendable (NSError?) -> Void) {
        let core = core
        Task {
            do {
                let config = try JSONDecoder().decode(FanConfig.self, from: configData)
                try await core.apply(config)
                reply(nil)
            } catch {
                reply(error as NSError)
            }
        }
    }

    func setAllAuto(reply: @escaping @Sendable (NSError?) -> Void) {
        let core = core
        Task {
            await core.setAllAuto()
            reply(nil)
        }
    }

    func heartbeat() {
        let core = core
        Task { await core.heartbeat() }
    }

    func getStatus(reply: @escaping @Sendable (Data) -> Void) {
        let core = core
        Task {
            let status = await core.currentStatus()
            reply((try? status.jsonData()) ?? Data())
        }
    }

    func selfTestWritePath(reply: @escaping @Sendable (Data) -> Void) {
        let core = core
        Task {
            let report = await core.selfTestWritePath()
            reply((try? JSONEncoder().encode(report)) ?? Data())
        }
    }
}
