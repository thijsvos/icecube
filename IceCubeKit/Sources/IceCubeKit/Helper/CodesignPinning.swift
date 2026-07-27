// CodesignPinning.swift — derives the XPC code-signing requirement from our own signature (no committed Team ID).

import Foundation
import Security

/// Builds the code-signing requirement each side of the XPC channel imposes
/// on the other (PLAN.md §4.2, TN3127 development variant).
///
/// The Team ID is **derived at runtime from our own signature** rather than
/// baked into source: the app pins the helper to the team the app itself was
/// signed with, and vice versa. No Team ID is ever committed, and forks work
/// without editing pinning code. Unsigned debug builds (CI, `xcodebuild
/// CODE_SIGNING_ALLOWED=NO`) have no team — callers must treat that as
/// "pinning unavailable" and fail closed in release builds.
public enum CodesignPinning {
    /// Which kind of certificate signed us, and therefore which requirement the
    /// peer must satisfy.
    ///
    /// The two are **not interchangeable**: a Developer ID build checked against
    /// the development requirement fails pinning, and the failure presents as
    /// the app and its helper simply never agreeing — "connecting…" forever,
    /// with nothing saying why.
    public enum SigningVariant: String, Sendable, Equatable {
        /// Apple Development (free or paid account, local install). What every
        /// build of Ice Cube has used so far, including Release builds from
        /// `scripts/install.sh`.
        case development
        /// Developer ID Application — notarized public distribution.
        case developerID
    }

    /// The Team ID (`subject.OU`) of the **current process's** signature, or
    /// `nil` when unsigned / ad-hoc signed.
    ///
    /// Resolved once: a process cannot change its own signature, and this is a
    /// synchronous Security-framework + on-disk read that `HelperClient.connect()`
    /// performs on the main actor. `maintain()` calls connect() on every 5 s pass
    /// while registered-but-unreachable, so it would otherwise repeat forever in
    /// exactly the degraded state where the UI already reads "connecting…".
    public static func currentTeamID() -> String? {
        ownSignature?.teamID
    }

    /// How the current process was signed.
    ///
    /// **Detected from our own certificate chain rather than from a build
    /// flag.** `#if DEBUG` would be wrong twice over: Release builds are signed
    /// with Apple Development today (that is what `scripts/install.sh`
    /// produces), so a compile-time switch would break the owner's own install
    /// the day it landed — and a fork signing with its own Developer ID would
    /// have to edit pinning code, which is exactly what deriving the Team ID at
    /// runtime already avoids.
    ///
    /// Defaults to ``SigningVariant/development`` when unsigned or unreadable.
    /// That is the conservative answer: callers treat a *missing* Team ID as
    /// "pinning unavailable" and fail closed in release, so this value never
    /// decides anything on its own.
    public static func currentVariant() -> SigningVariant {
        ownSignature?.variant ?? .development
    }

    private struct Signature {
        let teamID: String?
        let variant: SigningVariant
    }

    private static let ownSignature: Signature? = resolveSignature()

    /// The marker extension Apple puts in a Developer ID Application leaf.
    /// Its presence is the only reliable way to tell the two chains apart —
    /// the certificate's common name is display text, not a guarantee.
    private static let developerIDLeafMarker = "1.2.840.113635.100.6.1.13"

