// ManualTargets.swift — the manual slider's three rules: engage where you are, show, and send every fan.

import Foundation

/// The pure rules behind the manual per-fan sliders.
///
/// Extracted because these are the only decisions in the popover that touch a
/// **safety invariant**: every value here passes through
/// ``FanWriteSequencer/clamp(_:to:)``, and one of them decides what the daemon
/// records as its tracked config. Both rules were written after a real defect,
/// and neither could be tested where it lived.
public enum ManualTargets {
    /// Entering manual mode: hold every fan exactly where it is now, so there
    /// is no jump in noise the moment the user takes over.
    ///
    /// Via the sequencer's guarded clamp, **not** `clamped(to: Mn ... Mx)`:
    /// `Mn` and `Mx` are read with independent `try?`s that each fall back to 0
    /// ("degrade per-key rather than losing the whole fan"), so an inverted
    /// range is a modelled outcome — and building a `ClosedRange` from one
    /// traps. The same helper the daemon clamps its writes with.
    public static func engaging(_ fans: [Fan]) -> [Int: Double] {
        Dictionary(
            fans.map { ($0.id, FanWriteSequencer.clamp($0.actualRPM, to: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// What to send on release — a target for **every** fan, not just the
    /// sliders the user touched.
    ///
    /// `sliderTargets` is `@State`, and since the off-screen popover
    /// optimisation the whole content subtree is torn down when the popover
    /// closes, so it starts empty on every reopen. Sending it verbatim meant
    /// that after a reopen, moving one slider committed a single-entry map:
    /// the daemon's engage skips fans missing from `targets`, so the other fan
    /// stayed physically **forced** while dropping out of the tracked config —
    /// where `verifyManualState` then reported it as held and the wake
    /// re-assert skipped it. Filling from the live readings keeps the map
    /// complete.
    ///
    /// KNOWN INCONSISTENCY, preserved deliberately: an untouched fan is *sent*
    /// its clamped `actualRPM` here, but ``displayed(_:for:)`` *shows* its
    /// `targetRPM`. Reopen the popover mid-ramp, drag one slider, and the other
    /// fan's commanded target silently drops to its instantaneous tachometer
    /// reading while its slider still shows the old number. Unifying both on
    /// `targetRPM` is the fix and is a behaviour change — it belongs in its own
    /// commit, after a two-fan check in simulated mode, not in the extraction
    /// that merely moved these rules somewhere they can be tested.
    public static func committing(_ edited: [Int: Double], fans: [Fan]) -> [Int: Double] {
        Dictionary(
            fans.map { fan in
                (fan.id, edited[fan.id] ?? FanWriteSequencer.clamp(fan.actualRPM, to: fan))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// What the slider and its readout show for one fan: the user's edit if
    /// there is one, otherwise the fan's commanded target.
    public static func displayed(_ edited: [Int: Double], for fan: Fan) -> Double {
        edited[fan.id] ?? fan.targetRPM
    }

    /// The slider's range.
    ///
    /// `max(maxRPM, minRPM + 1)` is not defensive noise: a fan whose `Mx` read
    /// failed reports 0, and `minRPM ... 0` traps at runtime. The +1 guarantees
    /// a non-empty range for a fan that cannot be meaningfully driven anyway.
    public static func sliderRange(for fan: Fan) -> ClosedRange<Double> {
        fan.minRPM ... Swift.max(fan.maxRPM, fan.minRPM + 1)
    }
}
