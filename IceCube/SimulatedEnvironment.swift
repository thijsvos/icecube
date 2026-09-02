// SimulatedEnvironment.swift — the stand-ins that let simulated mode drive the whole UI while touching nothing real.

import Foundation
import IceCubeKit
import ServiceManagement

/// Everything a simulated launch uses instead of the real system.
///
/// **Why this file exists.** Simulated mode used to swap only the SMC provider.
/// Every other seam — the XPC channel to the root daemon, launchd registration,
/// the power-source watcher, `UserDefaults`, the presets file — kept its
/// production default, because `HelperManager()`'s no-argument initialiser
/// defaults to `SMAppServiceRegistrar()`, `HelperClient()` and
/// `PowerSourceMonitor()`, and `AppState` built it as a stored property before
/// `isSimulated` had even been assigned.
///
/// That was not theoretical. On 2026-08-02 a simulated instance connected to the
/// owner's real root daemon, ran the power rule off real charger state, applied
/// a preset to the real fans, and — when it quit — caused the daemon to revert
/// the real fans to auto, leaving a 75 °C die to `FanGuardian`:
///
///     23:29:00.891  Ice Cube[69180]  power rule: switching to Cold
///     23:29:01.150  IceCubeHelper    curve engaged (persists without app: false)
///     23:29:03.275  IceCubeHelper    all fans auto (app connection invalidated)
///
/// **The constraint that shapes every type below.** CLAUDE.md rule 3 says every
/// feature must be *demonstrable* in simulated mode. So these are not stubs that
/// refuse — refusing would leave the fan-control UI dead, which is the opposite
/// of the rule. They behave like a healthy, approved, connected daemon on a Mac
/// where everything works, and they simply have nowhere to send it.
enum SimulatedEnvironment {
    /// A daemon that is always installed and approved.
    ///
    /// Reports `.enabled` so the app opens straight into its normal state rather
    /// than onboarding. `register`/`unregister` succeed silently: in simulated
    /// mode those are exactly the calls that must not reach launchd, and a
    /// throwing stub would put the setup window into a permanent error.
    struct Registrar: DaemonRegistering {
        var status: SMAppService.Status {
            .enabled
        }

        func register() throws {}
        func unregister() async throws {}
        func openSettings() {}
    }

    /// A charger that never changes.
    ///
    /// Fixed at `.wall` and never fires `onChange`. Reading the *real* power
    /// source is what triggered the incident: the simulated instance saw a
    /// genuine unknown → battery transition, and the power rule turned that into
    /// a real preset applied to real fans.
    final class PowerSource: PowerSourceObserving {
        var current: PowerProfilePolicy.PowerSource {
            .wall
        }

        /// Charging, always — so "Warm from charging" is demonstrable with no
        /// hardware, no daemon and no charger, the same reason
        /// `seedSimulatedDecisions` fabricates a decision timeline.
        /// `MockSMCSimulation` idles `TB1T` at 38.5 °C, which is above the
        /// threshold, so the row appears in a simulated run.
        var isCharging: Bool {
            true
        }

        var onChange: (@MainActor () -> Void)?
        func start() {}
    }

    /// A user who never leaves — unless the run is told to script a trip.
    ///
    /// Fixed at `.present` and never fires, for the reason ``PowerSource`` is
    /// fixed at `.wall`: a simulated instance reading the real session's lock
    /// and display-sleep signals would turn a real lock into a preset on real
    /// fans by the same route the power rule once did.
    ///
    /// Demonstrable all the same (CLAUDE.md rule 3):
    /// `ICECUBE_SIMULATED_PRESENCE=away-after:20` makes the user leave 20 s
    /// after launch and come back 20 s later, one round trip, so the away
    /// preset and the hand-back can both be watched in the log with no lock
    /// screen involved.
    final class Presence: PresenceObserving {
        private(set) var current: PresencePolicy.Presence = .present
        var onChange: (@MainActor () -> Void)?
        private let delay: Duration?

        var reason: String {
            current == .away ? "scripted trip" : "here"
        }

        init(script: String? = ProcessInfo.processInfo.environment["ICECUBE_SIMULATED_PRESENCE"]) {
            delay = Self.delay(fromScript: script)
        }

        /// Whether a trip is scripted for this run.
        var isScripted: Bool {
            delay != nil
        }

