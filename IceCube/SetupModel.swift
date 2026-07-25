// SetupModel.swift — drives the guided fan-control setup: what step we're on, and what the button does.

import AppKit
import IceCubeKit
import Observation
import os
import ServiceManagement
import SwiftUI

/// The state machine behind the setup window.
///
/// It exists to keep the *decisions* out of the view. `HelperManager` already
/// knows the technical registration state; this turns that plus the app's own
/// location into the one thing the user is being asked to do right now, so the
/// view is a rendering of a step rather than a pile of nested conditionals.
@Observable
@MainActor
final class SetupModel {
    private let helper: HelperManager
    private let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "ui")

    /// Set once the user presses the enable button, so the flow can distinguish
    /// "hasn't asked yet" from "asked, waiting on System Settings" — the same
    /// `.requiresApproval` status means different things either side of that.
    private(set) var hasRequestedPermission = false
    /// A relocation attempt that failed; the user must drag it themselves.
    private(set) var relocationFailure: String?
    /// When the approval step started, so a stall can be distinguished from
    /// someone simply reading.
    private var awaitingSince: Date?
    /// True once a move to /Applications has been handed off to the relaunch.
    ///
    /// The window vanishing because we are relaunching is NOT the user
    /// dismissing it — treating it as such would make the relocated copy
    /// suppress the setup it is supposed to continue.
    private(set) var isRelocating = false

    /// True once the user has been on the approval step long enough that they
    /// are evidently not finding the switch.
    var needsApprovalDirections: Bool {
        guard step == .awaitingApproval, let awaitingSince else { return false }
        return Date().timeIntervalSince(awaitingSince) > SetupGuidance.approvalHelpDelay
    }

    init(helper: HelperManager) {
        self.helper = helper
    }

    /// Where the app is running from, and whether that is acceptable.
    var relocation: AppRelocation.Verdict {
        AppRelocation.verdict(
            bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
            isTranslocated: Self.isTranslocated
        )
    }

    /// The single step the user is on.
    var step: SetupGuidance.Step {
        if let failure = relocationFailure {
            return .blocked(reason: failure)
        }
        // A location problem outranks everything: nothing else can succeed
        // until it is fixed, and attempting registration first produces the
        // technical error this whole flow exists to avoid showing.
        if case .offerMove = relocation {
            return .moveToApplications
        }
        // Work in progress is never a failure. Registration passes through
        // intermediate states on its way to succeeding, and rendering any of
        // them as an error makes the flow flicker "can't start" at a user who
        // did nothing wrong. The retry loop reports a real failure only once
        // it has genuinely given up.
        if helper.isReregistering {
            return .connecting
        }
        if let error = helper.lastError, !error.isEmpty {
            return .blocked(reason: SetupGuidance.humanize(error))
        }
        switch helper.registration {
        case .enabled:
            switch helper.connection {
            case .connected:
                return .ready
            case .versionMismatch:
                // The app was replaced but launchd still runs the old service.
                // Surfaced as its own step because the user cannot possibly
                // know this happened, and the raw state reads as a failure.
                return .needsUpdate
            case .disconnected:
                return .connecting
            }
        case .requiresApproval:
            return .awaitingApproval
        case .notRegistered, .unknown:
            return hasRequestedPermission ? .awaitingApproval : .needsPermission
        }
    }

    var title: String {
        SetupGuidance.title(for: step)
    }

    var detail: String {
        SetupGuidance.detail(for: step)
    }

    var actionTitle: String? {
        SetupGuidance.actionTitle(for: step)
    }

    /// True once fan control is fully working — the window can offer to close.
    var isComplete: Bool {
        step == .ready
    }

    /// Performs whatever the current step's button says.
    func performAction() {
        switch step {
        case .moveToApplications:
            relocateToApplications()
        case .needsPermission:
            hasRequestedPermission = true
            helper.register()
            // Registering a background service always needs the one-time
            // approval, so send the user straight there rather than making
            // them find it after a second click.
            if helper.registration == .requiresApproval {
                helper.openApprovalSettings()
            }
        case .awaitingApproval:
            helper.openApprovalSettings()
        case .needsUpdate:
            Task { await helper.reregister() }
        case .blocked:
            relocationFailure = nil
            helper.clearError()
            hasRequestedPermission = false
            helper.refreshRegistration()
        case .ready, .connecting:
            break
        }
    }

    /// Nudges the helper state so the window reflects reality promptly while
    /// the user is looking at it, instead of waiting out the 5 s loop.
    func refresh() async {
        helper.refreshRegistration()
        await helper.maintainOnce()
        // Stamped here rather than in `step` — a computed property that
        // recorded state would set the clock on every render.
        if step == .awaitingApproval {
            if awaitingSince == nil {
                awaitingSince = Date()
            }
        } else {
            awaitingSince = nil
        }
    }

    // MARK: - Relocation

    /// Whether macOS is running us from a randomized read-only path (Gatekeeper
    /// app translocation). A translocated app cannot move itself.
    private static var isTranslocated: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path
            .hasPrefix("/private/var/folders/")
    }

    /// Moves the app into /Applications and relaunches from there.
    ///
    /// Deliberately best-effort with a clear fallback: `/Applications` is
    /// writable by admin users, but not by everyone, and a translocated app
    /// cannot move itself at all. When it fails the user gets an instruction
    /// and a Finder window, not an error code.
    private func relocateToApplications() {
        let source = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let destination = URL(fileURLWithPath: AppRelocation.destination(for: source.path))

        if Self.isTranslocated {
            relocationFailure = "Ice Cube is running from a temporary location, so it "
                + "can’t move itself. Drag Ice Cube into your Applications folder, "
                + "then open it from there."
            NSWorkspace.shared.activateFileViewerSelecting([source])
            return
        }
        // SAFETY: never delete anything we cannot replace.
        //
        // Moving to where we already are would remove the source and then fail
        // the move — deleting the user's app. `verdict` should never route us
        // here, but the consequence is severe enough that it must not depend on
        // a caller three layers away staying correct.
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            log.notice("relocation skipped: already at \(destination.path, privacy: .public)")
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                // An existing install is replaced ATOMICALLY rather than
                // removed-then-moved. The old sequence destroyed a working
                // installed copy before the new one was in place, so a move
                // that then failed left the user with nothing in /Applications
                // — strictly worse off than before they clicked the button.
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
            log.notice("relocated to \(destination.path, privacy: .public); relaunching")
            isRelocating = true
            relaunch(from: destination)
        } catch {
            log.error("relocation failed: \(error.localizedDescription, privacy: .public)")
            relocationFailure = "Ice Cube couldn’t move itself — your Mac may not allow it. "
                + "Drag Ice Cube into your Applications folder in the Finder window that "
                + "just opened, then open it from there."
            NSWorkspace.shared.activateFileViewerSelecting([source])
        }
    }

    /// Relaunches the moved copy and exits this one.
    private func relaunch(from url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
