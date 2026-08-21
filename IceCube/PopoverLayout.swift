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

    /// The height to give the scrolling region, or `nil` to leave it
    /// unconstrained because everything fits.
    ///
    /// - Parameters:
    ///   - contentHeight: what the scrolling content actually measured, or 0
    ///     before the first measurement has arrived.
    ///   - footerHeight: the pinned block below it — divider, optional update
    ///     row, footer buttons, bottom padding.
    ///   - availableHeight: `NSScreen.visibleFrame.height`, or `.infinity` when
    ///     there is no screen to ask.
    /// - Returns: `nil` when the content fits and should size naturally, so a
    ///   small popover stays small instead of being padded out to fill a tall
    ///   display.
    static func scrollHeight(
        contentHeight: CGFloat,
        footerHeight: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat? {
        // Before the first measurement lands there is nothing to decide, and
        // constraining to 0 would flash an empty popover on open.
        guard contentHeight > 0 else { return nil }
        let budget = availableHeight - footerHeight - bottomMargin
        // `budget` is NaN or infinite when there is no screen: fall through to
        // "no constraint" rather than to the floor, the same choice
        // `SensorListMetrics` makes for the same reason. Argument order in
        // `min` is load-bearing: a NaN *second* argument yields the first, so
        // the measured content wins over a poisoned budget either way.
        guard budget.isFinite, contentHeight > budget else { return nil }
        return max(minimumScrollHeight, budget)
    }
}
