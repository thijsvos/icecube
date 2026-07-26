// RegistrationPreflight.swift — decides whether SMAppService registration can succeed, before anything is torn down.

import Foundation

/// Whether the running app is in a state where `SMAppService.register()` can
/// possibly succeed — checked **before** a re-register unregisters anything.
///
/// Re-registering is unregister-then-register. If the register half fails, the
/// user is left with no helper at all: worse off than before they clicked, and
/// with fan control gone until they work out why. The failure that motivated
/// this is silent about its real cause — macOS loads the helper's launchd plist
/// by code signature, so an ad-hoc/unsigned build fails with
/// "Codesigning failure loading plist … code: -67056", which the app previously
/// reported as a generic "make sure Ice Cube runs from /Applications".
///
/// Pure and injected (no `Bundle`, no Security framework) so every rule is
/// unit-testable, matching ``SafetyMonitor`` and ``FanGuardian``.
public enum RegistrationPreflight {
    /// Why registration cannot succeed, or `nil` when it should be attempted.
    ///
    /// - Parameters:
    ///   - teamID: the running process's code-signing Team ID, or `nil` when
    ///     the build is unsigned/ad-hoc (see ``CodesignPinning/currentTeamID()``).
    ///   - bundlePath: the app bundle's filesystem path.
    public static func blocker(teamID: String?, bundlePath: String) -> String? {
        // An unsigned build is the unrecoverable one: SMAppService refuses the
        // plist outright, and no amount of retrying helps.
        guard teamID?.isEmpty == false else {
            return "This build isn’t code-signed, so macOS won’t load the helper. "
                + "Build and install a signed copy with scripts/install.sh "
                + "(XCODE_GUIDE §4), then try again."
        }
        // XCODE_GUIDE §4: "Registering daemons from Xcode's DerivedData path is
        // flaky." /Applications is the supported location.
        guard isInApplications(bundlePath) else {
            return "Ice Cube has to run from /Applications to register its helper — "
                + "it’s running from \(bundlePath). Install it with "
                + "scripts/install.sh (XCODE_GUIDE §4), then try again."
        }
        return nil
    }

    /// Whether `path` sits inside `/Applications` (at any depth — users file
    /// apps into subfolders) or a user-local `~/Applications`.
    static func isInApplications(_ path: String) -> Bool {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        if normalized.hasPrefix("/Applications/") {
            return true
        }
        // ~/Applications, without needing FileManager: match the shape.
        if let range = normalized.range(of: "/Applications/"),
           normalized[normalized.startIndex ..< range.lowerBound].hasPrefix("/Users/")
        {
            return true
        }
        return false
    }
}
