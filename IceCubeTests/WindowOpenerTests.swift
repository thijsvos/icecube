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
