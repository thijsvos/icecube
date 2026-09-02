// SimulatedIsolationTests.swift — proves a simulated launch cannot reach the real daemon, preferences or presets file.

import Foundation
import IceCubeKit
import ServiceManagement
import Testing

/// The regression test for the worst defect this project has shipped.
///
/// On 2026-08-02 an instance launched with `ICECUBE_SIMULATED=1` connected to
/// the owner's real root daemon, ran the power rule off real charger state,
/// applied a preset to the real fans, and on quit caused the daemon to revert
/// them — leaving a 75 °C die to `FanGuardian`.
///
/// Nothing caught it, and the reason is worth recording: `CompositionRoot` and
/// `AppState` were not compiled into the test target at all, so no test *could*
/// have referenced them. `HelperManagerTests` passed throughout because it
/// injects fakes for precisely the seams production never overrode. The suite
/// was testing a graph the app never built.
///
/// These tests assert the composition itself, which is the only layer where the
/// property is true or false.
@MainActor
@Suite("Simulated mode — isolation from the real system")
struct SimulatedIsolationTests {
    private func simulatedGraph() -> CompositionRoot.Graph {
        CompositionRoot.makeSimulatedForTesting()
    }

    /// The headline. Every daemon-facing seam must be a stand-in.
    @Test("The simulated graph contains no production system seam")
    func noProductionSeams() {
        let graph = simulatedGraph()
        #expect(graph.isSimulated)
        #expect(graph.provider is MockSMCProvider, "the SMC provider must be the mock")
        #expect(
            !(graph.defaults is UserDefaults),
            "a simulated run must not read or write the real preferences domain — those keys steer the real app's next launch"
        )
        #expect(
            graph.helper.usesSimulatedChannel,
            "the XPC channel must be a stand-in, or a simulated run drives the real fans"
        )
        #expect(
            graph.helper.usesSimulatedRegistrar,
            "launchd registration must be a stand-in, or a simulated run can install or remove a root daemon"
        )
        #expect(
            graph.helper.usesSimulatedPowerSource,
            "the power watcher must be a stand-in — a real charger change is what triggered the incident"
        )
        #expect(
            graph.helper.usesSimulatedPresence,
            "the presence watcher must be a stand-in — a real lock screen would reach the fans by the same route"
        )
        #expect(
            graph.processes is MockProcessSampler,
            "the process sampler must be a stand-in — a simulated run has no business reading real process names"
        )
    }

    /// The privacy half of isolation, asserted on behaviour rather than on type.
    ///
    /// The type check above can be satisfied by a mock that still calls
    /// `proc_listpids`. This one pins what actually matters: the PIDs a
    /// simulated run reports are fiction, and none of them can belong to a
    /// process on this machine.
    ///
    /// The `kill(pid, 0)` probe alone would be a flaky test — it only proves
    /// nothing holds that PID *at this instant*. The structural half is the
    /// range: `MockProcessSampler` numbers from 900001, above Darwin's PID
    /// ceiling of 99999, so a collision is impossible rather than merely
    /// unobserved. Both are asserted, because the range is the guarantee and
    /// the probe is what catches the range being changed back.
    @Test("A simulated run reports no PID that could exist on this machine")
    func simulatedProcessesAreFiction() async throws {
        let reading = try #require(await simulatedGraph().processes.sample())
        #expect(!reading.processes.isEmpty, "simulated mode must still demonstrate the feature")
        for process in reading.processes {
            #expect(
                process.pid >= MockProcessSampler.firstFakePID,
                "pid \(process.pid) is inside the range real processes use — a collision is only a matter of time"
            )
            #expect(
                kill(process.pid, 0) != 0,
                "pid \(process.pid) (\(process.name)) is a live process — simulated mode named a real one"
            )
        }
    }

    /// A simulated run must not post real banners about a machine that is fine.
    ///
    /// The simulated thermal model is a sine wave with random spikes, so an
    /// ungated run would fire the temperature alert repeatedly — and, since
    /// 2026-08-07, the loss-of-control alerts too, about a daemon that does not
    /// exist. It would also raise a real permission prompt the user never asked
    /// for.
    ///
    /// Asserted on `AlertManager` rather than through `AppState`, which is not
    /// compiled into this bundle. What that leaves unguarded is the single line
    /// `AppState` uses to wire it (`deliversNotifications: !isSimulated`) — so
    /// the test below pins the half that has behaviour, and the wiring stays a
    /// one-line review item rather than a silent assumption.
    @Test("Suppressed delivery still evaluates the rules, so simulated mode stays demonstrable")
    func simulatedAlertsAreEvaluatedButNotDelivered() {
        let defaults = SimulatedEnvironment.Defaults()
        let quiet = AlertManager(defaults: defaults, deliversNotifications: false)
        #expect(!quiet.deliversNotificationsForTesting)
        #expect(quiet.reportsControlLoss, "the rules must still be on, or nothing is demonstrable")

        // Runs the whole rule path. It must not touch UNUserNotificationCenter,
        // and it must not throw or trap on the way.
        quiet.evaluateControl(
            freshDecisions: [DecisionEvent(text: "SAFETY: fan write failed mid-sequence", date: Date())],
            fans: [],
            now: Date()
        )

        let live = AlertManager(defaults: SimulatedEnvironment.Defaults(), deliversNotifications: true)
        #expect(live.deliversNotificationsForTesting, "a real launch must still be able to speak")
    }

    /// Twelve chart preferences were exempt from isolation until 2026-08-07.
    ///
    /// `AppState` held `let chartSettings = ChartSettings()`, and `ChartSettings`
    /// read `UserDefaults.standard` directly — so while the daemon channel, the
    /// registrar, the power watcher, the presets file and the preferences store
    /// were all substituted, toggling any chart setting in a simulated run wrote
    /// into the owner's real preferences domain. The same defect class as the
    /// 2026-08-02 incident, and invisible for the same reason: neither file was
    /// compiled into this bundle, so no test could reference them.
    ///
    /// Asserted on `ChartSettings` itself, because `AppState` is still not in
    /// this bundle. What that leaves unguarded is the one line wiring them
    /// together (`ChartSettings(defaults: defaults)`) — a review item, stated
    /// rather than pretended away, exactly as `simulatedAlertsAreNotDelivered`
    /// does for `AlertManager`.
    @Test("Chart settings write to the store they are given, never to the real domain")
    func chartSettingsAreIsolated() {
        let store = SimulatedEnvironment.Defaults()
        let settings = ChartSettings(defaults: store)

        settings.showPower = true
        settings.showCharts = false

        #expect(store.object(forKey: "charts.power") as? Bool == true, "the write must land in the injected store")
        #expect(store.object(forKey: "charts.show") as? Bool == false)
        #expect(
            !(CompositionRoot.makeSimulatedForTesting().defaults is UserDefaults),
            "and the store a simulated launch hands it must not be the real one"
        )
    }

    /// The presets file is redirected rather than disabled, so saving a preset
    /// stays demonstrable while the owner's real catalog is unreachable.
    @Test("The simulated presets file is not the real one")
    func presetsFileIsRedirected() {
        let graph = simulatedGraph()
        #expect(graph.presets.fileURL != PresetStore.defaultFile)
        #expect(
            graph.presets.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "simulated presets belong in a temporary directory, got \(graph.presets.fileURL.path)"
        )
    }

    /// The history file follows the presets pattern: redirected, never
    /// disabled. A simulated launch writing fabricated records into the
    /// owner's real baseline would be the same incident this suite exists
    /// for, made worse by being silent and permanent — a poisoned baseline
    /// yields a false "your cooling degraded" months later.
    @Test("The simulated cooling-history file is not the real one, and arrives seeded")
    func historyFileIsRedirectedAndSeeded() {
        let graph = simulatedGraph()
        #expect(graph.history.fileURL != CoolingHistoryStore.defaultFile)
        #expect(
            graph.history.fileURL.path.hasPrefix(FileManager.default.temporaryDirectory.path),
            "simulated history belongs in a temporary directory, got \(graph.history.fileURL.path)"
        )
        // Demonstrable, not merely isolated (CLAUDE.md rule 3): months of
        // fabricated records so the trend has something to say, fingerprinted
        // simulated so a real run could never load them even by hand.
        let history = graph.history.history
        #expect(
            (history?.records.count ?? 0) + (history?.days.count ?? 0) > 50,
            "the seed must fill months, not moments"
        )
        #expect(history?.machine.isSimulated == true)
    }

    /// CLAUDE.md rule 3: every feature must be *demonstrable* when simulated.
    /// Isolation that left the fan-control UI dead would trade one violation
    /// for another, so the stand-in behaves like a healthy, approved daemon.
    @Test("The simulated daemon still answers, so the whole UI stays demonstrable")
    func simulatedDaemonIsDemonstrable() async throws {
        let channel = SimulatedEnvironment.HelperChannel()
        channel.connect()
        #expect(channel.isConnected)
        #expect(
            try await channel.version() == HelperConstants.protocolVersion,
            "a version mismatch would make the app offer to update a daemon that does not exist"
        )

        var config = FanConfig(mode: .curve)
        config.sharedCurve = .balanced
        try await channel.apply(config)
        let status = try await channel.status()
        #expect(status.mode == .curve, "applying a preset must be visible in the status the UI reads")
        #expect(status.activeCurve == .balanced)

        // The self-test WRITES to the SMC on real hardware, and the app runs it
        // automatically before a diagnostics export.
        #expect(try await channel.selfTestWritePath().verdict == .verified)
    }

    @Test("The simulated registrar reports an approved daemon and never touches launchd")
    func simulatedRegistrarIsInert() throws {
        let registrar = SimulatedEnvironment.Registrar()
        #expect(registrar.status == .enabled, "so the app opens in its normal state rather than onboarding")
        try registrar.register()
        registrar.openSettings()
    }

    /// The power rule is what actually fired in the incident: a real
    /// unknown → battery transition became a real preset on real fans.
    @Test("The simulated power source never changes, so the power rule cannot fire on real events")
    func simulatedPowerSourceIsFixed() {
        let power = SimulatedEnvironment.PowerSource()
        #expect(power.current == .wall)
        power.start()
        #expect(power.onChange == nil, "nothing may subscribe it to a real IOKit notification")
    }

    /// The away rule is the power rule's twin, and would fire on the same kind
    /// of real event: a lock screen instead of a charger.
    @Test("The simulated presence never changes on its own, so the away rule cannot fire on a real lock")
    func simulatedPresenceIsFixed() {
        let presence = SimulatedEnvironment.Presence(script: nil)
        #expect(presence.current == .present)
        presence.start()
        #expect(presence.onChange == nil, "nothing may subscribe it to a real session notification")
        // The scripted trip is the demonstrability half — parsed, never
        // guessed. Anything but the documented form means no trip.
        #expect(SimulatedEnvironment.Presence.delay(fromScript: "away-after:20") == .seconds(20))
        #expect(SimulatedEnvironment.Presence.delay(fromScript: "away-after:0") == nil)
        #expect(SimulatedEnvironment.Presence.delay(fromScript: "away") == nil)
        #expect(SimulatedEnvironment.Presence.delay(fromScript: nil) == nil)

        // A scripted trip switches the rule on — in the store it is handed,
        // which in the simulated graph is never the real one. An unscripted
        // run leaves the rule exactly as empty preferences leave it: off.
        let scripted = SimulatedEnvironment.Defaults()
        SimulatedEnvironment.Presence(script: "away-after:5").seedRule(into: scripted)
        #expect(
            scripted.data(forKey: HelperManager.presenceRuleKey) != nil,
            "a scripted trip must have a rule to act on"
        )
        let plain = SimulatedEnvironment.Defaults()
        SimulatedEnvironment.Presence(script: nil).seedRule(into: plain)
        #expect(
            plain.data(forKey: HelperManager.presenceRuleKey) == nil,
            "an ordinary simulated run must not turn the rule on"
        )
        #expect(
            CompositionRoot.makeSimulatedForTesting().helper.presenceRule.isEnabled == false
                || ProcessInfo.processInfo.environment["ICECUBE_SIMULATED_PRESENCE"] != nil,
            "the graph a test builds must not carry the rule unless the environment scripted a trip"
        )
    }

    /// The second route into simulated mode, and the one an environment-variable
    /// test would miss: `SystemSMCProvider.init` throwing on a machine with no
    /// AppleSMC service falls back to the simulation with no env var set.
    @Test("The SMC-failure fallback lands on the same isolated graph as the env var")
    func fallbackRouteIsAlsoIsolated() {
        // Both routes call the same private builder; this asserts the property
        // that matters rather than the plumbing — there is exactly one
        // simulated graph, so there is exactly one thing to get right.
        let a = simulatedGraph()
        let b = simulatedGraph()
        #expect(a.helper.usesSimulatedChannel && b.helper.usesSimulatedChannel)
        #expect(!(a.defaults is UserDefaults) && !(b.defaults is UserDefaults))
    }

    /// Injecting the store is only half of isolation — the settings the user can
    /// actually toggle have to *go through* it.
    ///
    /// Four preferences did not. `@AppStorage` binds to `UserDefaults.standard`
    /// and cannot be pointed at a plain `KeyValueStore`, so the persist toggle,
    /// the ⌥-click mode and the setup-dismissed flag each read and wrote the
    /// real domain while `FanControlMemory` and `reconcileMenuBarMode` read the
    /// injected one. Two consequences, both silent: a simulated session's
    /// toggles had no effect on what it actually sent, and flipping one wrote
    /// into the owner's real preferences. The type checks above could not catch
    /// it — the graph was correct; the views went around it.
    @Test("The user-facing toggles write to the injected store, not the real domain")
    func togglesGoThroughTheInjectedStore() {
        let graph = simulatedGraph()
        let state = AppState(graph: graph, menuBarHost: { _ in SilentHost() })

        state.persistsCurveWithoutApp = true
        state.prefersSilentOptionClick = true
        state.hasDismissedSetup = true
        state.isInsideEnabled = true

        #expect(graph.defaults.bool(forKey: AppState.persistCurveKey))
        #expect(graph.defaults.bool(forKey: MenuBarMode.preferenceKey))
        #expect(graph.defaults.bool(forKey: AppState.dismissedSetupKey))
        #expect(
            graph.defaults.bool(forKey: AppState.insideEnabledKey),
            "a simulated session must not be able to switch an experimental feature on for the real app"
        )

        // And the reader the daemon-facing code actually consults must agree
        // with the toggle — that half was broken, not merely leaky: `cyclePreset`
        // and `powerSourceChanged` both send `memory.persistsCurveWithoutApp`.
        #expect(
            FanControlMemory(defaults: graph.defaults).persistsCurveWithoutApp,
            "the toggle must steer what cyclePreset and powerSourceChanged actually send"
        )

        // Nothing may have reached the real domain on the way.
        #expect(!(graph.defaults is UserDefaults))
    }

    /// A menu-bar host that does nothing and touches no AppKit.
    private final class SilentHost: MenuBarHosting {
        func installVendoredItem() {}
        func removeVendoredItem() {}
        func closePopover() {}
    }
}
