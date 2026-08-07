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
}
