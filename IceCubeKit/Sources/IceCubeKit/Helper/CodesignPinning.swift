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
    /// The Team ID (`subject.OU`) of the **current process's** signature, or
    /// `nil` when unsigned / ad-hoc signed.
    ///
    /// Resolved once: a process cannot change its own signature, and this is a
    /// synchronous Security-framework + on-disk read that `HelperClient.connect()`
    /// performs on the main actor. `maintain()` calls connect() on every 5 s pass
    /// while registered-but-unreachable, so it would otherwise repeat forever in
    /// exactly the degraded state where the UI already reads "connecting…".
    public static func currentTeamID() -> String? {
        ownTeamID
    }

    private static let ownTeamID: String? = resolveTeamID()

    private static func resolveTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The TN3127-style development requirement for a peer signed by `teamID`
    /// with code-signing identifier `identifier`:
    /// Apple-rooted chain, WWDR intermediate (Apple Development certs), and
    /// the team pinned via the leaf's OU.
    ///
    /// NOTE (Phase 6): Developer ID-signed releases need the *distribution*
    /// variant (markers 6.2.6 + leaf 6.1.13) — the two are not compatible.
    public static func developmentRequirement(identifier: String, teamID: String) -> String {
        "identifier \"\(identifier)\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.1] /* WWDR */"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    /// The requirement to impose on a peer with `identifier`, pinned to *our
    /// own* team — or `nil` when we're unsigned, or when the inputs would not
    /// produce a requirement the Security framework accepts.
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
        let requirement = developmentRequirement(identifier: identifier, teamID: teamID)
        return isValidRequirement(requirement) ? requirement : nil
    }

    /// Rejects anything that could break out of the quoted literal it gets
    /// interpolated into (or is simply empty). Real Team IDs are 10 alphanumeric
    /// characters and bundle ids are reverse-DNS, so this excludes nothing
    /// legitimate — it just means a surprising value fails closed instead of
    /// producing a malformed requirement.
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
