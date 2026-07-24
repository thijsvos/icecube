// StatusItemShim.swift — makes the menu-bar icon respond to right-click as well as left-click.

import AppKit

/// SwiftUI's `MenuBarExtra` only reacts to left-clicks; there is no
/// first-party API to change that (FB11984872 territory). This shim finds
/// the status item's button in the status-bar window this process owns and
/// widens its action mask to both mouse buttons, so a right-click opens the
/// same popover.
///
/// Deliberately best-effort and defensive: it walks a private view hierarchy,
/// so if a macOS update changes the internals, every lookup simply fails and
/// right-click stays inert — nothing can break or crash.
enum StatusItemShim {
    /// Widens the status item's click mask. Returns whether it found the button,
    /// so a caller can retry until the item exists instead of guessing a delay.
    @discardableResult
    static func enableRightClick() -> Bool {
        for window in NSApp.windows
            where String(describing: type(of: window)).contains("NSStatusBarWindow")
        {
            if let button = firstStatusButton(in: window.contentView) {
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                return true
            }
        }
        return false
    }

    private static func firstStatusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let found = firstStatusButton(in: subview) {
                return found
            }
        }
        return nil
    }
}
