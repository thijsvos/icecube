// PowerProfilePolicy.swift — which preset a change of power source should switch to, and when to leave well alone.

import Foundation

/// Decides whether unplugging or plugging in should change the fan preset.
///
/// A laptop wants opposite things in the two situations. On battery it is on
/// your lap, probably at night, and every watt counts — quieter is worth a
/// warmer machine. On the wall it is on a desk and cool costs nothing. Ice Cube
/// applied one curve to both until now.
///
/// **Fires on transitions only, never continuously.** That is the whole safety
/// of the feature, not an implementation detail. This project has already
/// shipped a default that re-asserted itself and stomped the user's choice on
/// every launch (see ``StartupPolicy``'s HISTORY note, and CLAUDE.md ground
/// rule 4). A rule that enforced "on battery ⇒ Quiet" continuously would do
/// exactly that: pick Cold while unplugged and it would snap back, forever,
/// with no way to tell whether the app was broken or just opinionated.
///
/// So the question this answers is never "what should be running?" but "did the
/// power source just *change*?" — and if it did not, the answer is always
/// ``Decision/leaveAlone``. A preset chosen by hand stands until the user
/// physically plugs in or unplugs.
///
/// Pure, like ``StartupPolicy`` and ``SafetyMonitor``: inputs in, a decision
/// out, no I/O and no clock, so every branch is unit-tested without a battery.
public enum PowerProfilePolicy {
    /// Where the Mac is getting its power.
    public enum PowerSource: String, Sendable, Codable, Equatable {
        case battery
        /// Any external supply — charger, dock, or display delivering power.
        case wall
    }

    /// The user's mapping. Off until they configure it: both sides are their
    /// explicit choices, never guesses Ice Cube made for them.
    public struct Rule: Sendable, Codable, Equatable {
        public var isEnabled: Bool
        public var onBattery: Preset.Kind
        public var onWall: Preset.Kind

        /// Suggested in the UI as a starting point — quieter unplugged, cooler
        /// on the desk — but never applied until `isEnabled` is turned on.
        public static let suggested = Rule(isEnabled: false, onBattery: .quiet, onWall: .balanced)

        public init(isEnabled: Bool, onBattery: Preset.Kind, onWall: Preset.Kind) {
            self.isEnabled = isEnabled
            self.onBattery = onBattery
            self.onWall = onWall
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Change nothing — the rule is off, or the power source did not change.
        ///
        /// The second case is the important one: it is what protects a preset
        /// the user picked by hand from being undone a moment later.
        case leaveAlone
        /// Switch to this preset, because the power source just changed.
        case apply(Preset.Kind)
    }

    /// Decides whether a change of power source should switch presets.
    ///
    /// - Parameters:
    ///   - source: where the Mac is drawing power right now.
    ///   - previous: the source at the last decision, or `nil` if none has been
    ///     taken yet this session.
    ///   - rule: the user's mapping.
    public static func decide(
        source: PowerSource, previous: PowerSource?, rule: Rule
    ) -> Decision {
        guard rule.isEnabled else { return .leaveAlone }
        // The guard the whole feature rests on. Without it this becomes an
        // enforcer rather than a responder, and a manual preset chosen while
        // unplugged would be reverted on the very next evaluation.
        guard source != previous else { return .leaveAlone }
        return .apply(source == .battery ? rule.onBattery : rule.onWall)
    }
}
