// PopoverLayout.swift — how tall the popover may be, and what gives way when it cannot fit.

import Foundation

/// The popover's height budget.
///
/// **Why this exists, and why the previous answer could not work.**
/// `SensorListMetrics.popoverChrome` tried to express "everything that is not
/// the sensor list" as one measured constant, so the list could reserve what
/// was left. That is only possible if the rest of the popover has a fixed
/// height, and it does not: the chart section is `ForEach(chartRows)` over up
/// to six user-selected series at a user-selected row height (44 / 64 / 92 pt),
/// and the Inside card is opt-in at 240 pt more.
///
/// Measured once at 680 pt, the real value reached **1004 pt** on the reporting
/// machine — a 1216 pt popover in 1089 pt of room, with the footer (Settings,
/// Quit) 127 pt past the bottom edge and no way to reach it. Raising the
/// constant does not fix that class of bug; it postpones it until the next card
/// or the next row-height option, which is exactly how it arrived twice.
///
/// So nothing here predicts the content height. The view measures what it
/// actually drew, and this decides what to do about it — and the footer is
/// pinned outside the scrolling region, which makes "you can always reach
/// Settings" a structural property rather than an arithmetic one.
nonisolated enum PopoverLayout {
    /// Breathing room between the popover's bottom edge and the screen's, so a
    /// popover that only just fits does not sit flush against the edge.
    static let bottomMargin: CGFloat = 12

    /// Never squeeze the scrolling half smaller than this, however tall the
    /// pinned footer grows or however short the screen is. Below roughly this
    /// the popover stops being a readable surface and becomes a slot, and at
    /// that point a scroll bar is the honest answer rather than a smaller one.
    static let minimumScrollHeight: CGFloat = 220

    /// How to present the popover's cards.
    ///
    /// A two-case answer rather than an optional height, because the two cases
    /// are different *views*, not the same view with and without a constraint.
    /// That distinction was the bug: the cards were unconditionally wrapped in
    /// a `ScrollView` and "it fits" was expressed as a `nil` frame height. A
    /// scroll view has no intrinsic height, so an unconstrained one collapses
    /// to nothing — the popover rendered as its footer and no content at all,
    /// for every user whose cards fit, which is the default configuration.
    ///
    /// Making it an enum means "fits" cannot be spelled as "a scroll view with
    /// no height" again without changing this type and the tests below it.
    enum Presentation: Equatable {
        /// Draw the cards plainly, at their natural height. **Not** a scroll
        /// view — see above.
        case natural
        /// Draw them in a scroll view pinned to this height.
        case scrolling(height: CGFloat)
    }

    /// - Parameters:
    ///   - contentHeight: what the cards actually measured, or 0 before the
    ///     first measurement has arrived.
    ///   - footerHeight: the pinned block below them — divider, optional
    ///     update row, footer buttons, bottom padding.
    ///   - availableHeight: `NSScreen.visibleFrame.height`, or `.infinity` when
    ///     there is no screen to ask.
    ///
    /// Before the first measurement `contentHeight` is 0 and the answer is
    /// ``Presentation/natural``, so the cards render at full height and measure
    /// themselves. Starting them inside a zero-height scroll view would starve
    /// the geometry read that decides their height, and they would never grow.
    static func presentation(
        contentHeight: CGFloat,
        footerHeight: CGFloat,
        availableHeight: CGFloat
    ) -> Presentation {
        guard contentHeight > 0 else { return .natural }
        let budget = availableHeight - footerHeight - bottomMargin
        // `budget` is NaN or infinite when there is no screen: draw naturally
        // rather than sizing from a number that is not one. `SensorListMetrics`
        // documents the same hazard for the same reason.
        guard budget.isFinite, contentHeight > budget else { return .natural }
        return .scrolling(height: max(minimumScrollHeight, budget))
    }
}
