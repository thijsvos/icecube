// WindowOpenerTests.swift — the order the three steps of opening a window must happen in.

import Foundation
import Testing

/// One shared log, so the *order* of the steps can be asserted rather than only
/// that each of them happened.
@MainActor
private final class Recorder {
    private(set) var calls: [String] = []
    func record(_ call: String) {
        calls.append(call)
    }
}

/// Opening a window from the popover is three operations whose *order* is the
/// entire fix, and every wrong order is silent: no crash, no log line, just a
/// popover sitting on top of the window it opened (it is drawn at window level
/// 101; a `Window` scene is at level 0), or an `LSUIElement` app that failed to
/// come forward at all.
///
/// There is deliberately no test for "a window button must not close the
/// popover". `WindowOpener.open(_:using:)` takes no dismissal, so that property
/// is carried by the signature — the four call sites inside the Settings window
/// cannot express the mistake, which is stronger than asserting they don't.
@Suite("WindowOpener — the order")
@MainActor
struct WindowOpenerTests {
    @Test("From the popover: close it, then open, then activate")
    func popoverDismissesFirstAndActivatesLast() {
        let recorder = Recorder()
        WindowOpener.perform(
            dismiss: { recorder.record("dismiss") },
            open: { recorder.record("open") },
            activate: { recorder.record("activate") }
        )
        #expect(recorder.calls == ["dismiss", "open", "activate"])
    }

    /// Activation still has to come last with nothing to dismiss, because the
    /// `LSUIElement` workaround is what puts the window in front at all.
    @Test("From a window: open, then activate")
    func windowOpensThenActivates() {
        let recorder = Recorder()
        WindowOpener.perform(
            dismiss: nil,
            open: { recorder.record("open") },
            activate: { recorder.record("activate") }
        )
        #expect(recorder.calls == ["open", "activate"])
    }
}

/// The menu bar hands out one window at a time, because in an `LSUIElement` app
/// a window that is off screen is one the user cannot find, count or reach —
/// and so cannot close. Which windows may be retracted is a judgement about
/// work the user would lose, so it is asserted here rather than left to
/// whoever adds the next scene.
///
/// There is deliberately no test for "opening About from Settings must not
/// close Settings". The retraction lives only in `openFromPopover`;
/// `open(_:using:)` has no way to express it — the same signature-over-
/// convention argument the suite above makes about popover dismissal.
@Suite("WindowOpener — the windows the menu bar retracts")
@MainActor
struct MenuBarWindowRetractionTests {
    @Test("Summoning a window closes the one the user clicked away from")
    func retractsTheForgottenWindow() {
        #expect(
            WindowOpener.windowsToClose(
                openWindowIDs: [WindowOpener.ID.settings], summoning: WindowOpener.ID.sensors
            ) == [WindowOpener.ID.settings]
        )
    }

    /// Closing and reopening would rebuild the scene and lose the tab the user
    /// was on. The window is already there; this has to be a raise.
    @Test("Asking again for the window that is already open retracts nothing")
    func summoningTheOpenWindowRetractsNothing() {
        #expect(
            WindowOpener.windowsToClose(
                openWindowIDs: [WindowOpener.ID.settings], summoning: WindowOpener.ID.settings
            ).isEmpty
        )
    }

    /// The curve editor holds points, sliders and a preset name that are
    /// uncommitted until Apply Curve, and the setup flow has to survive the
    /// user leaving for System Settings. Closing either to tidy the screen
    /// would be a worse bug than the one being fixed.
    @Test("Windows holding unsaved work are never retracted")
    func neverRetractsWindowsHoldingWork() {
        for id in [WindowOpener.ID.curves, WindowOpener.ID.setup] {
            #expect(!WindowOpener.closableFromMenuBar.contains(id))
            #expect(
                WindowOpener.windowsToClose(
                    openWindowIDs: [id], summoning: WindowOpener.ID.sensors
                ).isEmpty
            )
        }
    }

    /// `NSApp.windows` is mostly not scenes — the popover, the status item —
    /// and those carry an empty autosave name. An empty id must match nothing,
    /// or the first summon would close the menu bar out from under itself.
    @Test("Windows that are not scenes are never touched")
    func ignoresNonSceneWindows() {
        #expect(
            WindowOpener.windowsToClose(
                openWindowIDs: ["", "", "NSColorPanel"], summoning: WindowOpener.ID.sensors
            ).isEmpty
        )
    }

    @Test("Everything stale goes in one pass")
    func retractsEveryStaleWindowAtOnce() {
        #expect(
            WindowOpener.windowsToClose(
                openWindowIDs: [WindowOpener.ID.settings, WindowOpener.ID.about, WindowOpener.ID.curves, ""],
                summoning: WindowOpener.ID.sensors
            ) == [WindowOpener.ID.settings, WindowOpener.ID.about]
        )
    }
}
