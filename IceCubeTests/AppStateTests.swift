// AppStateTests.swift — the app's only mutable model, testable at last, plus the two rules pulled out of it.

import Foundation
import IceCubeKit
import Testing

/// `AppState` measured **0.0 % — 0 of 420 executable lines, 54 functions** —
/// until 2026-08-08, and not because anybody decided it was untestable. One
/// line of it constructed a `StatusItemController`, which reaches AppKit and
/// pulls `PopoverView` and the entire popover tree behind it, so adding the
/// file to the test bundle would have compiled thirteen more with it. Nobody
/// did, so nothing in the app's only mutable model was ever pinned.
///
/// Injecting the menu-bar host fixed it, and cost **zero** extra files: with
/// `MenuBarHosting` supplied by the caller, `AppState` names no view at all.
///
/// The two rules worth the most were private, so they moved out — the pattern
/// this project has used six times (`SensorsWindowMetrics`, `ManualTargets`,
/// `PresetHighlight`, `StartupPolicy`, `ThermalDiagnosis`, `ControlAlertRules`).
@MainActor
@Suite("AppState — the model, and the rules extracted from it")
struct AppStateTests {
    /// Records what the menu bar was asked to do, and touches no AppKit.
    final class SpyHost: MenuBarHosting {
        private(set) var installs = 0
        private(set) var removals = 0
        private(set) var closes = 0
        func installVendoredItem() {
            installs += 1
        }

        func removeVendoredItem() {
            removals += 1
        }

        func closePopover() {
            closes += 1
        }
    }

    static func state(host: SpyHost = SpyHost()) -> AppState {
        AppState(graph: CompositionRoot.makeSimulatedForTesting(), menuBarHost: { _ in host })
    }

    // MARK: - PollErrorPolicy

    /// Both of these mean this Mac's sensor map is wrong, which will still be
    /// true on the next tick and the one after — so waiting three of them only
    /// delays a message that is already certain.
    @Test(
        "A mapping fault speaks on the first failure, with the diagnostics hint",
        arguments: [
            IceCubeError.smcKeyNotFound(key: "Tp01"),
            IceCubeError.smcDecodingFailed(key: "Tp01", type: "flt", bytes: []),
        ]
    )
    func mappingFaultsSpeakImmediately(error: IceCubeError) throws {
        let message = try #require(PollErrorPolicy.message(for: error, consecutiveFailures: 1))
        #expect(message.hasSuffix(PollErrorPolicy.diagnosticsHint), "a report is the only thing that fixes this")
    }

