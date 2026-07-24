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
    /// own* team — or `nil` when we're unsigned (pinning impossible).
    public static func requirementForPeer(identifier: String) -> String? {
        currentTeamID().map { developmentRequirement(identifier: identifier, teamID: $0) }
    }
}
