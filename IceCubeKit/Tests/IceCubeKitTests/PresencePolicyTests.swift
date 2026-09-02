// PresencePolicyTests.swift — leaving switches, returning hands back, and everything else is refused.

import Foundation
@testable import IceCubeKit
import Testing

/// Like ``PowerProfilePolicyTests``, the thing worth testing is what the rule
/// *refuses* to do: enforce a state, take over a manual choice, or hand back
/// a curve over something the user picked in the meantime.
@Suite("PresencePolicy — leave, come back, and never enforce")
struct PresencePolicyTests {
    private let rule = PresencePolicy.Rule(isEnabled: true, whileAway: .cold)
    private let balanced = FanConfig.curve(.balanced)
    private let cold = FanConfig.curve(.cold)

    /// A departure the rule acted on, as the caller records it: `restoreTo`
    /// from the decision, `appliedWhileAway` after the apply succeeded.
    private func afterLeaving(from running: FanConfig) -> PresencePolicy.Memory {
        var memory = PresencePolicy.Memory.empty
        let decision = PresencePolicy.decide(
            presence: .away, previous: .present, rule: rule, applied: running, memory: &memory
        )
        #expect(decision == .apply(.cold))
        memory.appliedWhileAway = cold
        return memory
    }

    @Test("Leaving switches to the away preset and remembers what was running")
    func leavingApplies() {
        var memory = PresencePolicy.Memory.empty
        let decision = PresencePolicy.decide(
            presence: .away, previous: .present, rule: rule, applied: balanced, memory: &memory
        )
        #expect(decision == .apply(.cold))
        #expect(memory.restoreTo == balanced)
        #expect(memory.appliedWhileAway == nil, "the caller records the apply, after it succeeds")
    }

    @Test("Coming back restores what was running")
    func returningRestores() {
        var memory = afterLeaving(from: balanced)
        let decision = PresencePolicy.decide(
            presence: .present, previous: .away, rule: rule, applied: cold, memory: &memory
        )
        #expect(decision == .restore(balanced))
        #expect(memory == .empty, "a return spends the memory")
    }

    /// THE test. Between leaving and returning something else may have chosen
    /// a preset — the power rule, or a hand on the keyboard in the second
    /// before the unlock was noticed — and the rule must not undo it.
    @Test("Coming back leaves alone whatever someone else chose in between")
    func returningYieldsToAnotherChoice() {
        var memory = afterLeaving(from: balanced)
        let decision = PresencePolicy.decide(
            presence: .present, previous: .away, rule: rule, applied: .curve(.quiet), memory: &memory
        )
        #expect(decision == .leaveAlone)
        #expect(memory == .empty, "and does not keep the stale memory for a later return")
    }

    /// A safety revert during sleep leaves the daemon on auto — nobody's
    /// choice, and exactly the state the user would least like to come back
    /// to. Restoring over it is handing back, not overriding.
    @Test("Coming back to the daemon's resting state still restores")
    func returningOverAutoRestores() {
        var memory = afterLeaving(from: balanced)
        let decision = PresencePolicy.decide(
            presence: .present, previous: .away, rule: rule, applied: .auto, memory: &memory
        )
        #expect(decision == .restore(balanced))
    }

    /// The comparison is by choice, not by byte: the app's own bookkeeping
    /// rebuilds the same curve with a different persist flag after a wake.
    @Test("The same curve with a different persist flag still counts as ours")
    func persistFlagDoesNotBreakRestore() {
        var memory = afterLeaving(from: balanced)
        let decision = PresencePolicy.decide(
            presence: .present, previous: .away, rule: rule,
            applied: .curve(.cold, persists: true), memory: &memory
        )
        #expect(decision == .restore(balanced))
    }

    @Test("Manual mode is left alone in both directions")
    func manualIsLeftAlone() {
        let manual = FanConfig(mode: .manual, manualTargets: [0: 3000])
        var memory = PresencePolicy.Memory.empty
        #expect(
            PresencePolicy.decide(
                presence: .away, previous: .present, rule: rule, applied: manual, memory: &memory
            ) == .leaveAlone
        )
        #expect(memory == .empty, "nothing was taken, so nothing is owed")

