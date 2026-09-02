// HeatFlow.swift — what the schematic is allowed to say about the state it is drawing.

import Foundation

/// The one-line reading under the cooling schematic.
///
/// **SCOPE CORRECTION (2026-08-17), before this shipped.** The plan for this
/// window promised a third state — "fans fast but heat is not leaving", the
/// dust-and-dried-paste signature — read off the spread between the two airflow
/// sensors. Checked against the reference machine before writing it: on
/// Mac14,9 under load those two sensors read **46.8 °C and 47.0 °C**
/// (docs/THERMAL.md), a spread of 0.2 °C *while cooling was working perfectly*.
/// They are both in the airflow path a few centimetres apart; neither is at an
/// end of it. There is no spread to threshold, so the state was not detectable
/// and has been removed rather than faked.
///
/// The question it was meant to answer is real, and it already has an owner:
/// `R = (T_die − T_ambient) / P` needs the watts and a settle rule, which is
/// ``CoolingEfficiency`` and the Cooling History window. Inside shows the
/// gradient as a live figure and links there. It does not compete with the
/// measured claim, and it does not invent a second one.
public enum HeatFlow {
    /// What the machine is doing, at the coarsest honest resolution.
    public enum State: String, Sendable, Equatable, CaseIterable {
        /// The die is at or below the air reference — a cold boot, or a
        /// machine that has been asleep. Nothing to report yet.
        case warmingUp
        /// Below ``warmCelsius``. Not much is happening.
        case coolAndQuiet
        /// Warm or hot, and the fans are moving in proportion.
        case working
        /// Warm or hot and **nothing is turning**. The state this app exists
        /// for: macOS letting a machine sit hot rather than spending noise.
        case hotAndUncooled
    }

    /// Warm enough that something ought to be cooling it, °C.
    ///
    /// 68 °C is not a new number: it is ``FanGuardian``'s own engage floor,
    /// lowered to this value in `12f63aa` (75 → 68 °C) after macOS was observed
    /// holding both fans at 0 RPM with the die at 69.9 °C. Reusing it means the picture and
    /// the daemon agree about what "warm" means, which they would not if this
    /// file picked its own.
    public static let warmCelsius = 68.0

    /// Below this fraction of a fan's own range, nothing useful is turning.
    ///
    /// Not zero. A fan parked at its firmware minimum is spinning without being
    /// commanded to cool anything, and reporting that as "working" would hide
    /// exactly the case ``State/hotAndUncooled`` exists to show.
    public static let movingFraction = 0.15

    /// How far the hottest silicon sits above the incoming air, °C.
    ///
    /// `nil` when this Mac reports no die sensor or no airflow sensor, and
    /// **negative results are refused** rather than drawn: a die below the air
    /// reference is the cold-boot case ``CoolingEfficiency/resistance(dieCelsius:ambientCelsius:watts:)``
    /// already declines to answer, and a bar drawn backwards would be worse
    /// than no bar.
    public static func gradient(for temperatures: [SensorReading]) -> Double? {
        guard let die = temperatures.hottestDieCelsius,
              let air = CoolingEfficiency.ambient(from: temperatures)
        else { return nil }
        let rise = die - air
        return rise > 0 ? rise : nil
    }

    /// Mean fan speed as a fraction of each fan's own range, 0…1.
    ///
    /// `nil` on a Mac with no fans **and** on a Mac whose fans all reported an
    /// unusable range — two different situations that share an answer here,
    /// because in both the drawing has no blower to turn. The caller
    /// distinguishes them; ``State`` does not need to.
    ///
    /// Each fan against its own maximum, so the figure is portable across
    /// machines with different ranges — the same normalisation ``FanBand``
    /// uses to make history comparable.
    public static func flowFraction(_ fans: [Fan]) -> Double? {
        let usable = fans.filter { $0.maxRPM > 0 }
        guard !usable.isEmpty else { return nil }
        let total = usable.reduce(0.0) { $0 + ($1.actualRPM / $1.maxRPM).clamped(to: 0 ... 1) }
        return total / Double(usable.count)
    }

    /// How much of the die's rise above the incoming air the exhaust air is
    /// drawn as carrying.
    ///
    /// **A visual scale, not a measurement, and the only invented number in
    /// this file.** Air leaving a laptop's fins sits somewhere between the
    /// intake and the heatsink base, which is itself well below the die — a
    /// third is the plausible middle of that for this class of machine. It
    /// exists because the alternative is drawing air that reaches die
    /// temperature, which would be a lie, or drawing no warming at all, which
    /// is what the sensors force (below).
    public static let carriedShare = 0.34

    /// The temperature to draw the air at, `progress` of the way along its
    /// path — 0 at the intake vent, 1 leaving the exhaust.
    ///
    /// **Why this is not simply an interpolation between the two airflow
    /// sensors.** It was, and it produced particles of a single flat colour on
    /// real hardware. `TaLP` and `TaRF` read **46.8 °C and 47.0 °C** on Mac14,9
    /// under load (docs/THERMAL.md): they sit centimetres apart in the same
    /// duct, and neither is at an end of the airflow. There is no measured
    /// spread between them to colour with — the same finding that removed this
    /// window's "heat is not leaving" state.
    ///
    /// So the ramp is an **illustration of heat pickup**, and its size is tied
    /// to something real: `dieRise`, the hottest silicon above the incoming
    /// air, which is the heat actually being carried away. An idle machine's
    /// air barely changes colour; a working one's visibly warms across the
    /// fins. The direction is cool-to-warm because that is the direction heat
    /// moves — air enters cool, crosses the heatsink, and leaves hot. Drawing
    /// it the other way would show heat flowing into the machine.
    ///
    /// Bounded by the die: air cannot leave hotter than the thing heating it.
    public static func airTemperature(progress: Double, intake: Double, dieRise: Double?) -> Double {
        guard let dieRise, dieRise > 0, progress.isFinite, intake.isFinite else { return intake }
        // Flat up to the blower, then warming across the fin stack — the heat
        // is picked up at the fins, not on the way to them.
        let crossing = ((progress - 0.62) / 0.38).clamped(to: 0 ... 1)
        // Smoothstep, so the colour eases rather than switching at one point.
        let eased = crossing * crossing * (3 - 2 * crossing)
        return intake + dieRise * carriedShare * eased
    }

    /// The state to report for a snapshot.
    ///
    /// A fanless Mac never reaches ``State/hotAndUncooled``. It has no fans by
    /// design and its whole thermal design assumes none, so telling its owner
    /// that nothing is cooling their Mac would be alarming and wrong — the same
    /// distinction ``FanBand/fanless`` is a separate case for.
    public static func state(for snapshot: SMCSnapshot) -> State {
        guard let gradient = gradient(for: snapshot.temperatures), gradient > 0 else {
            return .warmingUp
        }
        guard let die = snapshot.temperatures.hottestDieCelsius, die >= warmCelsius else {
            return .coolAndQuiet
        }
        guard let flow = flowFraction(snapshot.fans) else { return .working }
        return flow >= movingFraction ? .working : .hotAndUncooled
    }
}
