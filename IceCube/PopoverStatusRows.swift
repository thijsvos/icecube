// PopoverStatusRows.swift — the small rows the popover shows beside data: waiting, an error, an available update.

import IceCubeKit
import SwiftUI

/// Shown while the first reading is still in flight.
struct PopoverWaitingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Waiting for first reading…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Shown above the cards when something failed.
struct PopoverErrorRow: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(Theme.warning)
            // The same omission as the Control card's error line: a fixed
            // 380 pt popover truncates any real sentence at one line.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Error: \(message)")
    }
}

/// Shown only when a check has actually found something newer.
///
/// The counterpart to owning `UpdateChecker` on `AppState`: a check that runs
/// on launch and reports into a window nobody has open has not told anyone
/// anything. This is the surface a menu-bar user does look at.
///
/// A link, never a download. `UpdateChecker`'s own comment is the rule — "no
/// auto-download, no auto-install, no framework" — and an unsigned build has
/// no business installing itself.
struct PopoverUpdateRow: View {
    let version: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            Label("Version \(version) is available", systemImage: "arrow.down.circle")
                .font(.caption)
        }
        .accessibilityLabel("Version \(version) is available. Opens the release page.")
    }
}
