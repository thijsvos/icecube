// PowerProfilePolicyTests.swift — switching on a power change, and refusing to switch on anything else.

import Foundation
@testable import IceCubeKit
import Testing

/// The rule is small; the thing worth testing is what it *refuses* to do.
/// Ice Cube has already shipped a default that re-asserted itself over a user's
/// choice, and an "on battery ⇒ Quiet" rule that enforced continuously would be
/// the same bug wearing a different hat.
@Suite("PowerProfilePolicy — switch on a change, never enforce")
struct PowerProfilePolicyTests {
    private let rule = PowerProfilePolicy.Rule(
        isEnabled: true, onBattery: .quiet, onWall: .cold
    )

    @Test("Unplugging switches to the battery preset")
    func unplugSwitches() {
        let decision = PowerProfilePolicy.decide(source: .battery, previous: .wall, rule: rule)
        #expect(decision == .apply(.quiet))
    }

    @Test("Plugging in switches to the wall preset")
    func plugInSwitches() {
        let decision = PowerProfilePolicy.decide(source: .wall, previous: .battery, rule: rule)
        #expect(decision == .apply(.cold))
    }

    /// THE test. Between two power changes the user is free to pick anything,
    /// and nothing may take it away from them — the policy is never asked
    /// "what should be running?", only "did the power source just change?".
    @Test("An unchanged power source never re-applies, so a manual pick stands")
    func unchangedSourceLeavesAlone() {
        #expect(PowerProfilePolicy.decide(source: .battery, previous: .battery, rule: rule) == .leaveAlone)
        #expect(PowerProfilePolicy.decide(source: .wall, previous: .wall, rule: rule) == .leaveAlone)
    }

    /// Even repeatedly. A poll loop that re-evaluated every few seconds must not
    /// accumulate into enforcement.
    @Test("Evaluating the same state a hundred times still changes nothing")
    func repeatedEvaluationIsInert() {
        for _ in 0 ..< 100 {
            #expect(PowerProfilePolicy.decide(source: .battery, previous: .battery, rule: rule) == .leaveAlone)
        }
    }

    @Test("A disabled rule does nothing, even across a real transition")
    func disabledRuleDoesNothing() {
        var off = rule
        off.isEnabled = false
        #expect(PowerProfilePolicy.decide(source: .battery, previous: .wall, rule: off) == .leaveAlone)
        #expect(PowerProfilePolicy.decide(source: .wall, previous: .battery, rule: off) == .leaveAlone)
    }

    /// First evaluation of a session: no previous source, so this IS a change.
    /// Launching already unplugged should honour the rule the user set.
    @Test("The first evaluation of a session counts as a change")
    func firstEvaluationApplies() {
        #expect(PowerProfilePolicy.decide(source: .battery, previous: nil, rule: rule) == .apply(.quiet))
        #expect(PowerProfilePolicy.decide(source: .wall, previous: nil, rule: rule) == .apply(.cold))
    }

    @Test("Mapping both sides to the same preset still only fires on a change")
    func sameOnBothSides() {
        let flat = PowerProfilePolicy.Rule(isEnabled: true, onBattery: .balanced, onWall: .balanced)
        #expect(PowerProfilePolicy.decide(source: .battery, previous: .wall, rule: flat) == .apply(.balanced))
        #expect(PowerProfilePolicy.decide(source: .battery, previous: .battery, rule: flat) == .leaveAlone)
    }

    /// The rule is persisted, so it has to survive a round trip — and a rule
    /// that silently failed to decode would read as "off", quietly abandoning
    /// a setting the user configured.
    @Test("The rule round-trips through JSON")
    func ruleRoundTrips() throws {
        let data = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(PowerProfilePolicy.Rule.self, from: data) == rule)
    }

    @Test("The suggested rule is off until the user turns it on")
    func suggestedRuleIsOff() {
        #expect(PowerProfilePolicy.Rule.suggested.isEnabled == false)
        #expect(
            PowerProfilePolicy.decide(
                source: .battery, previous: .wall, rule: .suggested
            ) == .leaveAlone,
            "a suggestion must not act until accepted"
        )
    }
}
