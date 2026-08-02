// CurveFollower.swift — the stateful curve tracker: EMA smoothing + input deadband + asymmetric ramp limiting.

import Foundation

/// Follows a ``FanCurve`` tick by tick, smoothing the noisy die-temperature
/// signal in three stages so the fans respond to real thermal trends, not to
/// every momentary CPU burst (which is what makes fans "hunt" audibly):
///
/// 1. **EMA smoothing** of the raw input — an exponential moving average with
///    time constant ≈ `2s / smoothingAlpha`. A brief 2–4 s load spike barely
///    moves the average, so it doesn't reach the fans at all.
/// 2. **Input deadband** — the smoothed temperature must drift more than
///    `hysteresisCelsius` from the last accepted value before the curve
///    re-evaluates, killing tiny back-and-forth.
/// 3. **Asymmetric output ramp** — the emitted fraction rises quickly (safety)
///    but falls slowly (`rampDownPerTick < rampUpPerTick`), so the fans don't
///    nervously drop-then-re-raise; they ease down only on a sustained cooldown.
///
/// These defaults follow fan-tuning best practice (see docs/CREDITS.md): gentle
/// on the ears and, by avoiding needless speed cycling, gentle on the fan
/// bearings too. Pure state machine — no clock, no hardware — so every stage is
/// unit-tested. One follower per fan lives in the daemon.
public struct CurveFollower: Sendable, Equatable {
    /// EMA weight applied to each new reading (0 = frozen, 1 = no smoothing).
    /// 0.2 at a 2 s tick ≈ a 10 s time constant.
    public var smoothingAlpha: Double
    /// °C the smoothed input must move before the curve sees it.
    public var hysteresisCelsius: Double
    /// Max upward output change per tick, as a fraction of the fan range.
    public var rampUpPerTick: Double
    /// Max downward output change per tick — smaller than up, so cooldowns are
    /// gradual and the fans don't oscillate.
    public var rampDownPerTick: Double

    private var smoothedTemp: Double?
    private var effectiveTemp: Double?
    private var output: Double?

    public init(
        hysteresisCelsius: Double = 4,
        rampUpPerTick: Double = 0.1,
        rampDownPerTick: Double = 0.05,
        smoothingAlpha: Double = 0.2
    ) {
        // Bounded at both ends, not just below. A deadband wider than the
        // range a die actually moves through makes this follower inert:
        // `effectiveTemp` never updates, so the output stays wherever the first
        // tick put it while the die climbs. That is the one tuning value here
        // that can silently disable a curve — the ramp and alpha floors fail
        // loudly by comparison.
        //
        // 20 is deliberately far above anything the app can produce (the curve
        // editor's slider is 0...8), so this cannot quietly alter a legitimate
        // config. It exists for the values the UI never sees: a hand-edited
        // presets file, or a `FanConfig` decoded from XPC, where
        // `decodeIfPresent ?? 4` applies no bound at all.
        self.hysteresisCelsius = hysteresisCelsius.clamped(to: 0 ... 20)
        self.rampUpPerTick = rampUpPerTick.clamped(to: 0.01 ... 1)
        self.rampDownPerTick = rampDownPerTick.clamped(to: 0.01 ... 1)
        self.smoothingAlpha = smoothingAlpha.clamped(to: 0.01 ... 1)
    }

    /// Advances one tick: smooths `dieCelsius`, applies the deadband, evaluates
    /// `curve`, and ramps toward the result. Returns the fraction to command
    /// (always finite, always 0…1).
    public mutating func step(dieCelsius: Double, curve: FanCurve) -> Double {
        // 1. EMA smoothing (a non-finite reading is ignored — hold the last).
        if dieCelsius.isFinite {
            smoothedTemp = smoothedTemp.map { $0 + smoothingAlpha * (dieCelsius - $0) } ?? dieCelsius
        }
        let temp = smoothedTemp ?? dieCelsius
        guard temp.isFinite else { return output ?? 0 }

        // 2. Input deadband on the smoothed signal.
        if let current = effectiveTemp {
            if abs(temp - current) >= hysteresisCelsius {
                effectiveTemp = temp
            }
        } else {
            effectiveTemp = temp
        }
        let desired = curve.fraction(at: effectiveTemp ?? temp)

        // 3. Asymmetric ramp toward the curve's demand.
        let next: Double
        if let current = output {
            let delta = desired - current
            let limit = delta >= 0 ? rampUpPerTick : rampDownPerTick
            next = current + delta.clamped(to: -limit ... limit)
        } else {
            next = desired // first tick: start at demand, no artificial ramp-up
        }
        output = next.clamped(to: 0 ... 1)
        return output ?? 0
    }

    /// Forgets all state (mode changes, wake, new curve).
    public mutating func reset() {
        smoothedTemp = nil
        effectiveTemp = nil
        output = nil
    }
}
