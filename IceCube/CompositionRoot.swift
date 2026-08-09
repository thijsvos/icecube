// CompositionRoot.swift — the one place that decides what the app runs against, real or simulated.

import Foundation
import IceCubeKit
import os

/// Builds the app's object graph. Nothing else in the app may construct a
/// provider, a `HelperManager` or a `PresetStore` — keeping the choice in one
/// place is what lets tests, CI and simulated mode swap implementations without
/// touching UI code.
///
/// **This used to decide only the SMC provider, and that was a defect with
/// teeth.** `AppState` built `let helper = HelperManager()` as a stored
/// property, which defaults to the real XPC client, the real launchd registrar
/// and the real power watcher — so a simulated launch read fake sensors while
/// driving the owner's real fans, and disturbed real fan control when it quit
/// (see `SimulatedEnvironment` for the log). The flag now decides the whole
/// graph, because the only reliable place to enforce isolation is where the
/// objects are made.
enum CompositionRoot {
    /// Everything the app needs, wired for this launch.
    struct Graph {
        let provider: any SMCProviding
        let isSimulated: Bool
        let helper: HelperManager
        let presets: PresetStore
        /// Persisted cooling records + trend. Real file normally; a per-run
        /// temp file seeded with fabricated months when simulated, so the
        /// trend UI is demonstrable while the real history is untouchable.
        let history: CoolingHistoryStore
        /// Where app-level preferences go. Real `UserDefaults` normally; an
        /// in-memory store when simulated, so a simulated session cannot steer
        /// the real app's next launch.
        let defaults: any KeyValueStore
        /// Who is drawing power. Real `proc_pid_rusage` reads normally; fixed
        /// fiction when simulated, so a simulated session reads **no real PID**.
        ///
        /// Process names say what a person works on, which makes this the one
        /// seam in the graph whose simulated substitute is a privacy guarantee
        /// rather than a convenience.
        let processes: any ProcessSampling
    }

    /// Picks the graph for this launch.
    ///
    /// Simulated mode is on when the `ICECUBE_SIMULATED` environment variable
    /// is `"1"` (the committed "Ice Cube (Simulated)" scheme sets it) or when
    /// `--simulated` was passed on the command line. Otherwise the app opens
    /// the real SMC read-only; if that fails (no AppleSMC service — not a Mac?)
    /// it falls back to the simulation rather than launching dead, and the
    /// SIMULATED badge tells the truth about what's on screen.
    ///
    /// That fallback is the second route into simulated mode and is easy to
    /// forget: it is reached with no environment variable set, so a test that
    /// only sets `ICECUBE_SIMULATED` would miss it. Both routes therefore land
    /// on the same ``simulated()`` builder rather than each assembling a graph.
    static func make() -> Graph {
        let simulated = ProcessInfo.processInfo.environment["ICECUBE_SIMULATED"] == "1"
            || CommandLine.arguments.contains("--simulated")

        if simulated {
            return self.simulated()
        }

        do {
            return try live(provider: SystemSMCProvider())
        } catch {
            Logger(subsystem: HelperConstants.logSubsystem, category: "smc")
                .error("Cannot open the SMC (\(error.localizedDescription)) — falling back to the simulated provider.")
            return self.simulated()
        }
    }

    /// The real graph: real SMC, real daemon, real preferences, real presets file.
    private static func live(provider: any SMCProviding) -> Graph {
        Graph(
            provider: provider,
            isSimulated: false,
            helper: HelperManager(),
            presets: PresetStore(),
            history: CoolingHistoryStore(identity: .init(
                modelIdentifier: HostInfo.modelIdentifier(),
                isSimulated: false,
                // Read once, hashed with a per-file salt, never stored raw.
                serialNumber: HostInfo.serialNumber()
            )),
            defaults: UserDefaults.standard,
            processes: SystemProcessSampler()
        )
    }

    /// The simulated graph: fake sensors, and **no reachable system state**.
    ///
    /// Every seam is substituted here rather than checked at each call site.
    /// Scattered `if isSimulated` guards are how the original hole survived —
    /// there were six such checks in the app and every one of them was a badge
    /// or a label, so the app looked guarded while nothing was.
    ///
    /// The presets file is redirected into a per-process temporary directory
    /// rather than disabled, so saving and loading a preset stays demonstrable
    /// while the owner's real `presets.json` is untouchable.
    private static func simulated() -> Graph {
        let defaults = SimulatedEnvironment.Defaults()
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("IceCubeSimulated-\(ProcessInfo.processInfo.processIdentifier)")

        // Months of fabricated records, or the trend could only ever show
        // "collecting" — the `seedSimulatedDecisions` reasoning. The story is
        // selectable so every verdict state can be seen and screenshot:
        //   ICECUBE_SIMULATED_HISTORY=stable|rising|jump|improved|baseline|sparse
        // The seed applies only because the per-run sandbox has no file; the
        // live graph passes no seed, so fabricated readings cannot reach a
        // real install by any code path.
        let story = SimulatedCoolingHistory.story(
            fromEnvironment: ProcessInfo.processInfo.environment["ICECUBE_SIMULATED_HISTORY"]
        )

        return Graph(
            provider: MockSMCProvider(),
            isSimulated: true,
            helper: HelperManager(
                service: SimulatedEnvironment.Registrar(),
                client: SimulatedEnvironment.HelperChannel(),
                defaults: defaults,
                // No preflight blocker: the real one inspects the bundle path and
                // code signature to explain why registration would fail, and in
                // simulated mode there is nothing to register.
                blocker: { nil },
                powerSource: SimulatedEnvironment.PowerSource()
            ),
            presets: PresetStore(file: sandbox.appendingPathComponent("presets.json")),
            history: CoolingHistoryStore(
                file: sandbox.appendingPathComponent("cooling-history.json"),
                identity: .init(
                    // The mock's identity, not this Mac's: a simulated run
                    // reads no real system state, and the fingerprint's
                    // isSimulated flag keeps the file unloadable by a real run.
                    modelIdentifier: SimulatedCoolingHistory.machine.modelIdentifier,
                    isSimulated: true,
                    serialNumber: nil
                ),
                seed: SimulatedCoolingHistory.seed(story, endingAt: Date())
            ),
            defaults: defaults,
            processes: MockProcessSampler()
        )
    }

    /// The simulated graph, for tests.
    ///
    /// Exposed because ``SimulatedIsolationTests`` asserts the composition
    /// itself — the layer where isolation is true or false. Testing it through
    /// `make()` would mean mutating the process environment, and the whole
    /// point is that this graph is reachable by two routes (the env var and the
    /// SMC-open failure) that must not be able to drift apart.
    static func makeSimulatedForTesting() -> Graph {
        simulated()
    }
}
