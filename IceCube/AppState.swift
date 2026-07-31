// AppState.swift — the single observable model the menu-bar UI renders from; owns the 1 Hz polling loop.

import Foundation
import IceCubeKit
import Observation
import os

/// The app's only mutable state: the latest ``SMCSnapshot`` plus a short error
/// message when a read fails.
///
/// `AppState` polls its ``SMCProviding`` once per second on the main actor and
/// publishes the result via Observation — the menu bar label and the popover
/// both just read properties here. It never writes to hardware (nothing in the
/// app process does; see `SMCProviding`), and it never crashes on a provider
/// error: failures become a short message and polling keeps trying.
@Observable
final class AppState: PopoverLifecycleObserving {
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
    /// Built-in + user presets (Phase 4).
    let presets = PresetStore()
    /// Customizable chart/display preferences — the tinkerer surface.
    let chartSettings = ChartSettings()

    /// The hottest die-class sensor (CPU/GPU silicon), the curve input.
    var hottestDie: Double? {
        snapshot?.temperatures.hottestDieCelsius
    }

    /// Hottest CPU-core reading, for the compact readout.
    var cpuTempMax: Double? {
        snapshot?.temperatures.hottestCelsius(in: .cpu)
    }

    /// Hottest GPU reading, for the compact readout.
    var gpuTempMax: Double? {
        snapshot?.temperatures.hottestCelsius(in: .gpu)
    }

    /// Short human-readable description of the last read failure, or `nil`
    /// when the latest poll succeeded.
    private(set) var errorMessage: String?

    /// Surfaces a user-facing failure that did not come from polling — e.g. a
    /// file export that the system refused. The popover shows it like any other
    /// error; the next successful poll clears it.
    func reportError(_ message: String) {
        errorMessage = message
    }

    // MARK: - Charts (Phase 2)

    /// The dashboard's chart rows for the selected window, ready to render —
    /// already filtered to the rows the user has enabled (`chartSettings`).
    private(set) var chartRows: [ChartStore.Row] = []

    /// Frozen display (recording continues; see `togglePaused`).
    private(set) var isPaused = false

    /// Whether the menu-bar popover is actually on screen.
    ///
    /// `MenuBarExtra(.window)` keeps the popover's view graph alive after the
    /// first open, so publishing `chartRows` every second kept SwiftUI
    /// re-laying-out and re-drawing every chart into a window nobody could
    /// see — measured at ~17 % CPU sustained, against 0.3 % before the popover
    /// had ever been opened. Recording is unaffected: `chartStore.ingest`
    /// still runs every tick, so the history is complete when you next look.
    /// Observed, deliberately: `PopoverView`'s body branches on this, so
    /// SwiftUI has to see it change in order to swap the content out.
    private(set) var isPopoverVisible = false

    /// The popover came on screen: resume publishing and catch up at once, so
    /// it opens on current data rather than whatever was last published.
    func popoverAppeared() {
        Self.uiLog.notice("popover appeared — resuming live content")
        isPopoverVisible = true
        refreshCharts()
    }

    /// The popover went away: stop publishing and drop any in-flight render.
    func popoverDisappeared() {
        Self.uiLog.notice("popover disappeared — pausing live content")
        isPopoverVisible = false
        refreshTask?.cancel()
        refreshTask = nil
    }

    private static let uiLog = Logger(subsystem: "io.github.thijsvos.icecube", category: "ui")

    /// The shared x axis for all chart rows: trailing `window`, ending at the
    /// newest sample — every row scrolls in lockstep.
    private(set) var chartXDomain: ClosedRange<Date> = Date.distantPast ... Date.distantFuture

    /// What text accompanies the menu bar icon; persisted across launches.
    /// Icon-only also downshifts polling (nothing on screen needs 1 Hz).
    var menuBarDisplay: MenuBarDisplayMode {
        didSet {
            UserDefaults.standard.set(menuBarDisplay.rawValue, forKey: Self.menuBarDisplayKey)
            restartPolling()
        }
    }

