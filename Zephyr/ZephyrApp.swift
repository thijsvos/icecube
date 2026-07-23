// ZephyrApp.swift — the @main entry point: a menu-bar-only app showing a fan glyph + hottest temperature.

import SwiftUI
import ZephyrKit

/// Zephyr lives entirely in the menu bar (`LSUIElement` — no Dock icon).
///
/// The scene is a single `MenuBarExtra` in `.window` style: the label is a fan
/// glyph plus the hottest sensor temperature, and clicking it opens
/// ``PopoverView``. All state lives in one ``AppState``, wired to a real or
/// simulated SMC provider by ``CompositionRoot``.
@main
struct ZephyrApp: App {
    /// The single source of truth the label and popover both observe.
    @State private var appState: AppState

    init() {
        // CompositionRoot decides simulated vs real; the app never chooses.
        let (provider, isSimulated) = CompositionRoot.make()
        let state = AppState(provider: provider, isSimulated: isSimulated)
        state.start() // begin 1 Hz polling immediately so the label is live
        _appState = State(initialValue: state)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: appState)
        } label: {
            // Template rendering is mandatory-and-correct on the macOS 26
            // transparent menu bar: the system re-tints the glyph for us.
            HStack(spacing: 3) {
                Image(systemName: "fanblades")
                    .renderingMode(.template)
                Text(appState.hottestText)
                    .monospacedDigit()
            }
            .accessibilityLabel("Zephyr, hottest sensor \(appState.hottestText)")
        }
        .menuBarExtraStyle(.window)
    }
}
