// PopoverView.swift — the menu-bar popover: fans, temperatures, and the app's only Quit affordance.

import AppKit
import IceCubeKit
import SwiftUI

/// The content of the `MenuBarExtra` window.
///
/// Layout, top to bottom: the header (app name plus the SIMULATED badge —
/// deliberately no temperature, see ``PopoverHeader``), an error row when there
/// is one, then the cards: fans, the control section, the live charts, and the
/// temperature cards. Which of the middle three appear is the user's choice,
/// through `chartSettings.showControls` and `showCharts`. Below them a divider,
/// an update row when a newer release has been found, and the footer — Sensors…,
/// Settings…, "Why is it hot?" and Quit. Because Ice Cube is an `LSUIElement`
/// app there is no Dock icon, so that Quit is still the only way out.
///
/// Styling rule: system materials and hierarchical fills only, never opaque
/// custom colors, so the popover looks native in both light and dark mode.
struct PopoverView: View {
    /// The shared observable state; owned by `IceCubeApp`.
    let state: AppState

    /// Closes whichever window is hosting this view — SwiftUI's `MenuBarExtra`
    /// window, or the `NSPopover` in vendored hosting. Named for what it is, so
    /// `dismissPopover()` below can be the one thing the rest of the file calls.
    @Environment(\.dismiss) private var dismissHostingWindow

    /// Closes the popover in both hosting modes. Call this before opening any
    /// window from inside the popover.
    ///
    /// **Why the popover has to be closed at all:** its window sits at window
    /// level 101 while a `Window` scene sits at level 0, so it covers the
    /// window it just opened even though that window is correctly key and main.
    /// The Settings window was never opening behind anything — it was being
    /// drawn over.
    ///
    /// **Why two calls.** Neither one covers both modes. `dismissHostingWindow`
    /// is the only thing that closes SwiftUI's `MenuBarExtra` window without
    /// desyncing its presentation state — `NSWindow.close()` makes the next
    /// click on the menu bar icon do nothing and `performClose(_:)` does not
    /// hide it at all, both measured on macOS 26.4. It closes a vendored
    /// `NSPopover` too, but *only while that popover's window is key*, and the
    /// `makeKey()` in `StatusItemController.showPopover` is best-effort; when
    /// it has failed, `.transient`'s close-on-resign has no key window to
    /// resign either, so the explicit close is all that is left.
    ///
    /// **Neither call touches `state.isPopoverVisible`.** Whichever close wins
    /// reports itself — `.onDisappear` below in SwiftUI hosting,
    /// `popoverDidClose` in vendored. Clearing the flag here as well would do
    /// it while the popover is still animating out, and `body` would swap in
    /// the 1 pt placeholder: a 380×1 sliver in the user's face.
    private func dismissPopover() {
        dismissHostingWindow()
        // The optional is not a caveat: `AppState.start()` builds the
        // coordinator before the poll task, and `reconcileMenuBarMode()` — the
        // only thing that can ever select `.vendored` — returns early while it
        // is nil. So it is non-nil from launch, and vendored-with-no-coordinator
        // is unreachable rather than merely unlikely.
        state.menuBar?.closeVendoredPopover()
    }

    var body: some View {
        // MenuBarExtra(.window) keeps this view graph alive after the first
        // open, so while the window is off screen the live content must not be
        // built at all. It is not enough to stop publishing chart rows: the fan
        // gauges animate (0.45 s easeInOut) and the RPM readouts use
        // .contentTransition(.numericText()), both keyed on values that change
        // every second — which kept the hidden window in a continuous
        // CoreAnimation display cycle at ~18 % CPU. The lifecycle modifiers sit
        // on this outer Group so they still fire while the body is swapped out.
        Group {
            if state.isPopoverVisible {
                liveContent
            } else {
                // Same width token as the live content, so the window doesn't
                // resize on reopen.
                Color.clear.frame(width: Theme.Metrics.popoverWidth, height: 1)
            }
        }
        .task { await state.helper.maintainOnce() }
        .onAppear {
            state.popoverAppeared()
            quickSwitchIfOptionHeld()
        }
        .onDisappear { state.popoverDisappeared() }
    }

    /// ⌥-click on the menu bar item switches to the next preset (PLAN.md §1.1).
    ///
    /// **The popover still opens** — it just opens already switched. That is the
    /// cheap half of the plan's two variants and it is deliberately first:
    /// `MenuBarExtra` gives no way to intercept a click before the window
    /// appears, and the silent variant needs a hand-rolled `NSStatusItem` to
    /// host the glyph. Doing that here would put the whole menu bar at risk for
    /// a gesture; this reads one flag.
    ///
    /// Read at *appear* rather than captured earlier because there is nowhere
    /// earlier to read it. `NSEvent.modifierFlags` is the live keyboard state,
    /// so a user who releases ⌥ between the click and the window appearing gets
    /// an ordinary open — which is the harmless direction to be wrong in.
    private func quickSwitchIfOptionHeld() {
        // Only in SwiftUI hosting. `StatusItemController` reads the modifier
        // from the click event itself and usually never opens the popover at
        // all — but it does open it when a switch is refused, and ⌥ is often
        // still down at that moment, which would apply a second switch here.
        guard state.menuBar?.mode != .vendored else { return }
        guard NSEvent.modifierFlags.contains(.option) else { return }
        Task { await state.helper.cyclePreset(in: state.presets.all) }
    }

