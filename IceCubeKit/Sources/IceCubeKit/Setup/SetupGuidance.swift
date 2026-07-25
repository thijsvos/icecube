// SetupGuidance.swift — turns helper-setup states into plain language a non-developer can act on.

import Foundation

/// User-facing wording for the fan-control setup flow.
///
/// The project's diagnostics are developer-facing on purpose — "Codesigning
/// failure loading plist … -67056", "register() blocked", "SMAppService
/// status .requiresApproval". Those belong in the log. What a person who just
/// wants a quieter MacBook needs is a sentence telling them what to click.
///
/// Kept here, pure and testable, rather than inline in SwiftUI so the wording
/// is reviewable in one place and cannot drift per view.
public enum SetupGuidance {
    /// One step of the setup flow.
    public enum Step: Sendable, Equatable {
        /// Nothing to do — fan control is working.
        case ready
        /// The app must be in /Applications first.
        case moveToApplications
        /// Ready to ask macOS for permission.
        case needsPermission
        /// Asked; waiting for the user to flip the switch in System Settings.
        case awaitingApproval
        /// Permission granted, connecting to the background service.
        case connecting
        /// The app was updated and the part that controls fans is still the old
        /// version. One click fixes it — but it must be *offered*, because the
        /// user has no way to know it happened.
        case needsUpdate
        /// Something is wrong that the user must resolve.
        case blocked(reason: String)
    }

    /// A short title, suitable for a heading.
    public static func title(for step: Step) -> String {
        switch step {
        case .ready: "Fan control is on"
        case .moveToApplications: "Move Ice Cube to your Applications folder"
        case .needsPermission: "Turn on fan control"
        case .awaitingApproval: "Waiting for your approval"
        case .connecting: "Starting up…"
        case .needsUpdate: "Finish updating Ice Cube"
        case .blocked: "Fan control can’t start"
        }
    }

    /// One or two sentences explaining what is happening and what to do. No
    /// jargon: not "daemon", "helper", "register", "XPC", or "launchd".
    public static func detail(for step: Step) -> String {
        switch step {
        case .ready:
            "Ice Cube can control your fans. You can set a curve, pick a preset, "
                + "or take manual control at any time."
        case .moveToApplications:
            "macOS only allows background services for apps kept in the "
                + "Applications folder. Ice Cube can move itself there — it takes a second."
        case .needsPermission:
            "Ice Cube needs your permission to adjust fan speeds. Reading "
                + "temperatures already works; this is only for changing them."
        case .awaitingApproval:
            "System Settings is open. Switch on “Ice Cube” under Allow in the "
                + "Background, then come back here — this window updates by itself."
        case .connecting:
            "Ice Cube is connecting to the background service. This usually takes "
                + "a moment."
        case .needsUpdate:
            "Ice Cube was updated, but the part that adjusts your fans is still "
                + "the old version. One click brings it up to date."
        case let .blocked(reason):
            reason
        }
    }

    /// The label for the button that advances this step, or `nil` when there is
    /// nothing for the user to press.
    public static func actionTitle(for step: Step) -> String? {
        switch step {
        case .ready: nil
        case .moveToApplications: "Move to Applications"
        case .needsPermission: "Turn On Fan Control"
        case .awaitingApproval: "Open System Settings Again"
        case .connecting: nil
        case .needsUpdate: "Update Now"
        case .blocked: "Try Again"
        }
    }

    /// Extra directions for someone who has been on the approval step long
    /// enough that they are plainly not finding the switch.
    ///
    /// The short message deliberately does not spell out the whole path —
    /// most people follow the opened pane fine, and a wall of directions is
    /// its own obstacle. This appears only once waiting stops looking like
    /// "reading" and starts looking like "stuck", so the flow never becomes a
    /// spinner with no way forward.
    public static let approvalDirections = """
    In System Settings, go to General → Login Items & Extensions. \
    Scroll to “Allow in the Background” and switch on Ice Cube. \
    If it isn’t listed, quit Ice Cube and open it again.
    """

    /// How long to wait on the approval step before offering the directions
    /// above.
    public static let approvalHelpDelay: TimeInterval = 15

    /// Rewrites a developer-facing failure into something a user can act on.
    ///
    /// The technical text still goes to the log; this is what a person sees.
    /// Anything unrecognized is passed through rather than replaced with a
    /// vague catch-all — a specific message we failed to anticipate is more
    /// useful than "something went wrong".
    public static func humanize(_ technical: String) -> String {
        let lowered = technical.lowercased()
        if lowered.contains("isn’t code-signed") || lowered.contains("isn't code-signed")
            || lowered.contains("codesigning failure") || lowered.contains("-67056")
        {
            return "This copy of Ice Cube isn’t signed, so macOS won’t let it control fans. "
                + "Download the official release, or build it yourself — see the project README."
        }
        if lowered.contains("/applications") || lowered.contains("has to run from") {
            return "Ice Cube needs to live in your Applications folder before it can "
                + "control fans. Move it there and open it again."
        }
        if lowered.contains("operation not permitted") || lowered.contains("not authorized") {
            return "macOS declined the request. Open System Settings → General → "
                + "Login Items & Extensions and allow “Ice Cube” under Allow in the Background."
        }
        return technical
    }
}
