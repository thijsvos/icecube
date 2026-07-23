// CurveFollower.swift — the stateful curve tracker: input hysteresis + output ramp limiting.

import Foundation

/// Follows a ``FanCurve`` tick by tick, smoothing in two places:
///
/// - **Input hysteresis**: the temperature feeding the curve only moves when
///   the real reading drifts more than `hysteresisCelsius` from the last
///   accepted value — small wiggles (±1–2 °C every second) stop translating
///   into constant fan-speed changes.
/// - **Output ramp limiting**: the emitted fraction moves toward the curve's
///   demand by at most `rampPerTick` per step — speed changes are gradual,
///   never a lurch (PLAN.md §1.3 "max ΔRPM per second").
///
/// Pure state machine — no clock, no hardware — so every property is
/// unit-testable. One follower per fan lives in the daemon.
public struct CurveFollower: Sendable, Equatable {
    /// °C the input must move before the curve sees it.
    public var hysteresisCelsius: Double
    /// Maximum output change per tick, as fraction of the fan range
    /// (0.1 with a 2 s tick ≈ full range in 20 s).
    public var rampPerTick: Double

    private var effectiveTemp: Double?
    private var output: Double?

    public init(hysteresisCelsius: Double = 3, rampPerTick: Double = 0.1) {
        self.hysteresisCelsius = max(0, hysteresisCelsius)
        self.rampPerTick = min(max(rampPerTick, 0.01), 1)
    }

    /// Advances one tick: feeds `dieCelsius` through the deadband, evaluates
    /// `curve`, ramps toward the result. Returns the fraction to command
    /// (always finite, always 0…1).
    public mutating func step(dieCelsius: Double, curve: FanCurve) -> Double {
        if dieCelsius.isFinite {
            if let current = effectiveTemp {
                if abs(dieCelsius - current) >= hysteresisCelsius {
                    effectiveTemp = dieCelsius
                }
            } else {
                effectiveTemp = dieCelsius
            }
        }
        let desired = curve.fraction(at: effectiveTemp ?? dieCelsius)
        let next: Double = if let current = output {
            current + min(max(desired - current, -rampPerTick), rampPerTick)
        } else {
            desired // first tick: start where the curve says, no fake ramp-up
        }
        output = min(max(next, 0), 1)
        return output ?? 0
    }

    /// Forgets all state (mode changes, wake, new curve).
    public mutating func reset() {
        effectiveTemp = nil
        output = nil
    }
}
