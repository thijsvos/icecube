// ControlStatus.swift — the one sentence telling a user who is driving their fans right now.

import Foundation

/// What the popover says is happening to the fans, derived from the daemon's
/// own ``HelperStatus``.
///
/// **Why this is worth a type and a test suite.** This is the sentence someone
/// reads to decide whether their Mac is being cooled, and this project has
/// already deleted an entire preset because its label said the opposite of what
/// it did — the "Auto"/"macOS" preset was renamed, fenced behind a divider, and
/// finally removed, because "once the guardian started holding the fan floor
/// above 45 °C, its label became outright false". A status line that lies is a
/// known, historically-real bug class here, not a hypothetical one.
///
/// One enum rather than four booleans, each re-deriving the same precedence by
/// hand. ``HelperStatus`` is versioned and grows — v3 added `guardianActive`
/// itself — so a fifth state becomes a compile error in exactly the places that
/// must handle it, instead of a silently unhandled combination.
///
/// Carries a **case**, not a `Color`: the colour is SwiftUI's business and the
/// precedence is ours. That keeps this testable and keeps the daemon's module
/// free of AppKit.
public enum ControlStatus: Sendable, Equatable, CaseIterable {
    /// The user is holding the fans at a fixed RPM.
    case manual
    /// A temperature curve is driving them.
    case curve
    /// Nominally macOS's job, but the daemon's guardian stepped in because the
    /// Mac got hot and macOS was not cooling it.
    case guardianCooling
    /// Nobody of ours is driving.
    case automatic

    /// The daemon's report → what to say about it.
    ///
    /// `nil` status means no live connection, which reads as "off" rather than
    /// as a guess: claiming control the app cannot confirm is the failure this
    /// whole type guards against.
    public static func of(_ status: HelperStatus?) -> ControlStatus {
        guard let status else { return .automatic }
        switch status.mode {
        case .manual: return .manual
        case .curve: return .curve
        case .auto: return status.guardianActive ? .guardianCooling : .automatic
        }
    }

    public var text: String {
        switch self {
        case .manual: "MANUAL fan control"
        case .curve: "Curve active"
        // Says WHO is driving. "Automatic" left people believing Ice Cube was
        // managing cooling when it had handed the fans to macOS.
        case .guardianCooling: "macOS · Ice Cube stepped in"
        // No longer something anyone can pick — since the macOS preset was
        // removed this only appears in passing (before the first config lands
        // at launch) or after a safety revert. "Not controlling" rather than
        // "macOS is controlling" because, per the field finding, macOS
        // frequently does not pick the fans back up.
        case .automatic: "Fan control is off"
        }
    }

    /// SF Symbol name. A string, so this file needs no SwiftUI import.
    public var icon: String {
        switch self {
        case .manual: "hand.raised.fill"
        case .curve: "chart.xyaxis.line"
        case .guardianCooling: "wind"
        case .automatic: "gearshape"
        }
    }

    /// How prominent the row should be. The view maps this to a colour.
    public enum Emphasis: Sendable, Equatable {
        /// Something the user should notice: manual mode is watchdogged and
        /// unlike a curve it does not track load.
        case warning
        /// Ice Cube is driving, and that is the expected state.
        case active
        /// Nothing of ours is happening.
        case quiet
    }

    public var emphasis: Emphasis {
        switch self {
        case .manual: .warning
        case .curve, .guardianCooling: .active
        case .automatic: .quiet
        }
    }

    /// Whether a curve is what is running — the daemon's word, not the app's
    /// memory of what it sent.
    public var isCurve: Bool {
        self == .curve
    }
}
