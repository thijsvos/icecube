// SMCPoller.swift — turns any SMCProviding into a steady stream of snapshots (or failure notices).

import Foundation

/// One tick of the polling loop: a fresh snapshot, or why this tick failed.
/// Failures are events, not stream termination — a transient SMC hiccup
/// should show a message and keep polling, never kill the pipeline.
public enum SMCPollEvent: Sendable {
    case snapshot(SMCSnapshot)
    /// Why this tick failed, as the typed error — not a flattened string.
    /// Consumers need to tell a permanent failure (`smcKeyNotFound` on an
    /// unmapped Mac, which the diagnostics export exists to fix) from a
    /// transient hiccup; a `String` made those indistinguishable.
    case failure(IceCubeError)
}

/// Polls an ``SMCProviding`` on a fixed cadence and publishes the results as
/// an `AsyncStream` — the app consumes this for the menu bar and charts. The
/// default 1 s cadence respects the project rule of never polling the SMC
/// faster than 500 ms.
///
/// A value type: it holds only its (immutable) configuration and its one
/// method is stateless, so there is nothing for an actor to protect.
public struct SMCPoller: Sendable {
    private let provider: any SMCProviding
    private let interval: Duration

    public init(provider: any SMCProviding, interval: Duration = .seconds(1)) {
        self.provider = provider
        self.interval = interval
    }

    /// Starts a fresh polling loop; the loop lives exactly as long as the
    /// stream has a consumer (cancellation of the consuming task ends it).
    /// The first event arrives immediately, then one per interval.
    ///
    /// Buffering is `.bufferingNewest(1)`: only the freshest reading matters,
    /// so if the consumer stalls we drop stale frames rather than queue a
    /// burst of them.
    public func events() -> AsyncStream<SMCPollEvent> {
        let provider = provider
        let interval = interval
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do throws(IceCubeError) {
                        try await continuation.yield(.snapshot(provider.snapshot()))
                    } catch {
                        continuation.yield(.failure(error))
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
