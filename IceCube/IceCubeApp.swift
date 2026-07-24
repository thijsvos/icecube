// IceCubeApp.swift — the @main entry point: a menu-bar-only app showing a fan glyph + hottest temperature.

import IceCubeKit
import SwiftUI

/// Ice Cube lives entirely in the menu bar (`LSUIElement` — no Dock icon).
///
/// The scene is a single `MenuBarExtra` in `.window` style: the label is a fan
/// glyph plus the hottest sensor temperature, and clicking it opens
/// ``PopoverView``. All state lives in one ``AppState``, wired to a real or
/// simulated SMC provider by ``CompositionRoot``.
@main
struct IceCubeApp: App {
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
            // A custom melting-ice-cube template glyph (see MenuBarGlyph) —
            // a stable brand mark, not the snowflake which read as a live
            // "it's cold" status. The system tints the template for light/dark.
            HStack(spacing: 3) {
                Image(nsImage: MenuBarGlyph.iceCube)
                // The Text is ALWAYS present (empty when icon-only) — the
                // label's view structure never changes. Structurally removing
                // views from a MenuBarExtra label is a known way to glitch
                // the status item on macOS.
                Text(appState.menuBarText ?? "")
                    .monospacedDigit()
            }
            .accessibilityLabel("Ice Cube, hottest sensor \(appState.hottestText)")
            .task {
                // Widen the status item's click mask so right-click opens the
                // popover too. Polled rather than guessed: 500 ms was a bet on
                // when NSStatusBarWindow materializes during a cold launch that
                // also builds the provider, the helper manager and the first XPC
                // connection. `try?` on a sleep also swallows CancellationError,
                // so the old code ran the shim even after the task was cancelled.
                for _ in 0 ..< 20 {
                    if StatusItemShim.enableRightClick() {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled {
                        return
                    }
                }
            }
        }
        .menuBarExtraStyle(.window)

        // The SMC key browser + diagnostics export. Opened from the popover
        // via WindowOpener (LSUIElement apps need the explicit activation).
        // Settings deliberately have NO window: they render inline in the
        // popover (see SettingsSection) so choosing an option can't dismiss it.
        Window("SMC Sensors", id: WindowOpener.ID.sensors) {
            SensorsBrowserView(state: appState)
        }
        .defaultSize(width: 560, height: 480)

        // The fan-curve editor (Phase 4).
        Window("Fan Curves", id: WindowOpener.ID.curves) {
            CurveEditorView(state: appState)
        }
        .defaultSize(width: 620, height: 460)

        // Full settings. Fixed content size (the tabbed view is 480×380) and
        // non-resizable — one `.windowResizability(.contentSize)` only. (A
        // stray second `.contentMinSize` here previously let the window grow
        // to its saved frame and fill the screen.)
        Window("Ice Cube Settings", id: WindowOpener.ID.settings) {
            SettingsWindowView(state: appState)
        }
        .defaultSize(width: 480, height: 440)
        .windowResizability(.contentSize)

        // About panel — identity, version, license.
        Window("About Ice Cube", id: WindowOpener.ID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}
