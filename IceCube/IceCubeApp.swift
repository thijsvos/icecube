// IceCubeApp.swift — the @main entry point: a menu-bar-only app showing a fan glyph + hottest temperature.

import AppKit
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

    init() {
        // CompositionRoot decides simulated vs real; the app never chooses.
        // It now returns the WHOLE graph, not just a provider — deciding only
        // the provider here is what let a simulated launch reach the real
        // daemon.
        let state = AppState(
            graph: CompositionRoot.make(),
            // The only place the real menu-bar host is named. Keeping it here
            // rather than inside AppState is what lets AppState be tested.
            menuBarHost: { StatusItemController(state: $0) }
        )
        state.start() // begin 1 Hz polling immediately so the label is live
        _appState = State(initialValue: state)
    }

    /// False withdraws SwiftUI's status item so ``StatusItemController`` can take
    /// its place. `MenuBarExtra(isInserted:)` has existed since macOS 13, one
    /// version below this app's deployment target.
    private var swiftUIItemInserted: Binding<Bool> {
        Binding(
            get: { appState.menuBar?.isSwiftUIItemInserted ?? true },
            // The system writes back when the user ⌘-drags the item out of the
            // menu bar. Ignored: which item is hosted is Ice Cube's decision,
            // and honouring a drag-out here would silently disable the app.
            set: { _ in }
        )
    }

    var body: some Scene {
        MenuBarExtra(isInserted: swiftUIItemInserted) {
            PopoverView(state: appState)
        } label: {
            // A custom melting-ice-cube glyph (see MenuBarGlyph) — a stable
            // brand mark, not the snowflake which read as a live "it's cold"
            // status.
            //
            // NOT a template image, despite what this comment claimed until
            // 2026-07-27: it is a colour PNG and `isTemplate` is never set
            // anywhere. That is deliberate — MenuBarGlyph explains that a
            // monochrome silhouette just reads as a box — so nothing tints it
            // for light/dark, and nothing should start.
            HStack(spacing: 3) {
                Image(nsImage: MenuBarGlyph.iceCube)
                // The Text is ALWAYS present (empty when icon-only) — the
                // label's view structure never changes. Structurally removing
                // views from a MenuBarExtra label is a known way to glitch
                // the status item on macOS.
                //
                // No font modifier and no layout tricks, on purpose. MenuBarExtra
                // does not host this label as a view: it copies the image and
                // the text into the native status-bar button (measured
                // 2026-09-02 — the button's view tree was empty and its font was
                // the plain system font with `.monospacedDigit()` applied here;
                // hidden placeholder Texts were discarded too). What keeps the
                // item from resizing is the tabular-digit font `StatusItemShim`
                // sets on that button plus the fixed shape `MenuBarLabel` gives
                // every reading — the popover's "no reflow on a data change"
                // rule, applied to the most visible number in the app.
                Text(appState.menuBarText ?? "")
            }
            .accessibilityLabel("Ice Cube, hottest sensor \(appState.hottestText)")
            .task {
                // Exactly once per launch. This task restarts whenever AppKit
                // rebuilds the menu-bar label, which happens on any scene
                // change — so without this the window ambushed the user long
                // after launch, e.g. on closing the Sensors window.
                guard !appState.hasEvaluatedSetupPrompt else { return }
                appState.hasEvaluatedSetupPrompt = true

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
                // Classified once, in `FanControlStatus`, rather than
                // re-derived here from `registration` and `connection` by hand.
                // Two hand-written readings of the same twelve pairs is the
                // duplication that type exists to remove — and this was the
                // second one, which is why `needsUserAction` had no production
                // caller despite being exactly this question.
                let summary = FanControlStatus.summary(
                    registration: appState.helper.registration,
                    connection: appState.helper.connection
                )
                let needsUpdate = summary == .updateNeeded
                let notSetUp = summary.needsUserAction && !needsUpdate
                let log = Logger(subsystem: HelperConstants.logSubsystem, category: "ui")
                guard needsUpdate || (notSetUp && !appState.hasDismissedSetup) else {
                    // Say the ACTUAL reason. The old message asserted
                    // "registration ok, versions match" for every non-open,
                    // including the case where registration was plainly not ok
                    // — which sent me looking in the wrong place.
                    log.notice(
                        "setup: not shown (notSetUp: \(notSetUp, privacy: .public), dismissed: \(appState.hasDismissedSetup, privacy: .public))"
                    )
                    return
                }
                log.notice(
                    "setup: opening (needsUpdate: \(needsUpdate, privacy: .public), notSetUp: \(notSetUp, privacy: .public))"
                )
                WindowOpener.open(WindowOpener.ID.setup, using: openWindow)
            }
            .task {
                // Configure the status item's button — right-click opens the
                // popover too, and the digits get equal widths (see
                // StatusItemShim). Polled rather than guessed: 500 ms was a bet on
                // when NSStatusBarWindow materializes during a cold launch that
                // also builds the provider, the helper manager and the first XPC
                // connection. `try?` on a sleep also swallows CancellationError,
                // so the old code ran the shim even after the task was cancelled.
                for _ in 0 ..< 20 {
                    if StatusItemShim.configureButton() {
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
        //
        // The height fits the list this Mac actually has, because the window
        // will not fit it for us — see SensorsWindowMetrics for why this is
        // arithmetic and not layout. Deliberately no `.windowResizability`
        // here: `.automatic` is what keeps the window freely resizable, which
        // the raw-key table needs, and a stray resizability modifier is what
        // once let the settings window grow to fill the screen.
        Window("SMC Sensors", id: WindowOpener.ID.sensors) {
            SensorsBrowserView(state: appState)
        }
        .defaultSize(
            width: 560,
            height: SensorsWindowMetrics.frameHeight(
                rowCount: appState.sensorRowCount,
                // No main screen (headless, or mid display change) means no
                // screen-relative limit — fall back to the absolute cap rather
                // than to the floor.
                availableHeight: NSScreen.main?.visibleFrame.height ?? .infinity,
                // The decisions section only exists when the daemon has said
                // something, so it only costs height then.
                hasDecisions: !appState.helper.decisions.isEmpty
            )
        )

        // The fan-curve editor (Phase 4).
        Window("Fan Curves", id: WindowOpener.ID.curves) {
            CurveEditorView(state: appState)
        }
        .defaultSize(width: 620, height: 460)

        // "Why is it hot?" — the live diagnosis. Its own window rather than a
        // Sensors section: that window is sized to a computed ceiling two
        // earlier additions broke, and this answers a different question.
        // Sampling starts on appear and stops on disappear (`DiagnosisView`),
        // so a closed window costs nothing and holds no process names.
        Window("Why is it hot?", id: WindowOpener.ID.diagnosis) {
            DiagnosisView(state: appState)
        }
        .defaultSize(width: 460, height: 560)

        // Cooling history — months of °C/W per fan-speed band, and the
        // degradation verdict. Its own window for the Diagnosis window's
        // reason: the Sensors window is sized to a computed ceiling that two
        // earlier additions broke, and a weeks-wide chart is 150+ pt of
        // chrome that would break it a third time.
        Window("Cooling History", id: WindowOpener.ID.coolingHistory) {
            CoolingHistoryWindow(state: appState)
        }
        .defaultSize(width: 560, height: 420)

        // The experimental cooling schematic. The scene is always declared —
        // a SwiftUI `Window` cannot be added and removed at runtime — but
        // nothing ever opens it while `isInsideEnabled` is off, because every
        // route to it is gated on that flag. Declaring it unconditionally costs
        // one unopened scene; making it conditional would mean a live `if` in
        // the scene builder, which is not what that builder is for.
        Window("Inside", id: WindowOpener.ID.inside) {
            InsideView(state: appState)
        }
        .defaultSize(width: 620, height: 500)

        // Full settings. Fixed *width* at 480 and non-resizable, with the height
        // coming from whichever tab is showing — `SettingsWindowView` is
        // `.frame(width: 480)` plus `.fixedSize(vertical:)`, so the window grows
        // and shrinks as you move between General, Menu and Fan Control. Exactly
        // one `.windowResizability(.contentSize)`, which is what makes that
        // work. (A stray second `.contentMinSize` here previously let the window
        // grow to its saved frame and fill the screen.)
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
