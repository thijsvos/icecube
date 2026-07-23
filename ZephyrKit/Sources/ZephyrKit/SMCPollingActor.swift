// SMCPollingActor.swift — turns any SMCProviding into a steady stream of snapshots (or failure notices).

import Foundation

/// One tick of the polling loop: a fresh snapshot, or why this tick failed.
/// Failures are events, not stream termination — a transient SMC hiccup
/// should show a message and keep polling, never kill the pipeline.
public enum SMCPollEvent: Sendable {
    case snapshot(SMCSnapshot)
    case failure(String)
}

/// Polls an ``SMCProviding`` on a fixed cadence and publishes the results as
/// an `AsyncStream` — the app consumes this for the menu bar and (Phase 2)
/// charts. The default 1 s cadence respects the project rule of never polling
/// the SMC faster than 500 ms.
public actor SMCPollingActor {
    private let provider: any SMCProviding
    private let interval: Duration

    public init(provider: any SMCProviding, interval: Duration = .seconds(1)) {
        self.provider = provider
        self.interval = interval
    }

    /// Starts a fresh polling loop; the loop lives exactly as long as the
    /// stream has a consumer (cancellation of the consuming task ends it).
    /// The first event arrives immediately, then one per interval.
    public nonisolated func events() -> AsyncStream<SMCPollEvent> {
        let provider = provider
        let interval = interval
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    do {
                        try await continuation.yield(.snapshot(provider.snapshot()))
                    } catch {
                        continuation.yield(.failure(error.localizedDescription))
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