    private static func resolveSignature() -> Signature? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        // Index 0 is the leaf; an ad-hoc signature has no chain at all.
        let chain = dict[kSecCodeInfoCertificates as String] as? [SecCertificate]
        let variant: SigningVariant = chain?.first.map {
            certificate($0, hasExtension: developerIDLeafMarker) ? .developerID : .development
        } ?? .development
        return Signature(teamID: teamID, variant: variant)
    }

    private static func certificate(_ cert: SecCertificate, hasExtension oid: String) -> Bool {
        guard let values = SecCertificateCopyValues(cert, [oid as CFString] as CFArray, nil)
            as? [String: Any]
        else { return false }
        return values[oid] != nil
    }

    /// The TN3127-style development requirement for a peer signed by `teamID`
    /// with code-signing identifier `identifier`:
    /// Apple-rooted chain, WWDR intermediate (Apple Development certs), and
    /// the team pinned via the leaf's OU.
    public static func developmentRequirement(identifier: String, teamID: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.1] /* WWDR */"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// The Developer ID (distribution) requirement — PLAN.md §4.2's RELEASE
    /// form. Same shape as the development one but a different chain: the
    /// Developer ID CA as the intermediate, plus the leaf marker that says this
    /// really is a Developer ID Application certificate and not something else
    /// issued under the same CA.
    ///
    /// **Verified against a real Developer ID signature — just not ours.** Ice
    /// Cube has never been signed with one (that needs the paid account), so on
    /// 2026-07-27 both strings were checked with `codesign --verify -R` against
    /// two third-party binaries actually on disk, one of each kind:
    ///
    /// | | development req | distribution req |
    /// | --- | --- | --- |
    /// | a Developer ID app | no match | **match** |
    /// | Ice Cube (Apple Development) | **match** | no match |
    ///
    /// So the markers are right and the two chains are genuinely exclusive.
    /// What is still unproven is the *combination* — our identifier and our
    /// Team ID under a Developer ID chain — because that artifact does not
    /// exist. The first Developer ID build must re-run the check by hand
    /// against itself, as docs/RELEASING.md says.
    public static func distributionRequirement(identifier: String, teamID: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] /* Developer ID CA */"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] /* Developer ID App */"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// Picks the requirement for a variant. Split out from the runtime
    /// detection so the choice can be tested on a machine that has only ever
    /// held one kind of certificate.
    public static func requirement(
        identifier: String, teamID: String, variant: SigningVariant
    ) -> String {
        switch variant {
        case .development: developmentRequirement(identifier: identifier, teamID: teamID)
        case .developerID: distributionRequirement(identifier: identifier, teamID: teamID)
        }
    }

    /// The requirement to impose on a peer with `identifier`, pinned to *our
    /// own* team and matching *our own* certificate kind — or `nil` when we're
    /// unsigned, or when the inputs would not produce a requirement the
    /// Security framework accepts.
    ///
    /// Both sides of the channel run this same code from the same build, so
    /// they cannot disagree about which variant to expect.
    ///
    /// The nil-on-invalid path matters more than it looks: both
    /// `NSXPCConnection.setCodeSigningRequirement` and the listener equivalent
    /// raise an **Objective-C exception** on a malformed requirement string,
    /// which Swift cannot catch — in the daemon that is a crash, and under
    /// launchd a crash loop. Callers already treat nil as "pinning
    /// unavailable" and fail closed in release, so validating here converts an
    /// unrecoverable crash into the safe refusal that is already handled.
    public static func requirementForPeer(identifier: String) -> String? {
        guard let teamID = currentTeamID(),
              isSafeRequirementComponent(teamID),
              isSafeRequirementComponent(identifier)
        else { return nil }
        let requirement = requirement(
            identifier: identifier, teamID: teamID, variant: currentVariant()
        )
        return isValidRequirement(requirement) ? requirement : nil
    }

    /// Rejects anything that could break out of the quoted literal it gets
    /// interpolated into (or is simply empty).
    ///
    /// Real Team IDs are 10 alphanumeric characters and bundle ids are
    /// reverse-DNS, so this excludes nothing legitimate — it just means a
    /// surprising value fails closed instead of producing a malformed
    /// requirement.
    static func isSafeRequirementComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Whether the Security framework can actually compile this requirement.
    static func isValidRequirement(_ requirement: String) -> Bool {
        var parsed: SecRequirement?
        return SecRequirementCreateWithString(requirement as NSString, [], &parsed) == errSecSuccess
            && parsed != nil
    }
}
