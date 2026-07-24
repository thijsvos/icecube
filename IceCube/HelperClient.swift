// HelperClient.swift — the app's XPC connection to the helper daemon: pinned, async-wrapped, reconnect-aware.

import Foundation
import IceCubeKit
import os

/// A thin async wrapper around one `NSXPCConnection` to the root daemon.
///
/// The connection pins the helper's code signature to our own Team ID
/// (mirroring the pinning the helper applies to us). Unsigned dev builds
/// can't pin — that's logged loudly and only tolerated in DEBUG.
@MainActor
final class HelperClient {
    private var connection: NSXPCConnection?
    private let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "xpc")
    /// Called when the connection drops (helper crashed, unregistered, …).
    var onDisconnect: (() -> Void)?
    /// Bumped on every connect and disconnect, so a callback can tell whether
    /// the connection it reports on is still the current one. An `Int` rather
    /// than the connection itself because `NSXPCConnection` is not `Sendable`
    /// and these handlers must be.
    private var generation = 0

    var isConnected: Bool {
        connection != nil
    }

    func connect() {
        guard connection == nil else { return }
        generation &+= 1
        let generation = generation
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
        // `@Sendable` makes the "XPC calls this off the main thread" contract
        // explicit and checked in a module that is MainActor by default.
        //
        // The generation guard matters: this handler reports on THIS
        // connection, but by the time the main-actor hop lands, `maintain()`
        // may already have disconnected and reconnected. Without the check, a
        // stale callback would null out a newer, resumed connection —
        // orphaning it and flipping the UI to disconnected after a good
        // handshake.
        c.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.connection = nil
                self.onDisconnect?()
            }
        }
        c.interruptionHandler = { @Sendable [weak self] in
            // Helper died mid-flight; invalidate and let the manager reconnect.
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.connection?.invalidate()
            }
        }
        c.resume()
        connection = c
    }

    func disconnect() {
        // Bump first: the invalidate below fires the handler, which must see a
        // stale generation and not re-enter onDisconnect.
        generation &+= 1
        connection?.invalidate()
        connection = nil
    }

    // MARK: - Protocol calls (async wrappers)

    func version() async throws -> String {
        try await call { proxy, done in proxy.getVersion { done(.success($0)) } }
    }

    func apply(_ config: FanConfig) async throws {
        let data = try JSONEncoder().encode(config)
        try await call { proxy, done in
            proxy.apply(configData: data) { error in done(error.map { .failure($0) } ?? .success(())) }
        }
    }

    func setAllAuto() async throws {
        try await call { proxy, done in
            proxy.setAllAuto { error in done(error.map { .failure($0) } ?? .success(())) }
        }
    }

    func heartbeat() {
        // Fire-and-forget: no reply, so a dead connection simply does nothing.
        (connection?.remoteObjectProxy as? HelperProtocol)?.heartbeat()
    }

    func status() async throws -> HelperStatus {
        try await call { proxy, done in
            proxy.getStatus { data in done(Result { try HelperStatus.decode(data) }) }
        }
    }

    // MARK: - Plumbing

    private struct NotConnected: Error {}

    /// Runs one XPC call inside a single continuation. The proxy's error
    /// handler resumes the SAME `OnceResumer` — so a connection that dies
    /// mid-call fails the `await` instead of leaking the continuation and
    /// hanging forever (which is what happens if only the reply block can
    /// resume it). `OnceResumer` guarantees exactly one of the two fires.
    private func call<T: Sendable>(
        _ body: @Sendable (HelperProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        guard let connection else { throw NotConnected() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceResumer(continuation: continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(error))
            }
            guard let helper = proxy as? HelperProtocol else {
                once.resume(.failure(NotConnected()))
                return
            }
            body(helper) { once.resume($0) }
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
