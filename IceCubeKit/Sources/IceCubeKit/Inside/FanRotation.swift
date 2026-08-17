// FanRotation.swift — the drawn blade angle, and why it is deliberately not the real one.

import Foundation

/// Where a drawn blower's blades point at a given moment.
///
/// A pure function of fan speed and a time value, in the ``MockSMCSimulation``
/// idiom: same inputs, same angle, so the drawing is testable without a window
/// and a window that stopped redrawing resumes exactly where it left off
/// instead of jumping.
///
/// **The drawn speed is deliberately not the true speed, and the window prints
/// the true one beside it.** A fan drawn at 6,800 RPM into a 30 fps canvas
/// aliases — the wagon-wheel effect — and appears to slow, stop, or run
/// backwards. That would be a lie told most loudly at exactly the moment the
/// machine is working hardest and the user most needs to trust the picture. So
/// ``displayRPM(rpm:maxRPM:)`` maps the fan's own range onto a rate that stays
/// under the alias ceiling and is monotonic throughout: a faster fan always has
/// visibly faster blades. Above that, ``blur(rpm:maxRPM:)`` fades the discrete
/// blades into a rotating disc, which is what a fast fan actually looks like
/// and which cannot alias at all because there is no longer a blade to count.
public enum FanRotation {
    /// The canvas redraw rate the alias ceiling is derived from, frames/second.
    ///
    /// Was 30, which was a mistake worth recording: combined with the values
    /// below it put the fastest drawn fan *exactly* on the Nyquist limit, which
    /// is the one rate at which a rotating object is guaranteed to look
    /// stationary. A fan that stops moving when the machine works hardest is
    /// the opposite of the point.
    public static let frameRate = 60.0

    /// Blades drawn per blower. Not the real count — Apple's blowers have 31
    /// or 61 unevenly spaced blades, which at any drawable size is a grey
    /// smudge. Seven reads as a fan, and fewer blades buy more rotation speed
    /// before aliasing, because what aliases is *blade passes*, not turns.
    public static let bladeCount = 7

    /// How much of the frame rate the blade-pass rate may use.
    ///
    /// A third, not the half Nyquist allows. Nyquist is where aliasing
    /// *begins*; sitting on it is where motion becomes ambiguous, and just
    /// under it is where a wheel looks like it is dragging. A third leaves
    /// enough margin that rotation reads cleanly and always in the right
    /// direction.
    public static let aliasSafetyFactor = 3.0

    /// The fastest the blades may appear to turn, RPM.
    ///
    /// `bladeCount × revolutions/second` must stay under
    /// `frameRate / aliasSafetyFactor`. At 60 fps and seven blades that is
    /// 2.9 rev/s — about 171 RPM — which is a visibly, smoothly spinning fan.
    /// Faster fans are drawn at this rate with more blur rather than more
    /// speed, and the true figure is printed beside the drawing.
    public static var maximumDisplayRPM: Double {
        (frameRate / aliasSafetyFactor) / Double(bladeCount) * 60
    }

    /// The rate to draw at: the fan's own range mapped onto the alias ceiling.
    ///
    /// Linear in the fan's fraction rather than in absolute RPM, so a fan
    /// parked at its firmware minimum still visibly turns and the top of every
    /// machine's range lands at the same drawn speed. Zero maps to exactly
    /// zero — a stopped fan must be stopped, because "nothing is cooling this"
    /// is a state the picture has to be able to show.
    public static func displayRPM(rpm: Double, maxRPM: Double) -> Double {
        guard maxRPM > 0, rpm.isFinite, rpm > 0 else { return 0 }
        return maximumDisplayRPM * (rpm / maxRPM).clamped(to: 0 ... 1)
    }

    /// How fast the blades should turn, in turns per second.
    ///
    /// A **rate**, not a position. It used to be `phase(rpm:maxRPM:at:)`, which
    /// multiplied the absolute clock by this rate — correct only for a speed
    /// that never changes, and this one changes on every poll. See
    /// ``PhaseIntegrator`` for what that did to the drawing.
    public static func turnsPerSecond(rpm: Double, maxRPM: Double) -> Double {
        displayRPM(rpm: rpm, maxRPM: maxRPM) / 60
    }

    /// How far to fade discrete blades into a spinning disc, 0…1.
    ///
    /// Ramps to ``maximumBlur`` across the fan's range.
    ///
    /// Capped below 1 on purpose. Blur used to reach full opacity at 70 % of
    /// range, which erased the blades exactly when the fan was spinning
    /// fastest — so the drawing went *stiller* as the machine got busier. Blur
    /// is a speed cue layered over visible motion, never a replacement for it.
    public static let maximumBlur = 0.55

    public static func blur(rpm: Double, maxRPM: Double) -> Double {
        guard maxRPM > 0, rpm.isFinite, rpm > 0 else { return 0 }
        return ((rpm / maxRPM) * maximumBlur).clamped(to: 0 ... maximumBlur)
    }
}