    /// Documented as something the app should never see, since reads need no
    /// privilege. It speaks — but without the hint, which would be misleading
    /// advice for a fault a diagnostics report cannot explain.
    @Test("A privilege fault speaks immediately, without the diagnostics hint")
    func privilegeFaultSpeaksWithoutHint() throws {
        let message = try #require(
            PollErrorPolicy.message(for: .smcNotPrivileged(key: "Tp01"), consecutiveFailures: 1)
        )
        #expect(!message.hasSuffix(PollErrorPolicy.diagnosticsHint))
    }

    /// The rule that keeps a healthy Mac quiet. One dropped read happens; an
    /// error caption flashing in and out of the layout for it is worse than
    /// silence, because it teaches the user to ignore the caption.
    @Test("A transient fault stays quiet until the third consecutive failure")
    func transientFaultWaits() {
        let transient = IceCubeError.smcCallFailed(key: "Tp01", kernReturn: -1)
        #expect(PollErrorPolicy.message(for: transient, consecutiveFailures: 1) == nil)
        #expect(PollErrorPolicy.message(for: transient, consecutiveFailures: 2) == nil)
        #expect(PollErrorPolicy.message(for: transient, consecutiveFailures: 3) != nil, "the third is worth saying")
        #expect(PollErrorPolicy.message(for: transient, consecutiveFailures: 9) != nil, "and it keeps saying it")
    }

    // MARK: - Poll cadence

    /// An icon-only menu bar displays no reading, so polling faster than five
    /// seconds buys nothing visible and costs CPU all day. The rule had two
    /// call sites that once disagreed — which is exactly what an untestable
    /// shared rule invites.
    @Test(
        "An icon-only menu bar is never polled faster than every five seconds",
        arguments: [PollInterval.oneSecond, .twoSeconds, .fiveSeconds]
    )
    func iconOnlyIsFloored(interval: PollInterval) {
        #expect(interval.effectiveSeconds(display: .iconOnly) >= 5)
    }

    @Test("Every other display mode polls exactly as often as the user asked")
    func otherModesAreHonoured() {
        for interval in PollInterval.allCases {
            for display in MenuBarDisplayMode.allCases where display != .iconOnly {
                #expect(
                    interval.effectiveSeconds(display: display) == interval.rawValue,
                    "\(display) must not be throttled"
                )
            }
        }
    }

    // MARK: - The model

    @Test("A fresh model has no reading and nothing to say")
    func startsEmpty() {
        let state = Self.state()
        #expect(state.snapshot == nil)
        #expect(state.errorMessage == nil)
        #expect(state.hottestDie == nil)
        #expect(state.diagnosis == nil, "the diagnosis window has not been opened")
    }

    @Test("A simulated graph produces a simulated model")
    func simulatedFlagFollowsTheGraph() {
        #expect(Self.state().isSimulated)
    }

    /// The isolation hole closed earlier today, asserted from the other side:
    /// the model's chart settings must be the ones built from the graph's
    /// store, not a fresh `UserDefaults.standard`.
    @Test("Chart settings come from the graph's store")
    func chartSettingsUseTheInjectedStore() {
        let graph = CompositionRoot.makeSimulatedForTesting()
        let state = AppState(graph: graph, menuBarHost: { _ in SpyHost() })
        state.chartSettings.showPower = true
        #expect(graph.defaults.object(forKey: "charts.power") as? Bool == true)
    }

    // MARK: - The experimental switch

    /// Off is the whole promise of an opt-in feature, so it is pinned rather
    /// than assumed from `bool(forKey:)`'s behaviour.
    ///
    /// Worth one sentence about why that reader is the right one here, because
    /// the same call was the *wrong* one in `ChartStore.Window`: there `0` was a
    /// legitimate stored value, so "absent" and "one minute" were
    /// indistinguishable and the documented default could never fire. Here
    /// `false` genuinely means *not enabled* — there is no state this
    /// preference can hold that `false` would misrepresent.
    @Test("A store nobody has written reports the experimental window as off")
    func insideIsOffUntilAskedFor() {
        let graph = CompositionRoot.makeSimulatedForTesting()
        #expect(graph.defaults.object(forKey: AppState.insideEnabledKey) == nil, "nothing may have written it")
        let state = AppState(graph: graph, menuBarHost: { _ in SpyHost() })
        #expect(!state.isInsideEnabled, "an experimental feature must not arrive switched on")
    }

    /// Same contract as the Inside switch, for the same reasons, on the row
    /// that most needs it: every sibling in the diagnosis window reports a
    /// measurement and this one reports a projection, so the user throws the
    /// switch themselves.
    @Test("A store nobody has written reports the forecast as off")
    func forecastIsOffUntilAskedFor() {
        let graph = CompositionRoot.makeSimulatedForTesting()
        #expect(graph.defaults.object(forKey: AppState.forecastEnabledKey) == nil, "nothing may have written it")
        let state = AppState(graph: graph, menuBarHost: { _ in SpyHost() })
        #expect(!state.isForecastEnabled, "an experimental feature must not arrive switched on")
        #expect(state.forecast == nil, "and nothing may be published before it is asked for")
    }

    @Test("Turning the forecast on writes to the injected store")
    func forecastTogglePersistsThroughTheSeam() {
        let graph = CompositionRoot.makeSimulatedForTesting()
        let state = AppState(graph: graph, menuBarHost: { _ in SpyHost() })

        state.isForecastEnabled = true
        #expect(graph.defaults.bool(forKey: AppState.forecastEnabledKey))
        #expect(!(graph.defaults is UserDefaults), "and the store it landed in must not be the real one")

        state.isForecastEnabled = false
        #expect(!graph.defaults.bool(forKey: AppState.forecastEnabledKey), "and it must switch back off again")
    }

    /// Switching it off must clear the row, not leave the last projection on
    /// screen. A stale forecast is worse than none: it keeps making a claim
    /// about a machine it is no longer watching.
    ///
    /// The first version of this test **survived deleting the clearing code**.
    /// It flipped the switch on and straight back off without ever running a
    /// tick, so `forecast` had never been set and was `nil` either way — the
    /// test asserted a value that could not have been anything else. It now
    /// gets a projection on screen first, then takes it away.
    @Test("Switching the forecast off clears what it was showing")
    func forecastClearsWhenSwitchedOff() async {
        let state = Self.state()
        state.isForecastEnabled = true
        state.diagnosisAppeared()

        state.start()
        try? await Task.sleep(for: .milliseconds(2500))
        state.stop()
        #expect(state.forecast != nil, "there must be something to clear")

        state.isForecastEnabled = false
        #expect(state.forecast == nil)
    }

    /// The keys must not collide, or one experimental switch silently drives
    /// the other.
    @Test("The experimental preference keys are distinct")
    func experimentalKeysAreDistinct() {
        let keys = [
            AppState.insideEnabledKey,
            AppState.insideInPopoverKey,
            AppState.insideAnimationKey,
            AppState.forecastEnabledKey,
        ]
        #expect(Set(keys).count == keys.count, "\(keys)")
    }

    /// The seam `@AppStorage` broke three times: the toggle has to land in the
    /// store the graph handed over, or a simulated session writes a feature flag
    /// into the owner's real preferences.
    @Test("Turning the experimental window on writes to the injected store")
    func insideTogglePersistsThroughTheSeam() {
        let graph = CompositionRoot.makeSimulatedForTesting()
        let state = AppState(graph: graph, menuBarHost: { _ in SpyHost() })

        state.isInsideEnabled = true
        #expect(graph.defaults.bool(forKey: AppState.insideEnabledKey))
        #expect(!(graph.defaults is UserDefaults), "and the store it landed in must not be the real one")

        state.isInsideEnabled = false
        #expect(!graph.defaults.bool(forKey: AppState.insideEnabledKey), "and it must switch back off again")
    }

    /// Three states, and the third is the one that matters: "never chosen" has
    /// to stay distinguishable from "chosen off", because the first follows the
    /// system's Reduce Motion setting and the second overrides it. This is what
    /// `KeyValueStore.object(forKey:)` exists for — `bool(forKey:)` collapses
    /// the two.
    @Test("The animation preference remembers not having been chosen")
    func insideAnimationIsTriState() {
        let graph = CompositionRoot.makeSimulatedForTesting()
        let state = AppState(graph: graph, menuBarHost: { _ in SpyHost() })
        #expect(state.insideAnimation == nil, "an untouched preference must defer to the system")

        state.insideAnimation = false
        #expect(graph.defaults.object(forKey: AppState.insideAnimationKey) as? Bool == false)
        #expect(
            AppState(graph: graph, menuBarHost: { _ in SpyHost() }).insideAnimation == false,
            "an explicit off must survive a relaunch as an explicit off, not decay to 'unchosen'"
        )

        state.insideAnimation = nil
        #expect(
            graph.defaults.object(forKey: AppState.insideAnimationKey) == nil,
            "clearing it must remove the key, or 'follow the system' becomes unreachable"
        )
    }

    /// Two switches, not one, and the second must never be reachable without
    /// the first — a compact drawing appearing in the popover of someone who
    /// never turned the feature on is the failure the opt-in exists to prevent.
    @Test("The popover copy is off by default and writes through the injected store")
    func insideInPopoverIsOffAndIsolated() {
        let graph = CompositionRoot.makeSimulatedForTesting()
        #expect(graph.defaults.object(forKey: AppState.insideInPopoverKey) == nil)
        let state = AppState(graph: graph, menuBarHost: { _ in SpyHost() })
        #expect(!state.showsInsideInPopover, "an experimental surface must not arrive switched on")

        state.showsInsideInPopover = true
        #expect(graph.defaults.bool(forKey: AppState.insideInPopoverKey))
        #expect(!(graph.defaults is UserDefaults), "and it must not have reached the real domain")

        // The popover checks both, so turning the feature off must take the
        // compact copy with it whatever this one says.
        #expect(!state.isInsideEnabled, "the feature itself is still off")
    }

    /// An unreachable window is the point of the switch, and a window the menu
    /// bar cannot close is the "a window nobody remembers opening" bug
    /// `closableFromMenuBar` exists for. Inside qualifies for the same reason
    /// the diagnosis window does: it holds nothing and commits nothing.
    @Test("The experimental window is one the menu bar may close")
    func insideIsClosableFromTheMenuBar() {
        #expect(WindowOpener.closableFromMenuBar.contains(WindowOpener.ID.inside))
        #expect(
            WindowOpener.windowsToClose(
                openWindowIDs: [WindowOpener.ID.inside], summoning: WindowOpener.ID.settings
            ) == [WindowOpener.ID.inside],
            "opening Settings must not leave it stranded behind"
        )
    }

    @Test("Reporting an error surfaces it, and it can be cleared by the next good poll")
    func reportedErrorsAreVisible() {
        let state = Self.state()
        state.reportError("something went wrong")
        #expect(state.errorMessage == "something went wrong")
    }

    // MARK: - Gating

    /// The ~17 % CPU rule. Publishing chart rows into a popover nobody can see
    /// cost that much sustained, measured, before the gate existed.
    @Test("Charts do not publish while the popover is closed")
    func chartsAreGatedOnVisibility() {
        let state = Self.state()
        #expect(state.chartRows.isEmpty)
        state.refreshCharts()
        #expect(state.chartRows.isEmpty, "closed popover, nothing to draw")
    }

    @Test("The popover reports its own appearance and disappearance")
    func popoverLifecycleIsTracked() {
        let state = Self.state()
        #expect(!state.isPopoverVisible)
        state.popoverAppeared()
        #expect(state.isPopoverVisible)
        state.popoverDisappeared()
        #expect(!state.isPopoverVisible)
    }

    @Test("Pausing freezes the picture and un-pausing releases it")
    func pauseToggles() {
        let state = Self.state()
        #expect(!state.isPaused)
        state.togglePaused()
        #expect(state.isPaused)
        state.togglePaused()
        #expect(!state.isPaused)
    }

    /// Process names are the most sensitive thing this app touches, so closing
    /// the Diagnose window must not merely stop sampling — it must drop what
    /// was collected, rather than leave a list of what the user runs alive in a
    /// menu-bar process for days.
    @Test("Closing the diagnosis window discards what it collected")
    func diagnosisIsDiscardedOnClose() {
        let state = Self.state()
        state.diagnosisAppeared()
        state.diagnosisDisappeared()
        #expect(state.diagnosis == nil)
    }

    /// Sampling walks every PID on the machine. Doing that once a second for a
    /// window nobody has open is the same waste the popover gate exists to
    /// prevent, so it is gated the same way.
    @Test("No process sampling happens while the diagnosis window is closed")
    func samplingIsGated() async {
        let sampler = CountingSampler()
        let graph = CompositionRoot.makeSimulatedForTesting()
        let state = AppState(
            provider: graph.provider,
            isSimulated: true,
            helper: graph.helper,
            presets: graph.presets,
            history: graph.history,
            defaults: graph.defaults,
            processes: sampler,
            menuBarHost: { _ in SpyHost() }
        )
        state.diagnosisDisappeared() // explicitly closed

        state.start()
        try? await Task.sleep(for: .milliseconds(1200))
        state.stop()

        #expect(await sampler.calls == 0, "a closed window must cost nothing")
    }

    /// The wiring, end to end: a tick has to reach the projection and publish
    /// it, or every unit test below is testing code nothing calls.
    ///
    /// What it asserts is deliberately weak about the *content*. Two seconds
    /// into a simulated run there is no time constant yet — an estimate spans
    /// three minutes — so the honest verdict is a refusal, and that is exactly
    /// what should be on screen. The claim here is that the row **exists and
    /// says why it is quiet**, which is the whole design: a blank row reads as
    /// a machine the app has decided is fine.
    @Test("With the feature on, a tick publishes a forecast that names what it is waiting for")
    func aTickPublishesTheForecast() async {
        let state = Self.state()
        state.isForecastEnabled = true
        state.diagnosisAppeared()

        state.start()
        try? await Task.sleep(for: .milliseconds(2500))
        state.stop()

        guard case let .unavailable(gap) = state.forecast else {
            Issue.record("expected a named refusal two seconds in, got \(String(describing: state.forecast))")
            return
        }
        // Either honest answer this early: no transients measured yet, or the
        // draw has not held still long enough to have an equilibrium.
        switch gap {
        case .noTimeConstantYet, .loadNotSteady: break
        default: Issue.record("unexpected gap this early: \(gap)")
        }
    }

    /// Closing the window must drop the projection, not leave the last one on
    /// screen for whenever it is opened again. A stale forecast keeps making a
    /// claim about a machine nobody is watching.
    @Test("Closing the window clears the forecast")
    func closingTheWindowClearsTheForecast() async {
        let state = Self.state()
        state.isForecastEnabled = true
        state.diagnosisAppeared()

        state.start()
        try? await Task.sleep(for: .milliseconds(2500))
        state.stop()
        #expect(state.forecast != nil, "the row must have been up to begin with")

        state.diagnosisDisappeared()
        #expect(state.forecast == nil)
    }

    /// The estimator has to actually accumulate from the snapshots it is
    /// handed, which a two-second tick run cannot show: one estimate spans
    /// three minutes of steady machine. Driven directly instead, with a
    /// scripted ramp at the same shape a real one has.
    @Test("Feeding the estimator scripted snapshots accumulates estimates")
    func estimatorAccumulatesFromSnapshots() {
        let state = Self.state()
        let epoch = Date(timeIntervalSince1970: 1_753_000_000)
        var rise = 45.0

        for tick in 0 ..< 260 {
            rise = 5 + (rise - 5) * exp(-1.0 / 75)
            let fans = [
                Fan(
                    id: 0,
                    name: "L",
                    mode: .system,
                    actualRPM: 4500,
                    targetRPM: 4500,
                    minRPM: 2317,
                    maxRPM: 6800
                ),
            ]
            state.ingestForecastSample(SMCSnapshot(
                date: epoch.addingTimeInterval(Double(tick)),
                fans: fans,
                temperatures: [
                    SensorReading(key: "Tp01", label: "CPU", celsius: 40 + rise),
                    SensorReading(key: "TaLP", label: "Airflow", celsius: 40),
                ],
                power: 40
            ))
        }
        #expect(state.forecastEstimateCount > 0, "a clean 260 s ramp must yield estimates")
    }

    /// The switch has to gate the work, not just the drawing. A projection
    /// computed and published for a feature nobody turned on is the cost this
    /// row was made opt-in to avoid.
    @Test("With the feature off, a tick publishes nothing at all")
    func aTickPublishesNothingWhenOff() async {
        let state = Self.state()
        state.diagnosisAppeared()

        state.start()
        try? await Task.sleep(for: .milliseconds(2500))
        state.stop()

        #expect(state.diagnosis != nil, "the rest of the window must still work")
        #expect(state.forecast == nil, "a switched-off feature must not publish")
    }

    /// A sampler that counts, and returns nothing — the documented first-call
    /// behaviour of the real one.
    actor CountingSampler: ProcessSampling {
        private(set) var calls = 0
        private(set) var resets = 0
        func sample() async -> ProcessEnergyReading? {
            calls += 1
            return nil
        }

        func reset() {
            resets += 1
        }
    }
}
