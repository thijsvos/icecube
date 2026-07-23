// AppState.swift — the single observable model the menu-bar UI renders from; owns the 1 Hz polling loop.

import Foundation
import Observation
import ZephyrKit

/// The app's only mutable state: the latest ``SMCSnapshot`` plus a short error
/// message when a read fails.
///
/// `AppState` polls its ``SMCProviding`` once per second on the main actor and
/// publishes the result via Observation — the menu bar label and the popover
/// both just read properties here. It never writes to hardware (nothing in the
/// app process does; see `SMCProviding`), and it never crashes on a provider
/// error: failures become a short message and polling keeps trying.
@MainActor
@Observable
final class AppState {
    /// The most recent successful reading, or `nil` before the first one lands.
    private(set) var snapshot: SMCSnapshot?
    /// True when running against `MockSMCProvider` — the UI shows a badge so
    /// simulated numbers are never mistaken for real hardware.
    let isSimulated: Bool
    /// Short human-readable description of the last read failure, or `nil`
    /// when the latest poll succeeded.
    private(set) var errorMessage: String?

    /// Where readings come from. Injected so tests and Phase 1 swap freely.
    private let provider: any SMCProviding
    /// The polling loop; `nil` when stopped.
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(provider: any SMCProviding, isSimulated: Bool) {
        self.provider = provider
        self.isSimulated = isSimulated
    }

    deinit {
        // Task.cancel() is nonisolated and safe to call from deinit.
        pollTask?.cancel()
    }

    // MARK: - Polling

    /// Starts the 1 Hz polling loop. Calling it again while running is a no-op.
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return } // strong only for one iteration
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Cancels the polling loop. Safe to call when already stopped.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One poll: read a snapshot, or record a short error and keep the last
    /// good snapshot on screen so the UI never blanks out on a transient miss.
    private func refresh() async {
        do {
            snapshot = try await provider.snapshot()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - UI conveniences

    /// All fans from the latest snapshot (empty before the first reading).
    var fans: [Fan] {
        snapshot?.fans ?? []
    }

    /// All temperature sensors from the latest snapshot.
    var temperatures: [SensorReading] {
        snapshot?.temperatures ?? []
    }

    /// The hottest sensor right now, if any — drives the badge and tinting.
    var hottest: SensorReading? {
        snapshot?.hottest
    }

    /// The menu bar readout, e.g. `"62°"`; `"--°"` before the first reading.
    var hottestText: String {
        guard let hottest = snapshot?.hottest else { return "--°" }
        return "\(Int(hottest.celsius.rounded()))°"
    }
}
