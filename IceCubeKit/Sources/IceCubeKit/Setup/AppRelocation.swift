// AppRelocation.swift — decides whether to offer moving the app into /Applications before setup.

import Foundation

/// Whether Ice Cube should offer to move itself into `/Applications`.
///
/// This exists because of the single most likely first-run failure for a real
/// user: they download the release, double-click it in `~/Downloads`, and hit
/// "Ice Cube has to run from /Applications to register its helper". That
/// message is correct and completely useless — it names a constraint and leaves
/// the user to satisfy it. Offering the move turns a dead end into one button.
///
/// Pure and injected (no `Bundle`, no `FileManager`) so every rule is testable,
/// matching ``RegistrationPreflight``.
public enum AppRelocation {
    /// What the app should do about its own location.
    public enum Verdict: Sendable, Equatable {
        /// Already installed correctly; say nothing.
        case fine
        /// Offer to move it to `destination`.
        case offerMove(destination: String)
        /// A developer build running from Xcode's DerivedData. Never nag: the
        /// project's own install script is the supported path, and silently
        /// relocating a build product would be worse than the problem.
        case developerBuild
    }

    /// The canonical install location.
    public static let applicationsPath = "/Applications"

    /// Decides whether this bundle should be moved to /Applications, and how.
    ///
    /// - Parameters:
    ///   - bundlePath: the running app bundle's path.
    ///   - isTranslocated: whether macOS is running the app from a randomized
    ///     read-only path (Gatekeeper app translocation, which happens to a
    ///     quarantined app launched straight from a download). It deliberately
    ///     does **not** change the verdict — a translocated app still gets
    ///     `.offerMove`, because the one outcome that must never happen is a
    ///     silent dead end. It is a parameter so the *caller* can honour it: a
    ///     translocated bundle cannot copy itself, so `SetupModel` reveals it in
    ///     Finder for the user to drag instead. Pinned by
    ///     `SetupFlowTests.translocatedPrompts`.
    public static func verdict(bundlePath: String, isTranslocated: Bool = false) -> Verdict {
        let normalized = bundlePath.hasSuffix("/") ? String(bundlePath.dropLast()) : bundlePath

        // A build product is not an installation. `install.sh` puts a
        // signed copy in /Applications; moving DerivedData would break the next
        // build and confuse Xcode about what it just produced.
        if isDeveloperBuild(normalized) {
            return .developerBuild
        }
        if RegistrationPreflight.isInApplications(normalized) {
            return .fine
        }
        // Translocated apps live under a randomized /private/var/folders path
        // that vanishes on quit; a self-move is not possible from there.
        if isTranslocated || normalized.hasPrefix("/private/var/folders/") {
            return .offerMove(destination: applicationsPath)
        }
        return .offerMove(destination: applicationsPath)
    }

    /// Whether the path looks like an Xcode build product rather than an
    /// installed app.
    static func isDeveloperBuild(_ path: String) -> Bool {
        path.contains("/DerivedData/")
            || path.contains("/Build/Products/")
            || path.contains("/.build/")
    }

    /// Where a bundle at `bundlePath` would land inside `/Applications`.
    public static func destination(for bundlePath: String) -> String {
        let name = (bundlePath as NSString).lastPathComponent
        return "\(applicationsPath)/\(name)"
    }
}
