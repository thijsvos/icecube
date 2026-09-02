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
    /// Consecutive failed polls, kept here because the tick owns the counting
    /// and ``PollErrorPolicy`` owns the rule.
    ///
    /// The 3-in-a-row wait applies to *transient* faults only, and that
    /// distinction is the whole point of the split: an SMC that misses a read on
    /// healthy hardware must not flash a caption in and out of the layout, but a
    /// Mac whose sensor map is wrong will be wrong on every subsequent tick too,
    /// so `.smcKeyNotFound`, `.smcDecodingFailed` and `.smcNotPrivileged` speak
    /// on the first failure and ignore this number entirely.
    @ObservationIgnored private var consecutiveFailures = 0
    /// True when running against `MockSMCProvider` — the UI shows a badge so
    /// simulated numbers are never mistaken for real hardware.
    let isSimulated: Bool
    /// Where this launch's preferences live — real `UserDefaults`, or an
    /// in-memory store when simulated so a simulated session cannot steer the
    /// real app's next launch.
    @ObservationIgnored let defaults: any KeyValueStore

    static let persistCurveKey = "persistCurve"
    static let dismissedSetupKey = "hasDismissedSetup"
    static let insideEnabledKey = "experimental.inside"
    static let insideAnimationKey = "experimental.inside.animates"
    static let insideInPopoverKey = "experimental.inside.popover"
    static let forecastEnabledKey = "experimental.forecast"

    /// The app-wide "keep the curve running when Ice Cube quits" toggle.
    ///
    /// Here, rather than in three separate `@AppStorage` properties, because
    /// `@AppStorage` binds to `UserDefaults.standard` and cannot be pointed at
    /// the injected store — `SimulatedEnvironment.Defaults` is a plain
    /// `KeyValueStore`, not a `UserDefaults`. So the popover, the curve editor
    /// and the Settings tab each read a *different* value from
    /// `FanControlMemory.persistsCurveWithoutApp`, which does go through the
    /// seam: in a simulated session the toggle had no effect on what
    /// `cyclePreset` and `powerSourceChanged` actually sent, **and** flipping it
    /// wrote into the owner's real preferences domain. That is the hole
    /// `CompositionRoot` exists to close, and `ChartSettings` was already fixed
    /// for exactly this reason.
    var persistsCurveWithoutApp: Bool {
        didSet { defaults.set(persistsCurveWithoutApp, forKey: Self.persistCurveKey) }
    }

    /// Whether ⌥-click cycles presets without opening the popover.
    ///
    /// Same seam, same reason — and `reconcileMenuBarMode` already read this one
    /// through the injected store, so the `@AppStorage` copy in Settings was
    /// writing somewhere the reader never looked.
    var prefersSilentOptionClick: Bool {
        didSet {
            defaults.set(prefersSilentOptionClick, forKey: MenuBarMode.preferenceKey)
            reconcileMenuBarMode()
        }
    }

    /// Whether the user has actually CLOSED the guided setup — not merely that
    /// it was displayed once.
    ///
    /// It used to mean "shown", set the moment the window opened, which the
    /// relocation flow then broke: moving to /Applications relaunches the app,
    /// so the pre-move instance spent the one-shot flag and the relaunched one
    /// — the instance the user actually interacts with — decided setup had
    /// already been handled and showed nothing. The user was left in a menu-bar
    /// app with no visible way forward, immediately after being told setup would
    /// continue. Recording *dismissal* instead survives any number of relaunches
    /// and still never nags someone who said no.
    ///
    /// Here rather than in `@AppStorage` for the same seam reason as the two
    /// above: a simulated session that closed the setup window wrote this into
    /// the real preferences domain, so a *simulated* run could make the next
    /// real launch skip onboarding.
    var hasDismissedSetup: Bool {
        didSet { defaults.set(hasDismissedSetup, forKey: Self.dismissedSetupKey) }
    }

    /// Whether the experimental **Inside** window is available at all.
    ///
    /// Off until the user turns it on in Settings, and while it is off there is
    /// no route to the window: the popover shows no entry and
    /// ``WindowOpener/open(_:using:)`` is never called with its id. An
    /// "experimental" feature that is reachable anyway is not experimental.
    ///
    /// `bool(forKey:)` returning `false` for a key nobody has written is
    /// *exactly* the wanted default here, which is worth stating because the
    /// same call was the wrong reader in `ChartStore.Window`: there, `0` was a
    /// legitimate stored value, so "absent" and "one minute" were indis-
    /// tinguishable and the documented 5-minute default could never apply. The
    /// difference is that `false` here genuinely means *not enabled* — there is
    /// no state this preference can be in that `false` would misrepresent.
    ///
    /// Same injected-store seam as the three above: a simulated session must
    /// not be able to switch a feature on in the owner's real preferences.
    var isInsideEnabled: Bool {
        didSet { defaults.set(isInsideEnabled, forKey: Self.insideEnabledKey) }
    }

    /// Whether the diagnosis window shows where the temperature is heading.
    ///
    /// Off by default, and behind the same injected `defaults` seam the Inside
    /// switches use, so a simulated session cannot turn a feature on in the
    /// owner's real preferences.
    ///
    /// Opt-in for a reason this row has and the others do not: every sibling in
    /// that window reports something measured, and this one reports a
    /// projection from a model that fits one thermal pole to a machine with
    /// two. `ForecastCopy` works hard to keep the two legible apart, and a
    /// switch the user threw themselves is the last part of that.
    ///
    /// Also `false` genuinely means *not enabled* here, so `bool(forKey:)`
    /// returning `false` for an absent key is exactly the wanted default —
    /// the same argument ``isInsideEnabled`` makes.
    var isForecastEnabled: Bool {
        didSet {
            defaults.set(isForecastEnabled, forKey: Self.forecastEnabledKey)
            if !isForecastEnabled {
                forecast = nil
            }
        }
    }

    /// Whether a compact Inside runs inside the popover as well as in its own
    /// window.
    ///
    /// Separate from ``isInsideEnabled`` because they are different asks. The
    /// window is somewhere you go; the popover is what you glance at, and
    /// putting a continuously-redrawing drawing in the surface people open
    /// twenty times a day is a bigger commitment than opening one on purpose.
    /// Only reachable while the feature itself is on.
    var showsInsideInPopover: Bool {
        didSet { defaults.set(showsInsideInPopover, forKey: Self.insideInPopoverKey) }
    }

    /// Whether the Inside window animates, or `nil` to follow the system's
    /// Reduce Motion setting.
    ///
    /// Three states, not two, and the third is the point. macOS Reduce Motion
    /// is the right default to respect — but it is a blunt instrument here:
    /// it exists for parallax and full-screen zooms that provoke vestibular
    /// symptoms, and applying it to this window switches off the one thing the
    /// window is for. Someone who deliberately turned on an experimental live
    /// drawing of their fans has expressed an intent worth honouring over a
    /// global default, so they can say so — and someone who has not said
    /// anything still gets the system's answer.
    ///
    /// `nil` is why ``KeyValueStore/object(forKey:)`` exists: `bool(forKey:)`
    /// cannot tell "never chosen" from "chosen false", and here those two must
    /// behave differently.
    var insideAnimation: Bool? {
        didSet {
            if let insideAnimation {
                defaults.set(insideAnimation, forKey: Self.insideAnimationKey)
            } else {
                defaults.removeObject(forKey: Self.insideAnimationKey)
            }
        }
    }

    /// Helper daemon lifecycle + fan-control commands (Phase 3).
    ///
    /// Injected, never constructed here. It used to be `HelperManager()` as a
    /// stored property, which defaults to the real XPC client, the real launchd
    /// registrar and the real power watcher — and, being a stored-property
    /// initialiser, ran *before* `isSimulated` was even assigned, so it could
    /// not have consulted the flag even if it had wanted to. That is how a
    /// simulated launch came to drive the owner's real fans.
    let helper: HelperManager
    /// Built-in + user presets (Phase 4). Injected for the same reason.
    let presets: PresetStore
    /// Persisted cooling-efficiency records and their trend. Injected with
    /// **no default value**: a default would have to name the real file and
    /// would re-create exactly the isolation hole `CompositionRoot` exists
    /// to close (the documented 2026-08-02 incident's shape).
    let history: CoolingHistoryStore

    /// Owned here rather than by the Settings window, where it used to be a
    /// `@State`.
    ///
    /// That placement was the reason the check never ran on its own: the object
    /// did not exist until somebody opened Settings, so the only code path that
    /// could learn about a release was the button inside it. Every release so
    /// far is unsigned and installed by hand, which makes "the user never finds
    /// out" the expensive failure.
    let updates: UpdateChecker
    /// Customizable chart/display preferences — the tinkerer surface.
    ///
    /// Built from the injected `defaults`, not from `UserDefaults.standard`.
    /// It used to construct its own, which quietly exempted twelve preferences
    /// from simulated isolation.
    let chartSettings: ChartSettings

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

    /// Thermal resistance in °C/W, or nil while the machine is not settled
    /// enough to measure it. See ``CoolingEfficiency`` and `docs/THERMAL.md`.
    ///
    /// Published rather than computed on demand so the view never triggers the
    /// window arithmetic during layout.
    private(set) var coolingResistance: Double?

    /// Decisions the daemon has made since the last poll tick.
    ///
    /// Buffered rather than acted on immediately: they arrive on the helper's
    /// 5 s status refresh, and the alert rules also need the fan readings, which
    /// arrive on the 1 s poll. Draining here gives the rules exactly one
    /// evaluation point per tick with both inputs current.
    @ObservationIgnored private var pendingDecisions: [DecisionEvent] = []

    /// The rolling window behind ``coolingResistance``.
    @ObservationIgnored private var cooling = CoolingEfficiency.Tracker()

    /// The degradation verdict, re-evaluated **only** on load and on a new
    /// record — the deliberate inverse of `refreshDiagnosis`, which runs
    /// every tick because it describes this instant and is stale a second
    /// later. The trend describes months and is a pure function of the
    /// record set, so recomputing between records would burn cycles to
    /// produce the identical answer. Main-actor evaluation is fine because
    /// records arrive at most every five minutes over a retention-capped
    /// set (`CoolingHistory.maximumDayAggregates` — the cap's comment says
    /// this dependency out loud).
    private(set) var coolingTrend: CoolingTrend.Verdict = .noHistory

    /// The gate between the live settle window and the history file. Kit
    /// value type, held like the tracker above it.
    @ObservationIgnored private var historyRecorder = CoolingRecorder()

    /// How fast this Mac's die approaches what it is heading for.
    ///
    /// Fed every tick, like ``cooling`` and for the same reason inverted: the
    /// settle window needs an unbroken run of samples because a gap resets it,
    /// and this needs one because a gap costs it the three-minute window an
    /// estimate spans. Fed regardless of whether the feature is switched on —
    /// it is arithmetic on samples already being read, and a user who enables
    /// the row should not then wait twelve minutes for it to say anything.
    @ObservationIgnored private var timeConstant = ThermalTimeConstant()

    /// What each fan speed buys on this Mac, refitted **only when a record is
    /// appended** — the same reasoning as ``coolingTrend`` directly above.
    /// It is a pure function of the record set, so recomputing between records
    /// would burn cycles to produce an identical answer.
    @ObservationIgnored private var coolingLaw = CoolingLaw()

    /// Clears the history and re-evaluates at once — the verdict must not
    /// keep claiming "worse than June" about readings that no longer exist.
    func clearCoolingHistory() {
        history.clear()
        coolingTrend = history.history
            .map { CoolingTrend.evaluate($0, now: Date()) } ?? .noHistory
    }

    /// Records an "I cleaned it" boundary and re-evaluates: the baseline
    /// moves, so the sentence built on it must move in the same breath.
    func markCoolingServiced() {
        history.markServiced(at: Date())
        coolingTrend = history.history
            .map { CoolingTrend.evaluate($0, now: Date()) } ?? .noHistory
    }

    // MARK: - Diagnosis ("why is it hot?")

    /// The live verdict, or `nil` while the Diagnose window is closed.
    ///
    /// See ``ThermalDiagnosis``. Published rather than computed on demand so
    /// the view never runs the reasoning during layout.
    private(set) var diagnosis: ThermalDiagnosis.Verdict?

    /// How many time-constant estimates have been accepted so far.
    ///
    /// Read-only, and not published: it changes on a timescale no view should
    /// redraw for. Exists so a test can watch the estimator actually
    /// accumulate — see ``ingestForecastSample(_:)``.
    var forecastEstimateCount: Int {
        timeConstant.estimateCount
    }

    /// Where the temperature is heading, or `nil` when the window is shut or
    /// the feature is off.
    ///
    /// Published rather than computed on demand, for the reason ``diagnosis``
    /// gives: the view must never run the reasoning during layout.
    private(set) var forecast: ThermalForecast.Verdict?

    /// The most recent per-process sample. Kept between ticks so a pass that
    /// cannot produce a rate (the first one) leaves the previous answer up
    /// rather than blanking the list.
    @ObservationIgnored private var processReading: ProcessEnergyReading?

    /// Whether the Diagnose window is on screen.
    ///
    /// Gates the sampling, for the same measured reason `isPopoverVisible`
    /// gates chart publishing: a pass walks every PID on the machine, and doing
    /// that every second for a window nobody has open is exactly the waste that
    /// cost ~17 % sustained CPU before the popover gate existed. Unlike the
    /// cooling window, nothing is lost by not recording — the verdict is about
    /// this instant, so it is correct the moment you look.
    @ObservationIgnored private var isDiagnosisVisible = false

    /// The Diagnose window opened: start sampling.
    func diagnosisAppeared() {
        Self.uiLog.notice("diagnosis window appeared — sampling processes")
        isDiagnosisVisible = true
        // The sampler outlives the window, so its last cumulative reading is
        // from whenever the window was last closed. Differencing against that
        // divides one interval's energy by however long the window was shut,
        // and the first pass on screen shows every process at a few hundredths
        // of a watt — "nothing is using power", at the exact moment someone
        // opened this to ask what is.
        Task { [processSampler] in await processSampler.reset() }
    }

    /// The Diagnose window closed: stop sampling and drop what was collected.
    ///
    /// Dropping is deliberate. Process names are the most sensitive thing this
    /// app touches, and there is no reason to keep a list of them alive in a
    /// menu-bar process that will run for days after the window is shut.
    func diagnosisDisappeared() {
        Self.uiLog.notice("diagnosis window disappeared — discarding process data")
        isDiagnosisVisible = false
        processReading = nil
        diagnosis = nil
        forecast = nil
    }

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

    private static let uiLog = Logger(subsystem: HelperConstants.logSubsystem, category: "ui")

    /// The shared x axis for all chart rows: trailing `window`, ending at the
    /// newest sample — every row scrolls in lockstep.
    private(set) var chartXDomain: ClosedRange<Date> = Date.distantPast ... Date.distantFuture

    /// What text accompanies the menu bar icon; persisted across launches.
    /// Icon-only also downshifts polling (nothing on screen needs 1 Hz).
    var menuBarDisplay: MenuBarDisplayMode {
        didSet {
            defaults.set(menuBarDisplay.rawValue, forKey: Self.menuBarDisplayKey)
            restartPolling()
        }
    }

    // MARK: - Settings (Phase 5)

    /// Display unit; storage and math stay °C, conversion happens in UI only.
    var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: Self.unitKey) }
    }

    /// Display sampling cadence (the daemon's safety tick is independent).
    var pollInterval: PollInterval {
        didSet {
            defaults.set(pollInterval.rawValue, forKey: Self.intervalKey)
            restartPolling()
        }
    }

    /// Temperature-threshold notifications.
    let alerts: AlertManager

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
    /// Makes the menu-bar host when polling starts.
    ///
    /// Injected because the real one — `StatusItemController` — reaches AppKit
    /// and pulls `PopoverView` and the whole popover tree behind it. That
    /// single reference is what kept this 420-line type out of the test bundle
    /// entirely, at 0 % coverage, while every rule in it went unpinned.
    ///
    /// Required rather than defaulted: a default would have to name
    /// `StatusItemController` here and re-create the dependency, and an
    /// optional would let a caller silently ship without a menu bar. There is
    /// exactly one production call site, in `IceCubeApp`.
    @ObservationIgnored private let menuBarHost: @MainActor (AppState) -> any MenuBarHosting
    /// Who is drawing power. Injected via ``CompositionRoot`` so a simulated
    /// launch reads no real PID — see ``ProcessSampling``.
    @ObservationIgnored private let processSampler: any ProcessSampling
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

    /// Takes the whole graph rather than assembling it, so that simulated mode
    /// is decided in exactly one place. See ``CompositionRoot``.
    convenience init(
        graph: CompositionRoot.Graph,
        menuBarHost: @escaping @MainActor (AppState) -> any MenuBarHosting
    ) {
        self.init(
            provider: graph.provider,
            isSimulated: graph.isSimulated,
            helper: graph.helper,
            presets: graph.presets,
            history: graph.history,
            defaults: graph.defaults,
            processes: graph.processes,
            menuBarHost: menuBarHost
        )
    }

    init(
        provider: any SMCProviding,
        isSimulated: Bool,
        helper: HelperManager,
        presets: PresetStore,
        history: CoolingHistoryStore,
        defaults: any KeyValueStore,
        processes: any ProcessSampling = MockProcessSampler(),
        menuBarHost: @escaping @MainActor (AppState) -> any MenuBarHosting
    ) {
        self.menuBarHost = menuBarHost
        self.provider = provider
        self.isSimulated = isSimulated
        self.helper = helper
        self.presets = presets
        self.history = history
        self.defaults = defaults
        chartSettings = ChartSettings(defaults: defaults)
        updates = UpdateChecker(defaults: defaults)
        persistsCurveWithoutApp = defaults.bool(forKey: Self.persistCurveKey)
        prefersSilentOptionClick = defaults.bool(forKey: MenuBarMode.preferenceKey)
        hasDismissedSetup = defaults.bool(forKey: Self.dismissedSetupKey)
        isInsideEnabled = defaults.bool(forKey: Self.insideEnabledKey)
        showsInsideInPopover = defaults.bool(forKey: Self.insideInPopoverKey)
        isForecastEnabled = defaults.bool(forKey: Self.forecastEnabledKey)
        insideAnimation = defaults.object(forKey: Self.insideAnimationKey) as? Bool
        // Defaulted to the mock rather than to `SystemProcessSampler`, so a
        // caller that forgets the argument reads fiction instead of the user's
        // real process list. The safe default is the one that touches nothing.
        processSampler = processes
        // Simulated temperatures are a sine wave with random spikes; posting
        // real Notification Centre banners about them would be writing fiction
        // into the user's actual notification history.
        alerts = AlertManager(defaults: defaults, deliversNotifications: !isSimulated)
        let interval = PollInterval(
            rawValue: defaults.integer(forKey: Self.intervalKey)
        ) ?? .oneSecond
        let display = MenuBarDisplayMode(
            rawValue: defaults.string(forKey: Self.menuBarDisplayKey) ?? ""
        ) ?? .temperature
        // Built from the SAME rule `restartPolling()` uses. This used to pass
        // `interval.rawValue` straight through, and since the downshift lived
        // only in a `didSet` — which does not fire during init — an icon-only
        // user relaunching (the normal login-item case) polled at 1 Hz for the
        // whole session and never got the energy win the setting promises.
        poller = SMCPoller(
            provider: provider,
            interval: .seconds(interval.effectiveSeconds(display: display))
        )
        pollInterval = interval
        menuBarDisplay = display
        temperatureUnit = TemperatureUnit(
            rawValue: defaults.string(forKey: Self.unitKey) ?? ""
        ) ?? .celsius
        // Explicit, because constructing a HelperManager no longer starts its
        // own timers — see `HelperManager.start()`. The app is the only caller;
        // tests drive `maintainOnce()` directly instead.
        helper.start()
        // Once at launch; thereafter only when a record lands (see
        // `coolingTrend`). An empty store honestly reads `.noHistory`.
        if let loaded = history.history {
            coolingTrend = CoolingTrend.evaluate(loaded, now: Date())
        }
    }

    /// Rebuilds the polling stream with the effective cadence.
    ///
    /// Icon-only display has no reading on screen to keep current, so it polls
    /// at ≥ 5 s whatever the user picked — a real energy win for a menu-bar
    /// resident. The downshift is a property of the *display mode alone*
    /// (``PollInterval/effectiveSeconds(display:)``), not of whether the popover
    /// happens to be open: an icon-only user who opens the popover gets its
    /// gauges and charts at the slower cadence too. That is the honest trade —
    /// the alternative is restarting the poller on every popover open and close,
    /// which is a second thing to keep in step with the setting, for a window
    /// that is usually shut.
    private func restartPolling() {
        let seconds = pollInterval.effectiveSeconds(display: menuBarDisplay)
        let wasRunning = pollTask != nil
        pollTask?.cancel()
        pollTask = nil
        poller = SMCPoller(provider: provider, interval: .seconds(seconds))
        // Re-subscribe only. This used to call `start()`, whose "a second call
        // is a no-op" guard is `pollTask == nil` — which `restartPolling` has
        // just made true, so the guard could never see it. Every poll-interval
        // or menu-bar-display change therefore re-ran all of `start()`'s
        // once-per-launch work: another update check, another sensor
        // inventory, another `onFreshDecisions` assignment.
        //
        // `start()` is still the right call when polling was never running,
        // because then that setup genuinely has not happened yet.
        if wasRunning {
            consumePollingEvents()
        } else {
            start()
        }
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
            prefersSilentOptionClick: defaults.bool(forKey: MenuBarMode.preferenceKey),
            isSetUp: helper.registration == .enabled
        ))
    }

    /// Recomputes the "why is it hot?" verdict, if anyone is looking.
    ///
    /// The curve comes from the **daemon's** reported status rather than from
    /// whatever the app last sent: the question is what is actually driving the
    /// fans right now, and those two differ whenever a command was refused,
    /// deferred until wake, or overridden by a safety rule.
    private func refreshDiagnosis(_ new: SMCSnapshot) async {
        guard isDiagnosisVisible else { return }
        if let reading = await processSampler.sample() {
            processReading = reading
        }
        diagnosis = ThermalDiagnosis.diagnose(
            snapshot: new,
            resistance: coolingResistance,
            processes: processReading,
            curve: helper.status?.activeCurve,
            isCharging: helper.isCharging,
            // The previous verdict is the hysteresis state, so there is no
            // separate property to keep in step with it.
            wasWarmFromCharging: diagnosis?.charging.isWarm ?? false
        )
        forecast = isForecastEnabled ? projectForecast(new) : nil
    }

    /// Offers one tick to the time-constant estimator.
    ///
    /// Skips silently when the snapshot is missing any of the three inputs, for
    /// the same reason `CoolingEfficiency.Tracker` clears its window: a sample
    /// stitched across a gap is worse than no sample.
    ///
    /// Internal rather than private so a test can drive it with scripted
    /// snapshots. **The call site in `consumePollingEvents` is not covered**,
    /// and cannot be at test timescales: one estimate spans three minutes of
    /// steady machine, so a run long enough to observe the difference between
    /// feeding and not feeding is a run no test suite should contain. Deleting
    /// that one line would leave every test green and the forecast permanently
    /// silent. Stated rather than pretended away, in the same spirit as
    /// `SimulatedIsolationTests`' note about the line wiring `ChartSettings` to
    /// its store.
    func ingestForecastSample(_ snapshot: SMCSnapshot) {
        guard let watts = snapshot.power,
              let ambient = CoolingEfficiency.ambient(from: snapshot.temperatures),
              let die = snapshot.temperatures.hottestDieCelsius
        else { return }
        let usable = snapshot.fans.filter(\.hasUsableRange)
        let fraction = usable.isEmpty
            ? 0
            : usable.map { $0.actualRPM / $0.maxRPM }.reduce(0, +) / Double(usable.count)
        timeConstant.ingest(ThermalTimeConstant.Observation(
            date: snapshot.date,
            dieCelsius: die,
            ambientCelsius: ambient,
            watts: watts,
            fanFraction: fraction
        ))
    }

    /// The projection for this tick, or a named gap.
    ///
    /// `isLoadSteady` is answered by the settle tracker rather than guessed:
    /// a settled window is by definition one whose draw has held within
    /// `CoolingEfficiency.powerTolerance`, which is the same condition the
    /// forecast needs for its equilibrium to mean anything.
    private func projectForecast(_ snapshot: SMCSnapshot) -> ThermalForecast.Verdict {
        guard let watts = snapshot.power,
              let ambient = CoolingEfficiency.ambient(from: snapshot.temperatures),
              let die = snapshot.temperatures.hottestDieCelsius
        else { return .unavailable(.loadNotSteady) }
        return ThermalForecast.project(
            dieCelsius: die,
            ambientCelsius: ambient,
            watts: watts,
            fans: snapshot.fans,
            curve: helper.status?.activeCurve,
            law: coolingLaw,
            tau: timeConstant.tau,
            estimateCount: timeConstant.estimateCount,
            isLoadSteady: cooling.isSettled
        )
    }

    /// Starts consuming the 1 Hz polling stream. A second call is a no-op.
    func start() {
        guard pollTask == nil else { return }
        if menuBar == nil {
            menuBar = MenuBarModeCoordinator(host: menuBarHost(self), lifecycle: self)
        }
        if isSimulated {
            // No daemon in simulated mode, so nothing would ever populate the
            // decision timeline. See `seedSimulatedDecisions`.
            helper.seedSimulatedDecisions()
        } else {
            // Not in simulated mode, for the same reason notifications are
            // suppressed there: a fake run must not reach the network or leave
            // a real timestamp behind. Throttled to once a day by `checkIfDue`.
            Task { [weak self] in await self?.updates.checkIfDue() }
        }
        // Once, in parallel with polling: the inventory is a property of the
        // Mac, not of the moment. A failure is not worth reporting — the only
        // consumer is the Sensors window's opening height, which falls back to
        // the reporting count.
        Task { [weak self] in
            guard let self, let inventory = try? await provider.sensorInventory() else { return }
            sensorInventoryCount = inventory.count
        }
        helper.onFreshDecisions = { [weak self] fresh in
            self?.pendingDecisions.append(contentsOf: fresh)
        }
        consumePollingEvents()
    }

    /// Subscribes `pollTask` to the current poller's stream.
    ///
    /// Split out of ``start()`` so ``restartPolling()`` can swap the poller
    /// without re-running the once-per-launch work that sits above this.
    private func consumePollingEvents() {
        let events = poller.events()
        pollTask = Task { [weak self] in
            for await event in events {
                guard let self else { return } // strong only per event
                reconcileMenuBarMode()
                switch event {
                case let .snapshot(new):
                    snapshot = new
                    hottest = new.hottest(stickingTo: hottest?.key)
                    // Fed every tick, including while the popover is shut: the
                    // settle window needs an unbroken run of samples, and a gap
                    // resets it. Recording here rather than in the view is what
                    // makes a reading available the moment someone looks.
                    cooling.ingest(new)
                    coolingResistance = cooling.resistance
                    ingestForecastSample(new)
                    // The recorder's spacing runs on the monotonic clock and
                    // its stamps on the snapshot's wall clock, so an NTP step
                    // can move a record's date but never cause a burst or a
                    // stall (the SafetyMonitor two-clock precedent).
                    if let record = historyRecorder.ingest(
                        new, settled: cooling.settledWindow, elapsed: ContinuousClock().now
                    ) {
                        history.append(record, fans: new.fans, now: new.date)
                        if let loaded = history.history {
                            coolingTrend = CoolingTrend.evaluate(loaded, now: new.date)
                            coolingLaw = CoolingLaw.fit(loaded)
                        }
                    }
                    await refreshDiagnosis(new)
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
                    alerts.evaluate(dieCelsius: hottestDie, style: temperatureUnit.style)
                    // The other half: the daemon losing control, the guardian
                    // stepping in, or the fans stuck at maximum. Silent until
                    // 2026-08-07 — see `ControlAlertRules`.
                    let fresh = pendingDecisions
                    pendingDecisions.removeAll()
                    alerts.evaluateControl(freshDecisions: fresh, fans: new.fans, now: new.date)
                    // History records even while the display is paused, and
                    // while the popover is closed — pause freezes the picture,
                    // not the recording.
                    await chartStore.ingest(new)
                    if !isPaused, isPopoverVisible {
                        // Capture before suspending, then re-validate — the same
                        // rule `refreshCharts()` follows. Its comment names this
                        // loop as the other half of that race, but only its own
                        // side was ever fixed: reading `chartWindow` on both
                        // sides of the await let the rows come from the window
                        // the user just left and the axis from the one they
                        // just picked, which is the mid-glance rescale the
                        // anti-jump rules forbid.
                        let window = chartWindow
                        let rows = await chartStore.rows(window: window)
                        if window == chartWindow {
                            chartRows = rows.filter { chartSettings.includesRow(id: $0.id) }
                            chartXDomain = new.date.addingTimeInterval(-window) ... new.date
                        }
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
                    // The rule itself lives in `PollErrorPolicy`, pure and
                    // tested. Only the counter belongs to the tick.
                    if let message = PollErrorPolicy.message(
                        for: error, consecutiveFailures: consecutiveFailures
                    ) {
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
    /// `nil` for icon-only. Formatting lives in ``MenuBarLabel`` so it can be
    /// tested without standing up an `AppState`.
    var menuBarText: String? {
        MenuBarLabel.text(display: menuBarDisplay, hottest: hottestText, fans: fans)
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
            writePath: helper.writePathReport,
            // The decision log is the half of a bug report that was previously
            // impossible to attach: "my fans ramped at 2am" is unanswerable
            // from reads alone.
            decisions: helper.decisions.isEmpty ? nil : helper.decisions,
            coolingResistance: coolingResistance
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
    /// answer changes only a handful of times. Membership is fixed at discovery
    /// but the *published* list is only monotone: a power-gated cluster reports
    /// nothing for up to ~85 s, so this grows over the first minute and a half
    /// before it settles — and it is assigned only on change, which is why a
    /// growing count costs no extra scene evaluations.
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
    /// 0 until the fetch lands, which the `max` at each call site absorbs.
    ///
    /// Observed, deliberately, because the popover reserves its sensor list's
    /// height from it
    /// (``SensorListMetrics``). The warning on ``sensorRowCount`` does not apply
    /// here: nothing reads this from `App.body`, and the popover's body already
    /// re-renders every tick from `temperatures`, so the one invalidation this
    /// adds per launch costs nothing.
    private(set) var sensorInventoryCount = 0

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