    /// What the scrolling half measured, and what the pinned half measured.
    /// Both start at 0, which `PopoverLayout.scrollHeight` reads as "no
    /// decision yet" and answers with no constraint.
    @State private var contentHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    /// The height the popover has to live in. `visibleFrame` has already
    /// excluded the menu bar and the Dock. No screen at all (headless, or mid
    /// display change) means no constraint, matching `PopoverTemperatureCards`.
    private var availableHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? .infinity
    }

    /// The footer is **outside** the scrolling region, on purpose.
    ///
    /// It used to be the last child of one unbounded `VStack`, so when the
    /// content grew past the screen the footer was simply the part that fell
    /// off the bottom — Settings and Quit, unreachable, with no scroll bar to
    /// reveal them. How tall the content gets is a user setting (six selectable
    /// chart series at 44/64/92 pt each, plus the 240 pt Inside card), so no
    /// amount of budgeting the *content* can guarantee the footer survives.
    /// Taking it out of the scroll makes that guarantee structural.
    private var liveContent: some View {
        VStack(spacing: 0) {
            // Only wrapped in a `ScrollView` when it actually has to scroll.
            //
            // It was unconditionally wrapped, with a `nil` frame height meaning
            // "everything fits, size naturally". That is not what `nil` does to
            // a `ScrollView`: a scroll view has no intrinsic height, so an
            // unconstrained one collapses to nothing. With Live charts and
            // Inside switched off — the default, and the common case — the
            // popover rendered as its footer and nothing else. The tall
            // configuration worked, because that one takes the capped branch
            // and gets an explicit height, which is why measuring only the
            // reported case missed it.
            switch presentation {
            case .natural:
                measuredContent
            case let .scrolling(height):
                ScrollView(.vertical) {
                    measuredContent
                }
                .frame(height: height)
                .scrollBounceBehavior(.basedOnSize)
            }
            pinnedFooter
        }
        .frame(width: Theme.Metrics.popoverWidth)
        .onPreferenceChange(PopoverHeightKey.self) { height in
            // `@Sendable` under Swift 6, so the assignment hops to the main
            // actor rather than capturing it. `@State` is `Sendable`, so the
            // capture itself is fine.
            Task { @MainActor in contentHeight = height }
        }
        .onPreferenceChange(PopoverFooterHeightKey.self) { height in
            Task { @MainActor in footerHeight = height }
        }
    }

    private var presentation: PopoverLayout.Presentation {
        PopoverLayout.presentation(
            contentHeight: contentHeight,
            footerHeight: footerHeight,
            availableHeight: availableHeight
        )
    }

    /// The cards, reporting their own height so the decision above can be made.
    private var measuredContent: some View {
        scrollingContent
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: PopoverHeightKey.self, value: geometry.size.height)
                }
            )
    }

    private var pinnedFooter: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            Divider()
            if case let .available(version, url) = state.updates.status {
                PopoverUpdateRow(version: version, url: url)
            }
            PopoverFooter(state: state, dismissPopover: dismissPopover)
        }
        .padding(.horizontal, Theme.Metrics.popoverPadding)
        .padding(.bottom, Theme.Metrics.popoverPadding)
        .padding(.top, Theme.Metrics.sectionSpacing)
        .frame(width: Theme.Metrics.popoverWidth, alignment: .leading)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: PopoverFooterHeightKey.self, value: geometry.size.height)
            }
        )
    }

    private var scrollingContent: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            PopoverHeader(state: state)
            if let errorMessage = state.errorMessage {
                PopoverErrorRow(message: errorMessage)
            }
            if state.snapshot == nil {
                PopoverWaitingRow()
            } else {
                PopoverFanCard(state: state)
                if state.chartSettings.showControls {
                    FanControlSection(
                        helper: state.helper,
                        presets: state.presets,
                        fans: state.fans,
                        dismissPopover: dismissPopover,
                        persistsCurveWithoutApp: state.persistsCurveWithoutApp
                    )
                }
                // Above the charts and below the fan card: it is a picture of
                // the same machine those two describe in numbers, and it reads
                // as the summary they are the detail of.
                if state.isInsideEnabled, state.showsInsideInPopover {
                    InsideView(state: state, presentation: .popover)
                        .popoverCard()
                }
                if state.chartSettings.showCharts {
                    DashboardView(state: state)
                }
                PopoverTemperatureCards(state: state)
            }
        }
        .padding(Theme.Metrics.popoverPadding)
        .frame(width: Theme.Metrics.popoverWidth, alignment: .leading)
    }

    // MARK: - Header

    // MARK: - Fans

    // MARK: - Minimalist temperature views (when charts are hidden)

    // MARK: - Waiting / error states

    // MARK: - Footer

    /// Needed to open the sensors window scene from inside the popover.
    @Environment(\.openWindow) private var openWindow
}

/// The easing used for live readings, or `nil` when the user has turned the
/// "smooth readings" preference off (values then snap instantly).
///
/// On `AppState` rather than on a view because the popover's cards are three
/// files now and all of them animate the same readings; duplicating the
/// derivation is how two of them end up disagreeing.
extension AppState {
    var readingAnimation: Animation? {
        chartSettings.smoothReadings ? .easeInOut(duration: 0.35) : nil
    }
}

/// The scrolling half's measured height, reported up from a background reader.
private struct PopoverHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The pinned half's measured height. Separate key, because the two are read
/// against each other and one `max` over both would hide the smaller.
private struct PopoverFooterHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
