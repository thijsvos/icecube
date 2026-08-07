// PopoverFooter.swift — the popover's footer, which holds the app's only Quit affordance.

import AppKit
import IceCubeKit
import SwiftUI

/// The footer.
///
/// It matters more than it looks: Ice Cube is `LSUIElement`, so this Quit
/// button is the only way out of the app. `dismissPopover` is injected rather
/// than reconstructed — closing the popover before opening a window is
/// load-bearing ordering that lives in `PopoverView`.
struct PopoverFooter: View {
    let state: AppState
    let dismissPopover: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        footer
    }

    private var footer: some View {
        HStack {
            Button("Sensors…") {
                WindowOpener.openFromPopover(
                    WindowOpener.ID.sensors, using: openWindow, dismissing: dismissPopover
                )
            }
            .help("Browse every SMC key and export a diagnostics report")
            // Deliberately worded as the question rather than as a noun
            // ("Diagnostics", "Analysis"): it is the sentence people actually
            // arrive with, and the window's whole job is to answer it.
            Button("Why is it hot?") {
                WindowOpener.openFromPopover(
                    WindowOpener.ID.diagnosis, using: openWindow, dismissing: dismissPopover
                )
            }
            .help("What is drawing power, and whether cooling has anything left to give")
            Button("Settings…") {
                WindowOpener.openFromPopover(
                    WindowOpener.ID.settings, using: openWindow, dismissing: dismissPopover
                )
            }
            .help("All Ice Cube settings")
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}
