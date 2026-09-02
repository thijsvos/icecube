// PresencePolicy.swift — which preset to run while nobody is at the Mac, and how to hand back when they return.

import Foundation

/// Decides whether the user stepping away — or coming back — should change the
/// fan preset.
///
/// Fan noise is a cost only while someone can hear it. The preset chosen at
/// the keyboard keeps running after the screen locks and the chair empties, so
/// an export, a build or a backup left to finish overnight runs exactly as
/// quiet, and exactly as warm, as it did with someone watching. This rule
/// lets the user name a preset for those hours and get their own back the
/// moment they return.
///
/// **Fires on transitions only, never continuously** — ``PowerProfilePolicy``'s
/// doctrine, and for the same reason: a rule that enforced "away ⇒ Cold" on
/// every evaluation would be an enforcer, not a responder. The question is
/// never "what should be running?" but "did the user just leave, or just come
/// back?"
///
/// **Hands back only what it took.** Going away, it remembers what was running;
/// coming back, it restores that only if the fans are still on what it set —
/// or on the daemon's resting state, which is what a safety revert during
/// sleep leaves behind and is nobody's choice. Anything else that picked a
/// preset in between (the power rule, a hand on the keyboard in the first
/// second after unlock) wins, because it is more recent and it was chosen.
///
/// **Manual mode is left alone in both directions.** A fixed fan speed is the
/// user's explicit, hands-on choice, and CLAUDE.md ground rule 4 already says
/// no automation may put the fans under fixed-RPM control. Nor will this take
/// them out of it.
///
/// Pure, like ``StartupPolicy`` and ``PowerProfilePolicy``: inputs in, a
/// decision out, no I/O and no clock, so every branch is unit-tested without
/// a lock screen.
public enum PresencePolicy {
    /// Whether someone is at the Mac.
    public enum Presence: String, Sendable, Codable, Equatable {
        case present
        /// The screen is locked, the screensaver is running, or the display
        /// is asleep — macOS's own verdict that nobody is looking.
        case away
    }

    /// The user's choice. Off until they turn it on.
    public struct Rule: Sendable, Codable, Equatable {
        public var isEnabled: Bool
        /// The preset to run while nobody is there. A built-in, deliberately:
        /// this persists a `Preset.Kind`, exactly as ``PowerProfilePolicy/Rule``
        /// does, so the two rules share one picker and one on-disk shape.
        public var whileAway: Preset.Kind

        /// Suggested in the UI — cool the machine while nobody can hear it —
        /// but never applied until `isEnabled` is turned on.
        public static let suggested = Rule(isEnabled: false, whileAway: .cold)

        public init(isEnabled: Bool, whileAway: Preset.Kind) {
            self.isEnabled = isEnabled
            self.whileAway = whileAway
        }
    }

    /// What the rule displaced and what it put in its place, so the return
    /// trip can tell whether anything else chose a preset in between.
    ///
    /// In-process only. A launch is a return by definition, and a memory that
    /// outlived the process could restore a curve from a different day.
    public struct Memory: Sendable, Equatable {
        /// What was running when the user left.
        public var restoreTo: FanConfig?
        /// What the rule applied. `nil` until the apply succeeds — a memory of
        /// a preset that never reached the daemon would restore over a
        /// choice it never displaced.
        public var appliedWhileAway: FanConfig?

        public static let empty = Memory()

        public init(restoreTo: FanConfig? = nil, appliedWhileAway: FanConfig? = nil) {
            self.restoreTo = restoreTo
            self.appliedWhileAway = appliedWhileAway
        }
    }

    public enum Decision: Sendable, Equatable {
        /// Change nothing — the rule is off, presence did not change, there is
        /// nothing known to hand back, or something else chose since.
        case leaveAlone
        /// The user just left: switch to this preset.
        case apply(Preset.Kind)
        /// The user is back: put this config back.
        case restore(FanConfig)
    }

    /// Decides whether a change of presence should switch presets.
    ///
    /// - Parameters:
    ///   - presence: whether someone is at the Mac right now.
    ///   - previous: presence at the last decision, or `nil` if none has been
    ///     taken yet this session.
    ///   - rule: the user's choice.
    ///   - applied: the config the app believes is running.
    ///   - memory: what the last departure recorded. Updated in place: filled
    ///     on a departure the rule acts on, cleared on every return and
    ///     whenever the rule is off. The caller records `appliedWhileAway`
    ///     itself, after the apply succeeds.
    public static func decide(
        presence: Presence,
        previous: Presence?,
        rule: Rule,
        applied: FanConfig?,
        memory: inout Memory
    ) -> Decision {
        guard rule.isEnabled else {
            memory = .empty
            return .leaveAlone
        }
        // The guard the whole feature rests on — see PowerProfilePolicy.
        guard presence != previous else { return .leaveAlone }
        switch presence {
        case .away:
            // Only a curve can be handed back. Manual is the user's own
            // hands-on choice; auto and "nothing yet" leave nothing to
            // restore, and a departure that could not promise a return
            // would strand the user on the away preset.
            guard let applied, applied.mode == .curve else { return .leaveAlone }
            memory = Memory(restoreTo: applied, appliedWhileAway: nil)
            return .apply(rule.whileAway)
        case .present:
            defer { memory = .empty }
            guard let set = memory.appliedWhileAway, let back = memory.restoreTo else {
                return .leaveAlone
            }
            guard isStillOurs(applied, set: set) else { return .leaveAlone }
            return .restore(back)
        }
    }

    /// Whether the fans are still on what the rule set — or on the daemon's
    /// resting state, which a safety revert during sleep leaves behind and
    /// which nobody chose. Compared by mode and curve rather than the whole
    /// config, because the app's own bookkeeping may rebuild the same choice
    /// with a different persist flag.
    static func isStillOurs(_ applied: FanConfig?, set: FanConfig) -> Bool {
        guard let applied else { return false }
        if applied.mode == .auto {
            return true
        }
        return applied.mode == set.mode && applied.sharedCurve == set.sharedCurve
    }
}
