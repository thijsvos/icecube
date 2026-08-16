// FanControlStatus.swift — registration × connection, classified once, so two surfaces cannot disagree.

import Foundation

/// The plain-language answer to "is fan control working?", derived from the two
/// pieces of state that decide it.
///
/// **Why a type.** `HelperManager.Registration` has four cases and
/// `.Connection` three, so there are **twelve** pairs, and two separate surfaces
/// were each switching over them by hand: the Settings one-liner
/// (`SettingsWindow.setupStatusText`) and the popover's card
/// (`FanControlSection.content` → `enabledContent`). Two hand-written truth
/// tables over the same twelve pairs is how the popover and Settings come to
/// disagree about whether the user's fans are being controlled — the same
/// duplication that already bit `PresetHighlight`, whose doc comment records
/// that "the copies had already drifted".
///
/// **Only half of that migration happened.** Settings reads this type; the
/// popover still switches over `helper.connection` by hand in
/// `FanControlSection.enabledContent`, and takes its status line from the Kit's
/// `ControlStatus`. So the twelve pairs are written down once *here* and pinned
/// by `FanControlStatusTests`, but the second surface has not been moved onto
/// them yet, and until it is the two can still drift. Said differently: this
/// type is currently the fix's first half, not the finished job.
///
/// Lives **app-side**, not in IceCubeKit, and the rule is worth stating because
/// it is not obvious: extracted app logic goes to the Kit only when every one of
/// its inputs is already a Kit type. `Registration` and `Connection` describe
/// SMAppService approval and the XPC handshake *as a client sees them* — moving
/// them into the Kit so a label could be tested would make the root daemon's
/// module know about launchd approval, which it is on the other end of. So this
/// file is listed individually in `project.yml`'s `IceCubeTests` sources.
enum FanControlStatus {
    /// What is actually going on, independent of how any surface says it.
    enum Summary: Equatable, CaseIterable {
        /// Nothing installed, or state not yet known.
        case off
        /// Installed, waiting for the user in System Settings.
        case awaitingApproval
        /// Approved, but the XPC channel is not up yet.
        case starting
        /// Running, but speaking a different protocol version — fan control is
        /// paused until the service is re-registered.
        case updateNeeded
        /// Working.
        case on
    }

    /// The twelve pairs, collapsed to five outcomes.
    ///
    /// Registration is checked first and decisively: a connection state is
    /// meaningless while the service is not approved, and reading it anyway is
    /// how "connecting…" ends up on screen for a service that was never
    /// installed.
    static func summary(
        registration: HelperManager.Registration,
        connection: HelperManager.Connection
    ) -> Summary {
        switch registration {
        case .unknown, .notRegistered:
            .off
        case .requiresApproval:
            .awaitingApproval
        case .enabled:
            switch connection {
            case .connected: .on
            case .versionMismatch: .updateNeeded
            case .disconnected: .starting
            }
        }
    }
}

extension FanControlStatus.Summary {
    /// The Settings window's one-line status.
    ///
    /// Deliberately not the popover's wording: Settings answers "is it on?" in
    /// as few words as fit a `LabeledContent`, while the popover has room to say
    /// what to do about it — and it does that from its own switch over
    /// `helper.connection`, so this is the only surface currently reading
    /// ``FanControlStatus/Summary``. Shared *classification* is still the point
    /// of the type and the reason its tests walk all twelve pairs; see the
    /// type's own doc for why that sharing is only half-done.
    var settingsText: String {
        switch self {
        case .on: "On"
        case .updateNeeded: "Update needed"
        case .starting: "Starting up…"
        case .awaitingApproval: "Waiting for your approval"
        case .off: "Off"
        }
    }

    /// Whether the user has something to do about it.
    var needsUserAction: Bool {
        switch self {
        case .off, .awaitingApproval, .updateNeeded: true
        case .starting, .on: false
        }
    }
}
