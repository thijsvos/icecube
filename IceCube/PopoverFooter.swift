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

    /// The footer: four buttons, all the same shape.
    ///
    /// **It briefly held five and that was a mistake, twice over.** The popover
    /// is a fixed 380 pt (`Theme.Metrics.popoverWidth`, which the live content
    /// and the collapsed placeholder must agree on or the window visibly
    /// resizes on reopen). Four text buttons plus Quit already fill it, so
    /// adding one for the Inside window truncated the longest label — leaving
    /// `"Why is it..."` on the one button whose whole point is being phrased as
    /// the question people arrive with. Sizing the row to fit with
    /// `ViewThatFits` stopped the truncation and replaced it with something
    /// worse: a lone icon sitting among four text buttons.
    ///
    /// Five do not fit even with every label shortened — the arithmetic comes
    /// to roughly 380 pt before padding — so the answer is four. Inside is the
    /// one that goes, because it is opt-in and experimental and Settings, where
    /// it is switched on, has an **Open Inside…** button directly under the
    /// toggle.
    ///
    /// `fixedSize()` on each label is the guard against this recurring: a label
    /// that cannot shrink cannot silently become an ellipsis, so a sixth button
    /// or a longer localisation shows up as an obvious overflow instead of as a
    /// button that says nothing.
    private var footer: some View {
        HStack {
            Button("Sensors…") {
                WindowOpener.openFromPopover(
                    WindowOpener.ID.sensors, using: openWindow, dismissing: dismissPopover
                )
            }
            .fixedSize()
            .help("Browse every SMC key and export a diagnostics report")
            Button("Settings…") {
                WindowOpener.openFromPopover(
                    WindowOpener.ID.settings, using: openWindow, dismissing: dismissPopover
                )
            }
            .fixedSize()
            .help("All Ice Cube settings")
            // Last of the three, after the two nouns (owner preference,
            // 2026-08-07). Deliberately worded as the question rather than as a
            // noun ("Diagnostics", "Analysis"): it is the sentence people
            // actually arrive with, and the window's whole job is to answer it.
            Button("Why is it hot?") {
                WindowOpener.openFromPopover(
                    WindowOpener.ID.diagnosis, using: openWindow, dismissing: dismissPopover
                )
            }
            .fixedSize()
            .help("What is drawing power, and whether cooling has anything left to give")
            Spacer(minLength: 4)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .fixedSize()
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}
