// WindowOpener.swift — the one place that opens windows from the menu bar (LSUIElement focus dance).

import AppKit
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
        static let sensors = "sensors"
        static let curves = "curves"
        /// ".v2" gives the settings window a fresh identity so macOS forgets the
        /// oversized frame earlier buggy versions saved for the old id.
        static let settings = "settings.v2"
        static let about = "about"
        /// The guided fan-control setup flow.
        static let setup = "setup"
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
        perform(
            dismiss: dismissPopover,
            open: { openWindow(id: id) },
            activate: { NSApp.activate(ignoringOtherApps: true) }
        )
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
