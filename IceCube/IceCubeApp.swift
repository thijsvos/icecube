// IceCubeApp.swift — the @main entry point: a menu-bar-only app showing a fan glyph + hottest temperature.

import IceCubeKit
import os
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
    @Environment(\.openWindow) private var openWindow

    /// Whether the user has actually CLOSED the guided setup — not merely that
    /// it was displayed once.
    ///
    /// It used to mean "shown", set the moment the window opened, which the
    /// relocation flow then broke: moving to /Applications relaunches the app,
    /// so the pre-move instance spent the one-shot flag and the relaunched one
    /// — the instance the user actually interacts with — decided setup had
    /// already been handled and showed nothing. The user was left in a menu-bar
    /// app with no visible way forward, immediately after being told setup
    /// would continue. Recording *dismissal* instead survives any number of
    /// relaunches and still never nags someone who said no.
    @AppStorage("hasDismissedSetup") private var hasDismissedSetup = false

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
                // Two reasons to surface setup automatically, both cases the
                // user cannot discover on their own in a menu-bar-only app:
                //
                //   1. First launch, fan control not set up yet.
                //   2. The app was updated while its background service kept
                //      running the old version — invisible, and the only fix is
                //      a button they would never think to look for.
                //
                // Wait for the connection handshake first: immediately after
                // launch the state is "disconnected but fine", which would
                // either nag an existing user or miss the mismatch entirely.
                for _ in 0 ..< 12 where appState.helper.connection == .disconnected {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                let needsUpdate = if case .versionMismatch = appState.helper.connection {
                    true
                } else {
                    false
                }
                let notSetUp = appState.helper.registration != .enabled
                let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "ui")
                guard needsUpdate || (notSetUp && !hasDismissedSetup) else {
                    // Say the ACTUAL reason. The old message asserted
                    // "registration ok, versions match" for every non-open,
                    // including the case where registration was plainly not ok
                    // — which sent me looking in the wrong place.
                    log.notice(
                        "setup: not shown (notSetUp: \(notSetUp, privacy: .public), dismissed: \(hasDismissedSetup, privacy: .public))"
                    )
                    return
                }
                log.notice(
                    "setup: opening (needsUpdate: \(needsUpdate, privacy: .public), notSetUp: \(notSetUp, privacy: .public))"
                )
                WindowOpener.open(WindowOpener.ID.setup, using: openWindow)
            }
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

        // The guided fan-control setup. A window rather than a popover sheet
        // because the user has to leave for System Settings and come back —
        // a popover would dismiss itself the moment they clicked away, which
        // is exactly where the old flow lost people.
        Window("Set Up Ice Cube", id: WindowOpener.ID.setup) {
            SetupWindowView(state: appState)
        }
        .windowResizability(.contentSize)
    }
}
