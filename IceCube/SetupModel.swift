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
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            log.notice("relocated to \(destination.path, privacy: .public); relaunching")
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