    // MARK: - Settings (Phase 5)

    /// Display unit; storage and math stay °C, conversion happens in UI only.
    var temperatureUnit: TemperatureUnit {
        didSet { UserDefaults.standard.set(temperatureUnit.rawValue, forKey: Self.unitKey) }
    }

    /// Display sampling cadence (the daemon's safety tick is independent).
    var pollInterval: PollInterval {
        didSet {
            UserDefaults.standard.set(pollInterval.rawValue, forKey: Self.intervalKey)
            restartPolling()
        }
    }

    /// Temperature-threshold notifications.
    let alerts = AlertManager()

    private static let menuBarDisplayKey = "menuBarDisplay"
    private static let unitKey = "temperatureUnit"
    private static let intervalKey = "pollInterval"
    @ObservationIgnored private let chartStore = ChartStore()
    private var chartWindow: TimeInterval {
        chartSettings.window.seconds
    }

    // MARK: - Wiring

    /// Where readings come from. Injected so tests and simulated mode swap freely.
    private let provider: any SMCProviding
    /// Wraps `provider` in the snapshot stream; rebuilt when cadence changes.
    private var poller: SMCPoller
    /// The task consuming the polling stream; `nil` when stopped.
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Whether this launch has already decided whether to show the setup window.
    ///
    /// Lives here, on state with the app's lifetime, because the check runs in a
    /// `.task` on the MenuBarExtra **label** — a view AppKit tears down and
    /// rebuilds whenever the scene graph changes. Opening or closing any other
    /// window therefore restarted the task and re-ran the whole decision, so the
    /// setup window would reappear unbidden minutes after launch (observed:
    /// twice per launch, and again after closing the Sensors window). View-local
    /// state cannot express "once per launch" when the view itself is transient.
    @ObservationIgnored var hasEvaluatedSetupPrompt = false
    /// The in-flight chart re-render, cancelled when a newer one supersedes it.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(provider: any SMCProviding, isSimulated: Bool) {
        self.provider = provider
        self.isSimulated = isSimulated
        let interval = PollInterval(
            rawValue: UserDefaults.standard.integer(forKey: Self.intervalKey)
        ) ?? .oneSecond
        let display = MenuBarDisplayMode(
            rawValue: UserDefaults.standard.string(forKey: Self.menuBarDisplayKey) ?? ""
        ) ?? .temperature
        // Built from the SAME rule `restartPolling()` uses. This used to pass
        // `interval.rawValue` straight through, and since the downshift lived
        // only in a `didSet` — which does not fire during init — an icon-only
        // user relaunching (the normal login-item case) polled at 1 Hz for the
        // whole session and never got the energy win the setting promises.
        poller = SMCPoller(
            provider: provider,
            interval: .seconds(Self.effectiveSeconds(interval: interval, display: display))
        )
        pollInterval = interval
        menuBarDisplay = display
        temperatureUnit = TemperatureUnit(
            rawValue: UserDefaults.standard.string(forKey: Self.unitKey) ?? ""
        ) ?? .celsius
        // Explicit, because constructing a HelperManager no longer starts its
        // own timers — see `HelperManager.start()`. The app is the only caller;
        // tests drive `maintainOnce()` directly instead.
        helper.start()
    }

    /// Rebuilds the polling stream with the effective cadence. Icon-only
    /// display needs no 1 Hz updates while the popover is closed, so it
    /// polls at ≥ 5 s — a real energy win for a menu-bar resident.
    private static func effectiveSeconds(interval: PollInterval, display: MenuBarDisplayMode) -> Int {
        display == .iconOnly ? max(interval.rawValue, 5) : interval.rawValue
    }

    private func restartPolling() {
        let seconds = Self.effectiveSeconds(interval: pollInterval, display: menuBarDisplay)
        pollTask?.cancel()
        pollTask = nil
        poller = SMCPoller(provider: provider, interval: .seconds(seconds))
        start()
    }

    deinit {
        // Task.cancel() is nonisolated and safe to call from deinit.
        pollTask?.cancel()
        refreshTask?.cancel()
    }

    // MARK: - Polling

    /// Swaps the menu bar item between SwiftUI's and ours. Nil until ``start()``.
    @ObservationIgnored private(set) var menuBar: MenuBarModeCoordinator?

    /// Re-reads the hosting decision.
    ///
    /// Driven from the 1 Hz poll rather than read once at launch, so turning the
    /// preference on takes effect immediately. This app has no vocabulary for
    /// "takes effect on relaunch" and should not grow one — and a launch-time
    /// read has already shipped here as a bug once.
    private func reconcileMenuBarMode() {
        guard let menuBar else { return }
        menuBar.apply(MenuBarMode.resolve(
            prefersSilentOptionClick: UserDefaults.standard.bool(forKey: MenuBarMode.preferenceKey),
            isSetUp: helper.registration == .enabled
        ))
    }

    /// Starts consuming the 1 Hz polling stream. A second call is a no-op.
    func start() {
        guard pollTask == nil else { return }
        if menuBar == nil {
            menuBar = MenuBarModeCoordinator(
                host: StatusItemController(state: self), lifecycle: self
            )
        }
        // Once, in parallel with polling: the inventory is a property of the
        // Mac, not of the moment. A failure is not worth reporting — the only
        // consumer is the Sensors window's opening height, which falls back to
        // the reporting count.
        Task { [weak self] in
            guard let self, let inventory = try? await provider.sensorInventory() else { return }
            sensorInventoryCount = inventory.count
        }
        let events = poller.events()
        pollTask = Task { [weak self] in
            for await event in events {
                guard let self else { return } // strong only per event
                reconcileMenuBarMode()
                switch event {
                case let .snapshot(new):
                    snapshot = new
                    hottest = new.hottest(stickingTo: hottest?.key)
                    // Assigned only on a change: see `sensorRowCount`. Writing
                    // the same number every tick would still be a mutation, and
                    // Observation does not care that the value matched.
                    //
                    // Sized from what this Mac HAS, not from what is reporting
                    // this second — a power-gated cluster is silent for up to
                    // ~85 s after launch, and macOS saves the window's frame
                    // the first time it opens, so sizing to the momentary list
                    // would persist a window too short for the list the user
                    // sees from then on. `max` covers the unmapped-Mac path,
                    // where the enumerated list is the inventory.
                    let rows = SensorsWindowMetrics.rowCount(
                        temperatures: max(sensorInventoryCount, new.temperatures.count),
                        fans: new.fans.count
                    )
                    if rows != sensorRowCount {
                        sensorRowCount = rows
                    }
                    consecutiveFailures = 0
                    errorMessage = nil
                    alerts.evaluate(dieCelsius: hottestDie)
                    // History records even while the display is paused, and
                    // while the popover is closed — pause freezes the picture,
                    // not the recording.
                    await chartStore.ingest(new)
                    if !isPaused, isPopoverVisible {
                        chartRows = await chartStore.rows(window: chartWindow)
                            .filter { chartSettings.includesRow(id: $0.id) }
                        chartXDomain = new.date.addingTimeInterval(-chartWindow) ... new.date
                    }
                case let .failure(error):
                    // Keep the last good snapshot on screen. One transient
                    // miss is silent; only a persistent failure (3+ ticks)
                    // earns the error row — appearing/disappearing captions
                    // are exactly the layout jump we forbid.
                    //
                    // A typed error lets us tell permanent from transient:
                    // smcKeyNotFound on an unmapped Mac will never resolve by
                    // waiting, and it is precisely the case the diagnostics
                    // export exists to turn into a curated key map. Waiting
                    // three ticks to say so — and saying nothing about what to
                    // do — was the cost of flattening this to a String.
                    consecutiveFailures += 1
                    switch error {
                    case .smcKeyNotFound, .smcDecodingFailed:
                        errorMessage = error.localizedDescription
                            + " Export Diagnostics to help map this Mac."
                    case .smcNotPrivileged:
                        // Documented as "the app should never see this".
                        errorMessage = error.localizedDescription
                    default:
                        if consecutiveFailures >= 3 {
                            errorMessage = error.localizedDescription
                        }
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

    /// Re-renders rows for the current window and row filter. Call after a
    /// window change, a row-visibility toggle, or unpause.
    func refreshCharts() {
        guard !isPaused, isPopoverVisible else { return }
        // Owned, not fired-and-forgotten: DashboardView calls this from two
        // onChange hooks, and each call raced the poll loop for the same two
        // properties. Both read `chartWindow` before suspending and wrote after,
        // so whichever resumed last won — a window switch could leave the
        // previous window's domain on screen, which is exactly the axis rescale
        // mid-glance the anti-jump rules forbid.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let window = chartWindow // capture before suspending…
            let rows = await chartStore.rows(window: window)
            // …and re-validate after, so a superseded pass writes nothing.
            guard !Task.isCancelled, window == chartWindow else { return }
            if let end = rows.first?.series.first?.buckets.last?.time ?? snapshot?.date {
                chartXDomain = end.addingTimeInterval(-window) ... end
            }
            chartRows = rows.filter { chartSettings.includesRow(id: $0.id) }
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
        // Runs the write-path check first when the daemon is there and has not
        // already been asked this session. Everything else in the report
        // describes READS, and a "new Mac model" issue is almost always about
        // WRITES — so exporting without this produced a file that could not
        // answer the question it was attached to. The check commands no change
        // in fan speed (see `DaemonCore.selfTestWritePath`).
        if helper.writePathReport == nil {
            await helper.runWritePathSelfTest()
        }
        let report = try await DiagnosticsReport.generate(
            provider: provider, isSimulated: isSimulated, appVersion: version,
            writePath: helper.writePathReport
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

    /// How many rows the Sensors window's readable list will draw — the input
    /// to its opening height (see ``SensorsWindowMetrics``). `nil` until the
    /// first snapshot lands, which is not the same as zero.
    ///
    /// Its own property, rather than the scene reading `temperatures.count`
    /// directly, because the App's scene body is what consumes it: observing
    /// `snapshot` there would re-evaluate the whole scene graph — `MenuBarExtra`
    /// label included — once a second, forever, to answer a question whose
    /// answer changes at most once. Discovery fixes the sensor list at the first
    /// poll and `SensorStabilizer` guarantees every discovered sensor stays in
    /// every published reading, so this goes `nil` → *n* on that first snapshot
    /// and then holds for the life of the process.
    ///
    /// It must stay an **observed** property read inside the scene body: that
    /// registration is what makes SwiftUI re-evaluate `App.body` when the count
    /// arrives, and re-evaluating is what refreshes the stored `.defaultSize`.
    /// Measured — a version of this that read the same number from a plain
    /// global opened every window at the floor instead, silently and with no
    /// compile error.
    private(set) var sensorRowCount: Int?

    /// How many sensors this Mac **has**, as opposed to how many are reporting
    /// — see `SMCProviding.sensorInventory()`. Fetched once, because it is a
    /// property of the hardware.
    ///
    /// Not observed: only ``sensorRowCount`` is read from the scene body, and
    /// this feeds it. 0 until the fetch lands, which the `max` at the call site
    /// absorbs.
    @ObservationIgnored private var sensorInventoryCount = 0

    /// The menu bar readout, e.g. `"62°"`; `"--°"` before the first reading.
    /// Uses the hysteresis-stabilized `hottest` so label and badge agree,
    /// and the user's display unit.
    var hottestText: String {
        guard let hottest else { return "--°" }
        return temperatureUnit.text(hottest.celsius)
    }

    /// The chart history as CSV (Phase 5 export).
    func chartsCSV() async -> String {
        await chartStore.csv()
    }
}
