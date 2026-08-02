// PopoverHeader.swift — the popover's header: brand mark, simulated badge, hottest-sensor badge.

import AppKit
import IceCubeKit
import SwiftUI

/// The popover's top row. Owns no state; `AppState` comes in.
struct PopoverHeader: View {
    let state: AppState

    var body: some View {
        header
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The ice-cube brand mark — instant confirmation you opened the
            // right app the moment the popover appears.
            Image(nsImage: MenuBarGlyph.iceCube)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("Ice Cube")
                .font(.headline)
            if state.isSimulated {
                badge("SIMULATED")
                    .foregroundStyle(Theme.warning)
                    .accessibilityLabel("Simulated data")
            }
            Spacer()
            // No temperature here on purpose: the header is identity, not data.
            // The hottest reading lives in the body (and the menu bar) once —
            // showing it here too was the duplicate readout.
        }
    }

    /// A small capsule label using a hierarchical fill (never an opaque color).
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}