        // And coming back to manual after a departure the rule did act on:
        // the user sat down and pinned a speed; that stands.
        memory = afterLeaving(from: balanced)
        #expect(
            PresencePolicy.decide(
                presence: .present, previous: .away, rule: rule, applied: manual, memory: &memory
            ) == .leaveAlone
        )
    }

    /// A departure that cannot promise a return would strand the user on the
    /// away preset — so with nothing known to be running, nothing happens.
    @Test("Leaving with nothing to hand back does nothing")
    func leavingWithNothingRunningDoesNothing() {
        var memory = PresencePolicy.Memory.empty
        #expect(
            PresencePolicy.decide(
                presence: .away, previous: .present, rule: rule, applied: nil, memory: &memory
            ) == .leaveAlone
        )
        #expect(
            PresencePolicy.decide(
                presence: .away, previous: .present, rule: rule, applied: .auto, memory: &memory
            ) == .leaveAlone
        )
        #expect(memory == .empty)
    }

    /// The memory is only worth honouring if the apply actually happened —
    /// even when the fans are on the resting state, which would otherwise
    /// count as ours to restore over.
    @Test("A departure whose apply never succeeded restores nothing")
    func unrecordedApplyRestoresNothing() {
        var memory = PresencePolicy.Memory(restoreTo: balanced, appliedWhileAway: nil)
        #expect(
            PresencePolicy.decide(
                presence: .present, previous: .away, rule: rule, applied: .auto, memory: &memory
            ) == .leaveAlone
        )
    }

    @Test("Unchanged presence never re-applies, however often it is asked")
    func unchangedPresenceIsInert() {
        var memory = afterLeaving(from: balanced)
        for _ in 0 ..< 100 {
            #expect(
                PresencePolicy.decide(
                    presence: .away, previous: .away, rule: rule, applied: cold, memory: &memory
                ) == .leaveAlone
            )
        }
        #expect(memory.restoreTo == balanced, "polling while away must not erode the memory")
        for _ in 0 ..< 100 {
            #expect(
                PresencePolicy.decide(
                    presence: .present, previous: .present, rule: rule, applied: balanced, memory: &memory
                ) == .leaveAlone
            )
        }
    }

    @Test("A disabled rule does nothing and forgets any pending return")
    func disabledRuleDoesNothing() {
        var off = rule
        off.isEnabled = false
        var memory = afterLeaving(from: balanced)
        #expect(
            PresencePolicy.decide(
                presence: .present, previous: .away, rule: off, applied: cold, memory: &memory
            ) == .leaveAlone
        )
        #expect(memory == .empty, "turning the rule off while away must not leave a restore armed")
        #expect(
            PresencePolicy.decide(
                presence: .away, previous: .present, rule: off, applied: balanced, memory: &memory
            ) == .leaveAlone
        )
    }

    /// First evaluation of a session. Launching to a locked screen is a
    /// departure; launching to an unlocked one is nothing at all.
    @Test("The first evaluation of a session counts as a change")
    func firstEvaluation() {
        var memory = PresencePolicy.Memory.empty
        #expect(
            PresencePolicy.decide(
                presence: .away, previous: nil, rule: rule, applied: balanced, memory: &memory
            ) == .apply(.cold)
        )
        memory = .empty
        #expect(
            PresencePolicy.decide(
                presence: .present, previous: nil, rule: rule, applied: balanced, memory: &memory
            ) == .leaveAlone
        )
    }

    @Test("The rule round-trips through JSON")
    func ruleRoundTrips() throws {
        let data = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(PresencePolicy.Rule.self, from: data) == rule)
    }

    @Test("The suggested rule is off until the user turns it on")
    func suggestedRuleIsOff() {
        #expect(PresencePolicy.Rule.suggested.isEnabled == false)
        var memory = PresencePolicy.Memory.empty
        #expect(
            PresencePolicy.decide(
                presence: .away, previous: .present, rule: .suggested, applied: balanced, memory: &memory
            ) == .leaveAlone,
            "a suggestion must not act until accepted"
        )
    }
}
