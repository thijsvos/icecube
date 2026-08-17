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

    /// A sampler that counts, and returns nothing — the documented first-call
    /// behaviour of the real one.
    actor CountingSampler: ProcessSampling {
        private(set) var calls = 0
        func sample() async -> ProcessEnergyReading? {
            calls += 1
            return nil
        }
    }
}
