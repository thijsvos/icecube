// PopoverStatusRows.swift — the two rows the popover shows instead of data: waiting, and an error.

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
