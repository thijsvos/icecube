// WindowOpener.swift — the one place that opens windows from the menu bar (LSUIElement focus dance).

import AppKit
import IceCubeKit
import os
import SwiftUI

/// Opens app windows from the popover.
///
/// An `LSUIElement` app is never the active application, so a bare
/// `openWindow` can leave the new window behind other apps without key focus.
/// The fix — verified on macOS 26 — is to activate the app explicitly right
/// after opening. Every window-opening call site goes through here so the
/// workaround lives (and can be adjusted) in exactly one place, instead of
/// being cargo-culted across views. (PLAN.md §1.2; Apple FB11984872.)
enum WindowOpener {
    /// Identifiers for the app's window scenes.
    enum ID {
        /// ".v2" for the same reason as ``settings``: macOS saves a window's
        /// frame under `NSWindow Frame <scene id>` and a saved frame outranks
        /// `.defaultSize` — measured, a relaunch restores the saved height and
        /// ignores a changed default entirely. Without a fresh id, nobody who
        /// had ever opened this window would see the height that now fits their
        /// sensor list.
        ///
        /// It is a blunt instrument, and worth being honest about: it also
        /// discards a height the user picked by hand. That is the whole cost of
        /// the amnesia, it is paid once, and the window is still freely
        /// resizable afterwards.
        static let sensors = "sensors.v2"
        static let curves = "curves"
        /// ".v2" gives the settings window a fresh identity so macOS forgets the
        /// oversized frame earlier buggy versions saved for the old id.
        static let settings = "settings.v2"
        static let about = "about"
        /// The guided fan-control setup flow.
        static let setup = "setup"
        /// "Why is it hot?" — the live diagnosis.
        static let diagnosis = "diagnosis"

        /// The cooling-history chart and its controls.
        static let coolingHistory = "cooling-history"
    }

    /// The windows the menu bar may close on the user's behalf.
    ///
    /// An `LSUIElement` app has no Dock icon, no ⌘-Tab entry and, being an
    /// agent, no menu bar of its own — so it has no Window menu either. A
    /// window that is not on screen is therefore not merely out of the way, it
    /// is unreachable, and the user has no way to discover it still exists.
    /// Clicking away from one does not close it: measured on the owner's Mac,
    /// a Settings window dismissed that way was still open six minutes later.
    /// AppKit then does the ordinary thing it does for any app with more than
    /// one window — it promotes the next one when the front one closes
    /// (`order window: 460ca op: 1 relative: 460cc` in the AppKit window log,
    /// 5 ms after the Sensors window closed) — and a window nobody remembers
    /// opening arrives unannounced. That is the whole of the "the settings
    /// window pops up" bug. Nothing ever opened it; it was never closed.
    ///
    /// Membership answers one question: is anything lost by closing this?
    /// Settings and About commit every change as it is made and hold nothing.
    /// ``ID/curves`` is deliberately absent — the editor's points and preset
    /// name live in the window and are uncommitted until Apply Curve, so
    /// closing it would throw away a hand-drawn curve, which is a worse bug
    /// than this one. ``ID/setup`` is absent for the reason `IceCubeApp` gives
    /// for it being a window at all: that flow has to survive the user leaving
    /// for System Settings and coming back.
    ///
    /// ``ID/diagnosis`` is a member: it holds nothing and commits nothing — it
    /// is a live readout of this instant — and closing it is what stops the
    /// per-process sampling and discards the process names it collected.
    static let closableFromMenuBar: Set<String> = [
        ID.sensors, ID.settings, ID.about, ID.diagnosis, ID.coolingHistory,
    ]

    /// Which currently-open windows to close before `summoning` goes on screen.
    ///
    /// Ids in, ids out, so the decision can be exercised with no windows, no
    /// screen and no running app.
    ///
    /// The window being summoned is excluded on purpose: asking for Settings
    /// while Settings is open has to raise it, not close and rebuild it.
    /// SwiftUI tears a `Window` scene's content down on close, so a rebuild
    /// would silently reset the tab the user was on.
    static func windowsToClose(openWindowIDs: [String], summoning id: String) -> Set<String> {
        Set(openWindowIDs).intersection(closableFromMenuBar).subtracting([id])
    }

