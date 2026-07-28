// MenuBarMode.swift — which status item is in the menu bar, and the order the swap must happen in.

import Foundation

/// Who owns the menu bar item.
///
/// Ice Cube can host its status item two ways, and the difference is one
/// gesture: SwiftUI's `MenuBarExtra` cannot intercept a click before its window
/// appears, so ⌥-click there switches the preset *and* opens the popover. A
/// hand-rolled `NSStatusItem` can, so ⌥-click switches silently.
///
/// The SwiftUI one is the default and always will be. The vendored one exists
/// because PLAN.md §1.1 asked for the silent gesture, and it is opt-in because
/// it re-hosts the glyph, the popover, and the pause-when-closed work that took
/// ~17 % sustained CPU down to idle — a lot of the menu bar to put behind a
/// preference nobody has to turn on.
enum MenuBarMode: String, Equatable {
    /// `MenuBarExtra`. What every build before 2026-07-27 used, and the default.
    case swiftUI
    /// Our own `NSStatusItem`.
    case vendored

    /// Where the user's choice is stored. One owner, so the Settings toggle and
    /// the reconciler cannot drift apart.
    static let preferenceKey = "menu.silentOptionClick"

    /// Which mode should be active.
    ///
    /// **Both conditions matter.** The vendored item is only safe once the user
    /// has finished setup, because the first-run and version-mismatch prompts
    /// hang off the `MenuBarExtra` label's `.task`. In an `LSUIElement` app with
    /// no Dock icon, a half-set-up user in vendored mode would have no entry
    /// point to fix it at all.
    static func resolve(prefersSilentOptionClick: Bool, isSetUp: Bool) -> MenuBarMode {
        prefersSilentOptionClick && isSetUp ? .vendored : .swiftUI
    }
}

/// The part of `AppState` the swap has to touch. A protocol so the ordering can
/// be tested without building an `AppState`, which would drag in the chart
/// store, the alert manager and `UNUserNotificationCenter`.
@MainActor
protocol PopoverLifecycleObserving: AnyObject {
    func popoverDisappeared()
}

/// The vendored status item, as the coordinator sees it.
@MainActor
protocol MenuBarHosting: AnyObject {
    func installVendoredItem()
    func removeVendoredItem()
    /// Closes the vendored popover if it is on screen, and does nothing at all
    /// otherwise.
    ///
    /// **Must not touch `isPopoverVisible`.** The close is animated: the
    /// popover slides out and only then calls `popoverDidClose`, which is what
    /// reports the transition. Clearing the flag here as well would render
    /// `PopoverView`'s 1 pt placeholder while the popover is still on screen,
    /// collapsing it to a 380×1 sliver in front of the user.
    func closePopover()
}

/// Performs the swap between the two hosting modes, in one place, in one order.
///
/// **Why this exists at all.** The dangerous part of this feature is not the
/// AppKit code — it is that a swap can strand `AppState.isPopoverVisible` at
/// `true`. Nothing looks wrong when that happens: the UI is identical and the
/// behaviour is identical. The popover simply keeps animating its gauges and
/// its `.contentTransition(.numericText())` readouts into a window that is not
/// on screen, at roughly 17 % CPU, forever, on a laptop app whose entire pitch
/// is thermal sanity. It is reachable from *both* directions.
///
/// So `popoverDisappeared()` is called here, unconditionally, on every
/// transition, before anything moves — rather than by each hosting mode's own
/// teardown, which is two call sites and therefore one of them eventually
/// missing it. Making it structurally impossible is cheaper than testing for it,
/// and it is tested anyway.
@MainActor
@Observable
final class MenuBarModeCoordinator {
    /// Bound to `MenuBarExtra(isInserted:)`. False withdraws SwiftUI's status
    /// item so ours can take its place.
    private(set) var isSwiftUIItemInserted = true
    private(set) var mode: MenuBarMode = .swiftUI

    private let host: any MenuBarHosting
    private let lifecycle: any PopoverLifecycleObserving

    init(host: any MenuBarHosting, lifecycle: any PopoverLifecycleObserving) {
        self.host = host
        self.lifecycle = lifecycle
    }

    func apply(_ desired: MenuBarMode) {
        guard desired != mode else { return }
        // First, always, both directions. See the type's doc comment.
        lifecycle.popoverDisappeared()
        switch desired {
        case .vendored:
            // Withdraw before installing, so the two items are never both in
            // the menu bar — which would show the glyph twice.
            isSwiftUIItemInserted = false
            host.installVendoredItem()
        case .swiftUI:
            host.removeVendoredItem()
            isSwiftUIItemInserted = true
        }
        mode = desired
    }

    /// Closes the popover because the user opened a window from it.
    ///
    /// **Only the vendored half.** SwiftUI's `MenuBarExtra` window is closed by
    /// the ambient `@Environment(\.dismiss)` in `PopoverView`, never from here:
    /// every AppKit route to that window was measured to desync SwiftUI's own
    /// presentation state — `NSWindow.close()` makes the next click on the menu
    /// bar icon do nothing, and `performClose(_:)` does not even hide it. This
    /// is the one place the `StatusItemShim` precedent (walk the private
    /// hierarchy, best-effort) should *not* be followed: there is a first-party
    /// API and it works.
    ///
    /// The vendored popover needs this **as well as** that dismissal, because
    /// `@Environment(\.dismiss)` inside an `NSPopover` only closes it while the
    /// popover's window is key — measured both ways on macOS 26.4. The
    /// `makeKey()` in `showPopover` is best-effort, and in the case where it
    /// has failed `.transient`'s close-on-resign cannot help either (there is
    /// no key window to resign), so without this the popover would stay up
    /// precisely when things are already going wrong.
    ///
    /// Deliberately **not** called from `apply(_:)`: pausing the popover for a
    /// hosting swap and closing it for a window are different jobs, and the
    /// swap must keep clearing the flag while this must never touch it.
    func closeVendoredPopover() {
        guard mode == .vendored else { return }
        host.closePopover()
    }
}
