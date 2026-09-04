// StatusItemShim.swift — makes the menu-bar icon respond to right-click, and gives its digits equal widths.

import AppKit

/// Two things `MenuBarExtra` cannot be asked for, done to its button directly.
///
/// SwiftUI's `MenuBarExtra` only reacts to left-clicks — there is no
/// first-party API to change that (FB11984872 territory) — and it does not
/// host its label as a view at all: it copies the image and the text into the
/// native `NSStatusBarButton`, so a font modifier on the label is discarded.
/// Measured on 2026-09-02: the button's view tree was empty, its title was the
/// bare reading, and its font was the plain system font with
/// `.monospacedDigit()` applied to the label. This shim finds that button in
/// the status-bar window this process owns, widens its action mask to both
/// mouse buttons, and gives it the system font with tabular digits, so a
/// reading's width no longer depends on which digits it holds. `MenuBarLabel`
/// pads every reading to a fixed shape on top of that; the two together are
/// what keep the menu bar from sliding as the temperature changes.
///
/// Deliberately best-effort and defensive: it walks a private view hierarchy,
/// so if a macOS update changes the internals, every lookup simply fails —
/// right-click stays inert and the digits stay proportional — and nothing can
/// break or crash.
enum StatusItemShim {
    /// Widens the click mask and sets the tabular-digit font. Returns whether it
    /// found the button, so a caller can retry until the item exists instead of
    /// guessing a delay.
    @discardableResult
    static func configureButton() -> Bool {
        for window in NSApp.windows
            where String(describing: type(of: window)).contains("NSStatusBarWindow")
        {
            if let button = firstStatusButton(in: window.contentView) {
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                // The button's own size, with tabular figures. Measured to
                // survive every title SwiftUI writes afterwards: 45 of 45
                // one-second ticks kept the font and a 71 pt width.
                button.font = NSFont.monospacedDigitSystemFont(
                    ofSize: button.font?.pointSize ?? NSFont.systemFontSize, weight: .regular
                )
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