    /// Opens the window scene `id` and brings the app frontmost.
    ///
    /// For controls that live in one of the app's own windows. Deliberately has
    /// no way to close a popover: a dismissal fired from inside the Settings
    /// window would close *that* window. Popover buttons call
    /// ``openFromPopover(_:using:dismissing:)`` instead, so which call sites can
    /// dismiss is settled by the signature rather than by a convention someone
    /// has to remember.
    static func open(_ id: String, using openWindow: OpenWindowAction) {
        perform(
            dismiss: nil,
            open: { openWindow(id: id) },
            activate: { NSApp.activate(ignoringOtherApps: true) }
        )
    }

    /// Opens the window scene `id` from a control inside the menu bar popover,
    /// closing the popover on the way.
    ///
    /// - Parameter dismissPopover: `PopoverView.dismissPopover`, which closes
    ///   the popover in whichever mode is hosting it.
    static func openFromPopover(
        _ id: String, using openWindow: OpenWindowAction, dismissing dismissPopover: @escaping () -> Void
    ) {
        // Before `perform`, not inside it. The dismiss → open → activate order
        // is untouched and still pinned by WindowOpenerTests; this has to run
        // ahead of `activate`, which raises every window the app owns, because
        // a stale window closed after that would flash on screen first. And it
        // belongs to the popover alone: `open(_:using:)` is what the Settings
        // window uses to reach About, Curves and Setup, and those must not
        // close the window that opened them.
        closeStaleWindows(before: id)
        perform(
            dismiss: dismissPopover,
            open: { openWindow(id: id) },
            activate: { NSApp.activate(ignoringOtherApps: true) }
        )
    }

    /// Closes whatever the menu bar left behind, before it puts another window
    /// on screen.
    ///
    /// `frameAutosaveName` is what carries the scene id, not `identifier`:
    /// SwiftUI names a `Window`'s autosave slot after its id, which is why
    /// `defaults read io.github.thijsvos.icecube` lists `NSWindow Frame
    /// settings.v2`, whereas `identifier` is a decorated internal string.
    /// Windows that are not scenes — the popover at window level 101, the
    /// status item — have an empty autosave name and so match nothing.
    ///
    /// `isVisible` is the filter because it is exactly the state that goes
    /// wrong here: a window the user really closed already reports `false`,
    /// while the forgotten one behind Safari reports `true` for as long as it
    /// is invisible to the user.
    ///
    /// `close()` rather than `performClose(_:)`: the latter consults the
    /// delegate and beeps at a window with no close button. This is the app
    /// retracting its own window, not the user pressing anything — and SwiftUI
    /// treats it as the scene being dismissed, so a later `openWindow(id:)`
    /// brings it back.
    private static func closeStaleWindows(before id: String) {
        let visible = NSApp.windows.filter(\.isVisible)
        let doomed = windowsToClose(openWindowIDs: visible.map(\.frameAutosaveName), summoning: id)
        guard !doomed.isEmpty else { return }
        // Logged because the failure mode is a window moving on its own with no
        // trace of why — which is exactly how long this bug went unexplained.
        Logger(subsystem: HelperConstants.logSubsystem, category: "ui").notice(
            "menu bar: closing \(doomed.sorted().joined(separator: ", "), privacy: .public) before opening \(id, privacy: .public)"
        )
        for window in visible where doomed.contains(window.frameAutosaveName) {
            window.close()
        }
    }

    /// The three steps, in the one order that is correct — with the AppKit and
    /// SwiftUI actions injected so `WindowOpenerTests` can record them. The
    /// order is the whole of the fix, and it is invisible when wrong, which is
    /// exactly the kind of thing this project pins with a test.
    ///
    /// **Dismiss first.** The popover's window sits at `NSPopUpMenuWindowLevel`
    /// (101) while a `Window` scene sits at level 0, so a popover still on
    /// screen covers the window it just opened *even though that window is
    /// correctly key and main* — measured on macOS 26.4, and the entirety of
    /// the "Settings… opens behind the popover" bug. Opening first would also
    /// leave the popover drawn over the new window for the length of its close
    /// animation. Dismissing first makes the half-finished failure "popover
    /// closed, no window" rather than "window opened, popover covering it".
    ///
    /// **Activate last.** Closing the popover hands activation back to whatever
    /// app was in front — measured: `NSApp.isActive` goes false and `keyWindow`
    /// goes nil — so an activation placed any earlier is simply undone, which
    /// in an `LSUIElement` app is the FB11984872 failure this type exists to
    /// prevent. No dispatch hop between the steps either: a hop was measured to
    /// change nothing except how long the app spends deactivated with nothing
    /// on screen.
    static func perform(
        dismiss: (() -> Void)?,
        open: () -> Void,
        activate: () -> Void
    ) {
        dismiss?()
        open()
        activate()
    }
}
