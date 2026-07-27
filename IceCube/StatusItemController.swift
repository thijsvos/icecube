// StatusItemController.swift — our own menu bar item, so ⌥-click can switch presets without opening anything.

import AppKit
import IceCubeKit
import Observation
import os
import SwiftUI

/// A hand-rolled `NSStatusItem` hosting the same glyph and the same popover as
/// `MenuBarExtra`, used only when the user opts into the silent ⌥-click
/// (PLAN.md §1.1).
///
/// **Why this exists rather than a SwiftUI modifier:** `MenuBarExtra` gives no
/// hook that runs *before* its window appears, so the popover has already opened
/// by the time anything can read the modifier keys. Owning the button is the
/// only way to decide not to open it.
///
/// **Why it is opt-in:** it re-hosts the glyph, the popover, and the
/// pause-when-closed work that took ~17 % sustained CPU down to idle. That is a
/// lot of the menu bar to rebuild for one gesture, and nobody has to turn it on.
///
/// Zero dependencies, ~150 lines, all first-party AppKit — the "vendored shim"
/// PLAN.md §1.1 describes.
@MainActor
final class StatusItemController: NSObject, MenuBarHosting, NSPopoverDelegate {
    private let state: AppState
    private var item: NSStatusItem?
    private var popover: NSPopover?
    /// A preset name shown briefly instead of the live text, after a silent
    /// switch. Nil the rest of the time.
    private var flashedName: String?
    private var flashTask: Task<Void, Never>?
    private let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "ui")

    init(state: AppState) {
        self.state = state
        super.init()
    }

    // MARK: - MenuBarHosting

    func installVendoredItem() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            // Nothing to attach to. Bail loudly rather than leave a dead item in
            // the bar: `MenuBarModeCoordinator` has already withdrawn SwiftUI's,
            // so a silent failure here means no menu bar icon at all.
            log.error("menu bar: the status item has no button — cannot host the vendored item")
            NSStatusBar.system.removeStatusItem(item)
            return
        }
        // The glyph, verbatim. Same NSImage the SwiftUI label uses, already
        // sized to 18pt by MenuBarGlyph. Deliberately NOT a template: the colour
        // is the brand mark (see MenuBarGlyph), so nothing here tints it.
        button.image = MenuBarGlyph.iceCube
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(buttonClicked)
        // Right-click opens the popover too, matching what `StatusItemShim`
        // arranges for the SwiftUI item.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.item = item
        applyTitle()
        observeTitle()
        log.notice("menu bar: vendored status item installed")
    }

    func removeVendoredItem() {
        flashTask?.cancel()
        flashTask = nil
        flashedName = nil
        // The coordinator has already paused the popover; closing here is about
        // the window, not the flag.
        popover?.performClose(nil)
        popover = nil
        if let item {
            NSStatusBar.system.removeStatusItem(item)
        }
        item = nil
        log.notice("menu bar: vendored status item removed")
    }

    // MARK: - The click

    @objc private func buttonClicked() {
        // `NSApp.currentEvent` is the click being handled, so this reads the
        // modifiers *as of that click* rather than the live keyboard — which by
        // now may have changed.
        let optionHeld = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        guard optionHeld else {
            togglePopover()
            return
        }
        Task { await quickSwitch() }
    }

    private func quickSwitch() async {
        guard let applied = await state.helper.cyclePreset(in: PresetStore.builtins) else {
            // Refused, or the apply failed. Mode B has no error surface of its
            // own, so route the user to the one that already exists rather than
            // letting an ⌥-click look like a dead button.
            log.notice("menu bar: quick-switch did not apply — opening the popover instead")
            showPopover()
            return
        }
        flash(applied.name)
    }

    /// The only acknowledgement a silent switch gets: the preset's name in place
    /// of the live text for a moment.
    ///
    /// The title is ours in this mode, so changing it does not risk the
    /// status-item glitch that structurally changing a `MenuBarExtra` label
    /// does. The glyph is untouched.
    private func flash(_ name: String) {
        flashTask?.cancel()
        flashedName = name
        applyTitle()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            flashedName = nil
            applyTitle()
        }
    }

    // MARK: - The popover

    private func togglePopover() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = item?.button else { return }
        let popover = popover ?? makePopover()
        self.popover = popover
        // Clicking a status item does NOT activate an LSUIElement app, so
        // without this the popover's window never becomes key — and both of the
        // bugs that caused are invisible from the code:
        //
        //   1. SwiftUI draws every control in its inactive state, so the active
        //      preset's `.tint(Theme.accent)` greys out and the popover looks
        //      like nothing is selected at all.
        //   2. `.transient` dismisses when its window resigns key. With no key
        //      window there is nothing to resign, so clicking elsewhere on
        //      screen left the popover stuck open until a button was pressed.
        //
        // `MenuBarExtra` does this for its own window; owning the item means
        // owning this too.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(state: state))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        return popover
    }

    /// `willShow`, not `didShow`: with `isPopoverVisible` still false the popover
    /// body is a 1pt-high placeholder, so a flag set after the window is on
    /// screen opens it at 380×1 and makes it jump to full height.
    func popoverWillShow(_: Notification) {
        state.popoverAppeared()
        // The same "reflect reality promptly" hook `PopoverView.task` gives the
        // SwiftUI path. Concurrent callers join the pass in flight, so the
        // duplication with that hook is free.
        Task { await state.helper.maintainOnce() }
    }

    func popoverDidClose(_: Notification) {
        state.popoverDisappeared()
    }

    // MARK: - Title

    private func applyTitle() {
        guard let button = item?.button else { return }
        button.title = flashedName ?? state.menuBarText ?? ""
        button.setAccessibilityLabel("Ice Cube, hottest sensor \(state.hottestText)")
    }

    /// Keeps the title in step with the 1 Hz poll.
    ///
    /// `withObservationTracking` fires **once**, so it re-arms itself — the
    /// standard `@Observable` idiom. A timer here would be a second clock
    /// competing with the poller for no benefit.
    private func observeTitle() {
        withObservationTracking {
            applyTitle()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let controller = self, controller.item != nil else { return }
                controller.observeTitle()
            }
        }
    }
}
