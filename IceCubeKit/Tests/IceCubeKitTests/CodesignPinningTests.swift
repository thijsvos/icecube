// CodesignPinningTests.swift — the XPC requirement string: shape, Security-framework validity, and failing closed.

import Foundation
@testable import IceCubeKit
import Security
import Testing

/// The one security control in the codebase had no tests at all. These pin two
/// separate things: that the requirement we generate is what TN3127 describes,
/// and that a requirement the Security framework would reject can never escape
/// this type — because the XPC APIs that consume it raise an uncatchable
/// Objective-C exception on a malformed string, which in the root daemon means
/// a crash loop under launchd.
@Suite("CodesignPinning")
struct CodesignPinningTests {
    private let identifier = "io.github.thijsvos.icecube"
    private let teamID = "ABCDE12345"

    @Test("The development requirement pins identifier, Apple anchor, WWDR intermediate and team OU")
    func requirementShape() {
        let requirement = CodesignPinning.developmentRequirement(
            identifier: identifier, teamID: teamID
        )
        #expect(requirement.contains("identifier \"\(identifier)\""))
        #expect(requirement.contains("anchor apple generic"))
        // The WWDR marker — this is what distinguishes the development variant
        // from the Developer ID one (6.2.6 + leaf 6.1.13), which Phase 6 needs.
        #expect(requirement.contains("1.2.840.113635.100.6.2.1"))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"\(teamID)\""))
    }

    @Test("A well-formed requirement actually compiles in the Security framework")
    func requirementCompiles() {
        let requirement = CodesignPinning.developmentRequirement(
            identifier: identifier, teamID: teamID
        )
        #expect(CodesignPinning.isValidRequirement(requirement), "must be accepted by SecRequirementCreateWithString")
    }

    @Test("Real-world Team IDs and bundle identifiers are accepted")
    func acceptsLegitimateComponents() {
        for value in [teamID, identifier, "io.github.thijsvos.icecube.helper", "A1B2C3D4E5"] {
            #expect(CodesignPinning.isSafeRequirementComponent(value), "\(value) must be allowed")
        }
    }

    /// A value carrying a quote would close the string literal it is
    /// interpolated into and let the rest be parsed as requirement syntax.
    @Test("Components that could break out of the quoted literal are rejected")
    func rejectsInjectionShapedComponents() {
        let hostile = [
            "", // empty pins nothing meaningful
            "AB\"CDE", // closes the literal
            "X\" or anchor trusted \"", // appends an alternative
            "ABCDE 12345", // whitespace changes tokenisation
            "ABCDE\n12345",
            String(repeating: "A", count: 256), // absurd length
        ]
        for value in hostile {
            #expect(
                !CodesignPinning.isSafeRequirementComponent(value),
                "must reject \(value.debugDescription)"
            )
        }
    }

    /// The end-to-end guarantee: an injection-shaped identifier must yield nil
    /// (pinning unavailable → callers fail closed) rather than a string that
    /// would crash the daemon when handed to XPC.
    @Test("A hostile identifier yields no requirement rather than a malformed one")
    func hostileIdentifierFailsClosed() {
        let requirement = CodesignPinning.requirementForPeer(identifier: "bad\" or anchor trusted \"")
        #expect(requirement == nil, "must refuse rather than emit an unparseable requirement")
    }

    /// Whatever `requirementForPeer` returns on this machine — nil when the test
    /// bundle is unsigned, a string when it is not — it must never be a string
    /// the Security framework would reject.
    @Test("requirementForPeer never returns a requirement that would raise in XPC")
    func neverEmitsUnparseableRequirement() {
        guard let requirement = CodesignPinning.requirementForPeer(identifier: identifier) else {
            return // unsigned build: pinning unavailable, which is the safe answer
        }
        #expect(CodesignPinning.isValidRequirement(requirement))
    }

    /// Documents the asymmetry that bit us: an *empty* OU is syntactically legal
    /// (so it would not crash), but it pins to a team nothing can match. Failing
    /// closed on empty is deliberate, not incidental.
    @Test("An empty team ID is syntactically legal but still refused")
    func emptyTeamIDRefused() {
        let syntacticallyFine = CodesignPinning.developmentRequirement(identifier: identifier, teamID: "")
        #expect(CodesignPinning.isValidRequirement(syntacticallyFine), "Security accepts an empty OU")
        #expect(!CodesignPinning.isSafeRequirementComponent(""), "we refuse it anyway")
    }
}
