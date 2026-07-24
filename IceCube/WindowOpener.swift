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
    }

    /// Opens the window scene `id` and brings the app frontmost.
    static func open(_ id: String, using openWindow: OpenWindowAction) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
