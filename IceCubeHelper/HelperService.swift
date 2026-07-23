// HelperService.swift — the XPC listener: code-signing pinning on every connection, thin bridge to DaemonCore.

import Foundation
import IceCubeKit
import os

/// Accepts XPC connections from the app (and nothing else) and forwards the
/// tiny ``HelperProtocol`` surface to ``DaemonCore``.
final class HelperService: NSObject, NSXPCListenerDelegate, HelperProtocol, @unchecked Sendable {
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
                // to run as the same user, so a DEBUG build isn't wide open.
                guard connection.effectiveUserIdentifier == getuid() else {
                    log.fault("DEBUG: rejecting XPC from a different user (uid \(connection.effectiveUserIdentifier))")
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
}
