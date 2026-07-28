// FanActivity.swift — what one fan's numbers mean on screen: filling, ramping, or starting from rest.

import Foundation

/// The display decisions for a single fan, derived once from a ``Fan`` reading.
///
/// Extracted from `PopoverView` because none of this is view code — it is
/// hardware knowledge, and it is the densest concentration of it in the app:
/// the measured ~1.5 s firmware dead time, the stale-`F{i}Tg` trap, and a
/// divide guard over a `maxRPM` that really is 0 on a half-failed read. Every
/// one of those rules was written after something on screen said the wrong
/// thing on real hardware, and none of them could be tested where they lived.
///
/// A value type computed once per row per tick, so the view asks each question
/// of the same snapshot rather than re-deriving from `fan` four times.
public struct FanActivity: Sendable, Equatable {
    /// What the big number should say.
    ///
    /// A case rather than a `Bool` because the alternative to a speed is not
    /// "a speed with a flag" — it is a different thing to render, and every
    /// surface that shows it (including VoiceOver) has to make the same choice.
    public enum Readout: Sendable, Equatable {
        /// Commanded, but the tachometer has not moved yet.
        case starting
        /// Reporting real motion.
        case speed(rpm: Double)
    }

    public let readout: Readout
    /// `actualRPM` as a fraction of maximum (0…1), measured from **0**, not
    /// from the fan's minimum.
    ///
    /// A fan spinning at its floor (Quiet parks it at `Mn`) must still show a
    /// visibly partial bar, never an empty one that reads as "stopped". The
    /// only empty bar is a genuinely stopped fan.
    public let fillFraction: Double
    /// Where the gauge tick goes, or `nil` when there is no destination worth
    /// marking.
    public let rampTargetFraction: Double?
    /// The RPM to show as "→ 4400", or `nil` when the fan is not meaningfully
    /// short of its target.
    public let rampTargetRPM: Double?

    /// How far a fan may trail its target before the row says where it is
    /// heading. Below this, the gauge tick alone tells the story.
    static let rampVisibleRPM: Double = 300
    /// Below this the tachometer is treated as not yet moving.
    static let stoppedRPM: Double = 100

    public init(_ fan: Fan) {
        // Every rule below requires `.forced` — Ice Cube actually driving this
        // fan. `targetRPM` is simply the last value written to `F{i}Tg` and it
        // PERSISTS after control is handed back: a revert parks it at the fan's
        // minimum and then gives the fan to macOS, which may well settle at
        // 0 RPM. Reading that stale number as a destination made Automatic
        // display a permanent "→ 2317" while the fan sat still — promising
        // something nothing was working toward, which is worse than silence.
        let driving = fan.mode == .forced

        fillFraction = fan.maxRPM > 0
            ? (fan.actualRPM / fan.maxRPM).clamped(to: 0 ... 1)
            : 0

        rampTargetFraction = driving && fan.maxRPM > 0 && fan.targetRPM > 0
            ? (fan.targetRPM / fan.maxRPM).clamped(to: 0 ... 1)
            : nil

        // Only counts ramping UP: winding down is not something a user waits
        // on, and showing it would put a hint on screen most of the time for
        // no gain.
        let rampingUp = driving
            && fan.targetRPM > 0
            && fan.targetRPM - fan.actualRPM > Self.rampVisibleRPM
        rampTargetRPM = rampingUp ? fan.targetRPM : nil

        // Measured on a Mac14,9 at 5 samples/s: a stopped fan given a target
        // reads EXACTLY 0 RPM for ~1.5 s before the tachometer shows anything,
        // then climbs to speed over another ~3 s. The whole ramp is
        // firmware-paced — driving the fan at 6800 instead of 4250 produced an
        // identical curve (295/573/839/1731…) and an identical dead time, so it
        // cannot be made faster from here.
        //
        // What it CAN do is stop lying about it. "0 RPM" during that window
        // says nothing is happening when the fan is in fact starting, which is
        // exactly when someone concludes the app is broken and switches back.
        //
        // KNOWN GAP, deliberately preserved: the comparison is `>` against
        // `minRPM`, and a Quiet or Balanced curve on a cool Mac commands
        // EXACTLY `minRPM` — so "starting…" does not fire in part of the
        // scenario it was written for. Changing it to `>=` is a behaviour
        // change and belongs in its own commit, not in the extraction that
        // merely moved this rule somewhere it can finally be tested.
        let starting = driving && fan.targetRPM > fan.minRPM && fan.actualRPM < Self.stoppedRPM
        readout = starting ? .starting : .speed(rpm: fan.actualRPM)
    }
}
