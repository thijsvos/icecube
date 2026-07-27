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

    /// The Developer ID form. Ice Cube has never been signed with one — this
    /// pins the string's shape and, below, that the Security framework accepts
    /// it. Neither is proof that a real notarized build satisfies it; only a
    /// Developer ID build can establish that.
    @Test("The distribution requirement pins the Developer ID CA, the leaf marker and team OU")
    func distributionRequirementShape() {
        let requirement = CodesignPinning.distributionRequirement(
            identifier: identifier, teamID: teamID
        )
        #expect(requirement.contains("identifier \"\(identifier)\""))
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("1.2.840.113635.100.6.2.6"), "Developer ID CA marker")
        #expect(requirement.contains("1.2.840.113635.100.6.1.13"), "Developer ID Application leaf marker")
        #expect(requirement.contains("certificate leaf[subject.OU] = \"\(teamID)\""))
    }

    /// The two chains are mutually exclusive. A build checked against the wrong
    /// one fails pinning, and it presents as the app and helper never agreeing —
    /// "connecting…" forever, with nothing saying why.
    @Test("The two requirements do not overlap")
    func variantsAreDistinct() {
        let development = CodesignPinning.developmentRequirement(
            identifier: identifier, teamID: teamID
        )
        let distribution = CodesignPinning.distributionRequirement(
            identifier: identifier, teamID: teamID
        )
        #expect(development != distribution)
        #expect(!development.contains("6.2.6"), "development must not claim the Developer ID CA")
        #expect(!distribution.contains("6.2.1"), "distribution must not claim the WWDR intermediate")
    }

    @Test(
        "Each variant selects its own requirement",
        arguments: [
            CodesignPinning.SigningVariant.development,
            CodesignPinning.SigningVariant.developerID,
        ]
    )
    func variantSelectsItsRequirement(variant: CodesignPinning.SigningVariant) {
        let chosen = CodesignPinning.requirement(
            identifier: identifier, teamID: teamID, variant: variant
        )
        let expected = variant == .development
            ? CodesignPinning.developmentRequirement(identifier: identifier, teamID: teamID)
            : CodesignPinning.distributionRequirement(identifier: identifier, teamID: teamID)
        #expect(chosen == expected)
        #expect(CodesignPinning.isValidRequirement(chosen), "must compile in the Security framework")
    }

    /// An unsigned test bundle has no certificate chain. Landing on
    /// `.development` there is what keeps this change inert until a Developer ID
    /// actually exists — the variant never decides anything on its own, because
    /// a missing Team ID already makes callers fail closed.
    @Test("An unsigned process reports the development variant")
    func unsignedFallsBackToDevelopment() {
        #expect(CodesignPinning.currentVariant() == .development)
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
