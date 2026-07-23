// HelperClient.swift — the app's XPC connection to the helper daemon: pinned, async-wrapped, reconnect-aware.

import Foundation
import os
import ZephyrKit

/// A thin async wrapper around one `NSXPCConnection` to the root daemon.
///
/// The connection pins the helper's code signature to our own Team ID
/// (mirroring the pinning the helper applies to us). Unsigned dev builds
/// can't pin — that's logged loudly and only tolerated in DEBUG.
@MainActor
final class HelperClient {
    private var connection: NSXPCConnection?
    private let log = Logger(subsystem: "io.github.thijsvos.zephyr", category: "xpc")
    /// Called when the connection drops (helper crashed, unregistered, …).
    var onDisconnect: (() -> Void)?

    var isConnected: Bool {
        connection != nil
    }

    func connect() {
        guard connection == nil else { return }
        let c = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName, options: .privileged
        )
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        if let requirement = CodesignPinning.requirementForPeer(
            identifier: HelperConstants.helperBundleID
        ) {
            c.setCodeSigningRequirement(requirement)
        } else {
            log.fault("app has no Team ID — connecting WITHOUT pinning (DEBUG-only situation)")
        }
        c.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connection = nil
                self?.onDisconnect?()
            }
        }
        c.interruptionHandler = { [weak self] in
            // Helper died mid-flight; invalidate and let the manager reconnect.
            Task { @MainActor [weak self] in
                self?.connection?.invalidate()
            }
        }
        c.resume()
        connection = c
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Protocol calls (async wrappers)

    func version() async throws -> String {
        let proxy = try proxy()
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceResumer(continuation: continuation)
            (proxy as? HelperProtocol)?.getVersion { version in
                once.resume(.success(version))
            }
        }
    }

    func apply(_ config: FanConfig) async throws {
        let data = try JSONEncoder().encode(config)
        let proxy = try proxy()
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceResumer(continuation: continuation)
            (proxy as? HelperProtocol)?.apply(configData: data) { error in
                if let error {
                    once.resume(.failure(error))
                } else {
                    once.resume(.success(()))
                }
            }
        }
    }

    func setAllAuto() async throws {
        let proxy = try proxy()
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceResumer(continuation: continuation)
            (proxy as? HelperProtocol)?.setAllAuto { error in
                if let error {
                    once.resume(.failure(error))
                } else {
                    once.resume(.success(()))
                }
            }
        }
    }

    func heartbeat() {
        (try? proxy()).flatMap { ($0 as? HelperProtocol)?.heartbeat() }
    }

    func status() async throws -> HelperStatus {
        let proxy = try proxy()
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceResumer(continuation: continuation)
            (proxy as? HelperProtocol)?.getStatus { data in
                do {
                    try once.resume(.success(HelperStatus.decode(data)))
                } catch {
                    once.resume(.failure(error))
                }
            }
        }
    }

    // MARK: - Plumbing

    private struct NotConnected: Error {}

    private func proxy() throws -> Any {
        guard let connection else { throw NotConnected() }
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor [weak self] in
                self?.log.error("XPC call failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// Guards a checked continuation against double-resume: XPC gives no formal
/// guarantee that a reply block and the error handler are mutually exclusive
/// in every edge case, and a double resume is instant UB.
/// `nonisolated`: XPC reply blocks call `resume` from arbitrary threads — the
/// app target's MainActor default isolation must not apply here.
private final nonisolated class OnceResumer<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
