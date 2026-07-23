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
    /// The hottest sensor as shown in UI — updated with hysteresis so the
    /// badge doesn't flip between near-equal cores every second.
    private(set) var hottest: SensorReading?
    /// Consecutive failed polls; the error row only appears at 3+ so a single
    /// transient miss can't flash a caption in and out of the layout.
    @ObservationIgnored private var consecutiveFailures = 0
    /// True when running against `MockSMCProvider` — the UI shows a badge so
    /// simulated numbers are never mistaken for real hardware.
    let isSimulated: Bool
    /// Helper daemon lifecycle + fan-control commands (Phase 3).
    let helper = HelperManager()
    /// Short human-readable description of the last read failure, or `nil`
    /// when the latest poll succeeded.
    private(set) var errorMessage: String?

    // MARK: - Charts (Phase 2)

    /// The dashboard's chart rows for the selected window, ready to render.
    private(set) var chartRows: [ChartStore.Row] = []
    /// Index into `ChartStore.windows` (1 / 5 / 15 / 60 min). Default 5 min.
    var selectedWindowIndex = 1 {
        didSet { refreshCharts() }
    }

    /// Frozen display (recording continues; see `togglePaused`).
    private(set) var isPaused = false
    /// The shared x axis for all chart rows: trailing `window`, ending at the
    /// newest sample — every row scrolls in lockstep.
    private(set) var chartXDomain: ClosedRange<Date> = Date.distantPast ... Date.distantFuture

    /// What text accompanies the menu bar icon; persisted across launches.
    var menuBarDisplay: MenuBarDisplayMode {
        didSet { UserDefaults.standard.set(menuBarDisplay.rawValue, forKey: Self.menuBarDisplayKey) }
    }

    private static let menuBarDisplayKey = "menuBarDisplay"
    @ObservationIgnored private let chartStore = ChartStore()
    private var chartWindow: TimeInterval {
        ChartStore.windows[selectedWindowIndex]
    }

    // MARK: - Wiring

    /// Where readings come from. Injected so tests and simulated mode swap freely.
    private let provider: any SMCProviding
    /// Wraps `provider` in the 1 Hz snapshot stream (`SMCPollEvent`s).
    private let poller: SMCPollingActor
    /// The task consuming the polling stream; `nil` when stopped.
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(provider: any SMCProviding, isSimulated: Bool) {
        self.provider = provider
        self.isSimulated = isSimulated
        poller = SMCPollingActor(provider: provider)
        menuBarDisplay = MenuBarDisplayMode(
            rawValue: UserDefaults.standard.string(forKey: Self.menuBarDisplayKey) ?? ""
        ) ?? .temperature
    }

    deinit {
        // Task.cancel() is nonisolated and safe to call from deinit.
        pollTask?.cancel()
    }

    // MARK: - Polling

    /// Starts consuming the 1 Hz polling stream. A second call is a no-op.
    func start() {
        guard pollTask == nil else { return }
        let events = poller.events()
        pollTask = Task { [weak self] in
            for await event in events {
                guard let self else { return } // strong only per event
                switch event {
                case let .snapshot(new):
                    snapshot = new
                    hottest = new.hottest(stickingTo: hottest?.key)
                    consecutiveFailures = 0
                    errorMessage = nil
                    // History records even while the display is paused —
                    // pause freezes the picture, not the recording.
                    await chartStore.ingest(new)
                    if !isPaused {
                        chartRows = await chartStore.rows(window: chartWindow)
                        chartXDomain = new.date.addingTimeInterval(-chartWindow) ... new.date
                    }
                case let .failure(message):
                    // Keep the last good snapshot on screen. One transient
                    // miss is silent; only a persistent failure (3+ ticks)
                    // earns the error row — appearing/disappearing captions
                    // are exactly the layout jump we forbid.
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
                        errorMessage = message
                    }
                }
            }
        }
    }

    /// Stops consuming (which also ends the underlying polling loop).
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Chart controls

    /// Pause freezes the rendered rows; ingest continues so nothing is lost.
    /// Resuming immediately re-renders the live window.
    func togglePaused() {
        isPaused.toggle()
        if !isPaused {
            refreshCharts()
        }
    }

    /// Re-renders rows for the current window (window change or unpause).
    private func refreshCharts() {
        guard !isPaused else { return }
        Task { [weak self] in
            guard let self else { return }
            let rows = await chartStore.rows(window: chartWindow)
            if let end = rows.first?.series.first?.buckets.last?.time ?? snapshot?.date {
                chartXDomain = end.addingTimeInterval(-chartWindow) ... end
            }
            chartRows = rows
        }
    }

    // MARK: - Menu bar text

    /// The text beside the menu bar icon, per the user's display setting;
    /// `nil` for icon-only.
    var menuBarText: String? {
        switch menuBarDisplay {
        case .iconOnly: nil
        case .temperature: hottestText
        case .fanSpeed: fanRPMText
        case .both: "\(hottestText) \(fanRPMText)"
        }
    }

    /// The fastest fan's speed, compact: `"5.0k"` above 1000 RPM.
    private var fanRPMText: String {
        guard let top = fans.map(\.actualRPM).max() else { return "--" }
        return top >= 1000 ? String(format: "%.1fk", top / 1000) : String(Int(top.rounded()))
    }

    // MARK: - Sensors browser & diagnostics

    /// A fresh full key dump for the sensors browser. Errors surface as an
    /// empty list plus `errorMessage` — the browser shows the message.
    func keyDump() async -> [SMCKeyDump] {
        do {
            return try await provider.keyDump()
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// The exportable diagnostics report as pretty JSON (PLAN.md §3.3 — what
    /// a "new Mac model" GitHub issue asks for).
    func diagnosticsJSON() async throws -> Data {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let report = try await DiagnosticsReport.generate(
            provider: provider, isSimulated: isSimulated, appVersion: version
        )
        return try report.jsonData()
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

    /// The menu bar readout, e.g. `"62°"`; `"--°"` before the first reading.
    /// Uses the hysteresis-stabilized `hottest` so label and badge agree.
    var hottestText: String {
        guard let hottest else { return "--°" }
        return "\(Int(hottest.celsius.rounded()))°"
    }
}