        /// Turns the away rule on in a simulated store when a trip is
        /// scripted. Asking for a trip is asking to watch the rule act; a
        /// simulated run's preferences start empty, so without this the trip
        /// would log a presence change and the rule would do nothing. Only a
        /// simulated store is ever handed in, so no real preference moves.
        func seedRule(into defaults: any KeyValueStore) {
            guard isScripted,
                  let data = try? JSONEncoder().encode(PresencePolicy.Rule(isEnabled: true, whileAway: .cold))
            else { return }
            defaults.set(data, forKey: HelperManager.presenceRuleKey)
        }

        /// `away-after:N` → N seconds; anything else → no trip.
        static func delay(fromScript script: String?) -> Duration? {
            guard let script, script.hasPrefix("away-after:"),
                  let seconds = Int(script.dropFirst("away-after:".count)), seconds > 0
            else { return nil }
            return .seconds(seconds)
        }

        func start() {
            guard let delay else { return }
            Task { [weak self] in
                try? await Task.sleep(for: delay)
                self?.flip(to: .away)
                try? await Task.sleep(for: delay)
                self?.flip(to: .present)
            }
        }

        private func flip(to presence: PresencePolicy.Presence) {
            current = presence
            onChange?()
        }
    }

    /// Preferences that live and die with the process.
    ///
    /// Not merely tidiness. `HelperManager` persists the last curve, the startup
    /// preference and the persist toggle through this seam, and those keys steer
    /// what the **real** app does on its next launch — so a simulated session
    /// could hand the real one a curve the user never chose.
    final class Defaults: KeyValueStore {
        private var values: [String: Any] = [:]
        func set(_ value: Any?, forKey defaultName: String) {
            values[defaultName] = value
        }

        func removeObject(forKey defaultName: String) {
            values[defaultName] = nil
        }

        func string(forKey defaultName: String) -> String? {
            values[defaultName] as? String
        }

        func data(forKey defaultName: String) -> Data? {
            values[defaultName] as? Data
        }

        func bool(forKey defaultName: String) -> Bool {
            values[defaultName] as? Bool ?? false
        }

        func object(forKey defaultName: String) -> Any? {
            values[defaultName]
        }

        func integer(forKey defaultName: String) -> Int {
            values[defaultName] as? Int ?? 0
        }
    }

    /// A daemon that answers every call plausibly and writes to nothing.
    ///
    /// This is the piece that keeps rule 3 satisfiable. It holds the config it
    /// is given and reflects it back through ``status()``, so applying a preset,
    /// editing a curve, taking manual control and watching the Control card
    /// update all work exactly as they do against a real daemon — the commands
    /// simply stop here instead of reaching a mach service.
    ///
    /// `selfTestWritePath` returns `.verified` rather than `.unavailable`: the
    /// self-test is what the app runs automatically before a diagnostics export,
    /// and on real hardware it *writes to the SMC*. Returning a healthy verdict
    /// keeps the Settings pane demonstrable while guaranteeing no write happens.
    final class HelperChannel: HelperChanneling {
        var onDisconnect: (() -> Void)?
        private(set) var isConnected = false
        private var config = FanConfig(mode: .auto)

        func connect() {
            isConnected = true
        }

        func disconnect() {
            isConnected = false
            onDisconnect?()
        }

        /// The real protocol version, so the version handshake agrees and the
        /// app does not offer to update a daemon that does not exist.
        func version() async throws -> String {
            HelperConstants.protocolVersion
        }

        func apply(_ config: FanConfig) async throws {
            self.config = config
        }

        func setAllAuto() async throws {
            config = FanConfig(mode: .auto)
        }

        func heartbeat() {}

        /// Reflects back whatever was last applied, with targets derived from
        /// the config so the popover shows a moving picture rather than zeros.
        func status() async throws -> HelperStatus {
            HelperStatus(
                mode: config.mode,
                appliedTargets: config.manualTargets.isEmpty ? [0: 2400, 1: 2400] : config.manualTargets,
                unlockBranch: "direct",
                lastWriteVerified: true,
                guardianActive: false,
                recentEvents: [],
                activeCurve: config.sharedCurve,
                recentDecisions: nil
            )
        }

        func selfTestWritePath() async throws -> WritePathReport {
            WritePathReport(
                verdict: .verified,
                modeKeySuffix: "Md",
                unlockBranch: "direct",
                fanCount: 2,
                fanRanges: [0: [2317, 6800], 1: [2317, 6800]],
                hasFtstKey: false,
                detail: "Simulated — no SMC write was performed."
            )
        }
    }
}
