// PhaseIntegrator.swift — accumulates a rotation phase, so a change of speed never moves the thing being drawn.

import Foundation

/// A phase that advances at a speed which is allowed to change.
///
/// **The bug this exists for.** The schematic first computed phase directly from
/// the clock: `phase = seconds × speed`. That is correct only while `speed` is
/// constant, and here it never is — the flow rate and the blade rate are both
/// derived from `actualRPM`, which arrives fresh on every poll and drifts by a
/// few RPM each time. `seconds` is `timeIntervalSinceReferenceDate`, around
/// 8.3 × 10⁸, so a speed change of one part in ten thousand moved the result by
/// **83,000 cycles**: every particle and every blade teleported to an unrelated
/// phase, once a second, for as long as the window was open. It read as a
/// stutter, which is what a jump to a random position looks like when it happens
/// at a steady rate.
///
/// Multiplying an absolute clock by a varying rate cannot be made continuous —
/// the discontinuity is proportional to how long the program has been running.
/// The fix is to integrate instead: advance by `rate × dt` and keep the total.
/// That costs the "pure function of time" property the drawing was designed
/// around, and it was the wrong property to want.
public struct PhaseIntegrator: Sendable, Equatable {
    /// Accumulated phase in **turns**, always in `0..<1`.
    public private(set) var phase: Double = 0
    private var lastSeconds: Double?

    /// The longest step that may be integrated at once, seconds.
    ///
    /// A window that was hidden, or a Mac that slept, resumes with a `dt` of
    /// minutes or hours. Integrating that would spin the blades through
    /// thousands of turns in one frame, which is the same visual glitch this
    /// type exists to remove, arriving by a different route. Anything longer is
    /// treated as a resume: the clock is re-anchored and the phase is left
    /// where it was.
    public static let maximumStep = 0.5

    public init(phase: Double = 0) {
        self.phase = phase - phase.rounded(.down)
    }

    /// Advances to `seconds` at `turnsPerSecond` and returns the new phase.
    ///
    /// **Idempotent for a repeated `seconds`.** SwiftUI may evaluate a view body
    /// more than once for the same frame — a resize, a state change elsewhere —
    /// and a draw that advanced the phase on each of those would run fast and
    /// unevenly. Asking for the same instant twice gives the same answer, so the
    /// caller can mutate this from inside a draw without having to reason about
    /// how often the draw happens.
    ///
    /// That property comes from the `delta > 0` guard below and not from a
    /// separate equality check. There was one, and it was an exactly equivalent
    /// branch — a repeated instant gives `delta == 0`, which the same guard
    /// already rejects. Two mechanisms for one rule is one more than can be
    /// tested, and a mutation of the redundant half survives by definition.
    ///
    /// **The phase can never go non-finite**, and that is a property of the
    /// guard below rather than of a separate check on the input. `delta > 0`
    /// and `delta <= maximumStep` both reject NaN, `turnsPerSecond.isFinite`
    /// rejects the other route, and `lastSeconds` is re-anchored before any of
    /// them — so a NaN instant costs exactly one frame of motion and nothing
    /// else. There was an explicit `seconds.isFinite` guard here; it was
    /// removed because it changed nothing observable, and an unobservable
    /// branch is one no test can defend.
    @discardableResult
    public mutating func advance(to seconds: Double, turnsPerSecond: Double) -> Double {
        guard let last = lastSeconds else {
            lastSeconds = seconds
            return phase
        }
        let delta = seconds - last
        lastSeconds = seconds
        // Backwards time (a clock adjustment) re-anchors without moving.
        guard delta > 0, delta <= Self.maximumStep, turnsPerSecond.isFinite else { return phase }

        let advanced = phase + turnsPerSecond * delta
        phase = advanced - advanced.rounded(.down)
        return phase
    }
}
