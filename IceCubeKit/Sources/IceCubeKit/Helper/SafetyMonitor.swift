// SafetyMonitor.swift — the daemon's safety decision engine: watchdog, temp ceiling, sensor health (pure, injected
// time).

import Foundation

/// Evaluates every daemon tick and decides whether manual/curve control may
/// continue (PLAN.md §4.3). Pure state machine — time, temps, and heartbeats
/// are inputs — so every rule is unit-testable with a scripted clock.
///
/// Non-negotiable invariants enforced here:
/// - **Watchdog**: no app heartbeat for 15 s → revert, always in manual mode;
///   curve mode is exempt only when the config persists without the app.
/// - **Temperature ceiling**: any monitored sensor over its class ceiling for
///   N consecutive ticks → force maximum cooling, regardless of the user's
///   settings, until it cools 5 °C below the ceiling. Die sensors legitimately
///   run hotter than proximity sensors, hence per-class thresholds + debounce
///   (a single glitched tick must not slam the fans).
/// - **Sensor health**: >3 consecutive failed temperature reads while manual
///   control is active → revert (flying blind is not allowed).
public struct SafetyMonitor: Sendable {
    /// Tunables, overridable in tests only — release code uses the defaults.
    public struct Limits: Sendable {
        public var watchdogTimeout: Duration = .seconds(HelperConstants.watchdogTimeout)
        /// CPU/GPU die sensors reach 95–105 °C under legitimate full load.
        public var dieCeiling: Double = 104
        /// Everything else (airflow, SSD, battery…) should stay well below.
        public var otherCeiling: Double = 95
        /// Consecutive over-ceiling ticks required to trigger (debounce).
        public var ceilingDebounceTicks: Int = 3
        /// Cooling releases once the offender is this far below its ceiling.
        public var releaseDelta: Double = 5
        /// Consecutive failed sensor reads tolerated in manual/curve mode.
        public var sensorFailureLimit: Int = 3

        public init() {}
    }

    /// One tick's decision, in order of precedence.
    public enum Verdict: Sendable, Equatable {
        /// Continue as configured.
        case ok
        /// Overheating: drive every fan at maximum until released.
        case forceMaxCooling(offender: String)
        /// Manual/curve control must end now.
        case revertToAuto(reason: String)
    }

    /// Die-class sensor key prefixes (higher ceiling).
    private let limits: Limits
    private var overCeilingTicks = 0
    private var coolingActive = false
    private var sensorFailureTicks = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Evaluates one tick.
    ///
    /// Takes the heartbeat's **age**, not two absolute instants, on purpose.
    /// The watchdog is a duration rule, so a duration is all it needs — and
    /// taking `Date`s made the revert deferrable by a backwards wall-clock
    /// step (an NTP correction yielded a negative age, which is never greater
    /// than the timeout). The caller measures the age on a monotonic clock, so
    /// that class of bug cannot be expressed here.
    ///
    /// - Parameters:
    ///   - heartbeatAge: how long since the app last fed the watchdog, or
    ///     `nil` if it never has.
    ///   - config: what the daemon is currently enforcing.
    ///   - temperatures: this tick's readings, or `nil` if the read failed.
    public mutating func evaluate(
        heartbeatAge: Duration?,
        config: FanConfig,
        temperatures: [SensorReading]?
    ) -> Verdict {
        let controlling = config.mode != .auto

        // 1. Sensor health — flying blind while controlling is forbidden.
        if temperatures == nil {
            sensorFailureTicks += 1
            if controlling, sensorFailureTicks > limits.sensorFailureLimit {
                return .revertToAuto(reason: "sensor reads failed \(sensorFailureTicks) consecutive ticks")
            }
        } else {
            sensorFailureTicks = 0
        }

        // 2. Watchdog — manual is ALWAYS watchdogged; curve only when the
        // config does not persist without the app (PLAN.md §4.3.1).
        if controlling {
            let watchdogged = config.mode == .manual || !config.persistsWithoutApp
            if watchdogged {
                guard let heartbeatAge else {
                    return .revertToAuto(reason: "watchdog: no app heartbeat received")
                }
                if heartbeatAge > limits.watchdogTimeout {
                    let seconds = heartbeatAge.components.seconds
                    return .revertToAuto(reason: "watchdog: no app heartbeat for \(seconds) s")
                }
            }
        }

        // 3. Temperature ceiling — debounced trigger, hysteresis release.
        // Evaluated even in auto mode so status can surface it, but only
        // meaningful action happens while we hold the fans.
        if let temperatures {
            if let offender = worstOffender(in: temperatures) {
                overCeilingTicks += 1
                if coolingActive || overCeilingTicks >= limits.ceilingDebounceTicks {
                    coolingActive = true
                    return controlling ? .forceMaxCooling(offender: offender) : .ok
                }
            } else {
                overCeilingTicks = 0
                if coolingActive {
                    if allReleased(temperatures) {
                        coolingActive = false
                    } else if controlling {
                        // Still inside the hysteresis band: keep cooling.
                        return .forceMaxCooling(offender: "cooling until −\(Int(limits.releaseDelta)) °C below ceiling")
                    }
                }
            }
        }

        return .ok
    }

    /// The hottest sensor currently above its class ceiling, if any.
    private func worstOffender(in temperatures: [SensorReading]) -> String? {
        temperatures
            .filter { $0.celsius >= ceiling(for: $0.key) }
            .max { $0.celsius < $1.celsius }
            .map { "\($0.key) at \(Int($0.celsius.rounded())) °C" }
    }

    /// True once every sensor is below its ceiling minus the release delta.
    private func allReleased(_ temperatures: [SensorReading]) -> Bool {
        temperatures.allSatisfy { $0.celsius < ceiling(for: $0.key) - limits.releaseDelta }
    }

    private func ceiling(for key: String) -> Double {
        SMCKeyMaps.isDieKey(key) ? limits.dieCeiling : limits.otherCeiling
    }
}
