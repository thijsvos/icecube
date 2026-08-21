// SensorListMetrics.swift — how much of the popover the sensor list may take, and when it starts scrolling.

import CoreGraphics

/// Decides the height of the popover's sensor list, and whether it scrolls.
///
/// **Why the list needs a bound at all.**
/// `PopoverTemperatureCards.temperatureListSection` draws one row per
/// `AppState.temperatures` entry, and that count is a
/// property of the Mac rather than of the app: 20 on the owner's curated
/// Mac14,9, but on a model outside `SMCKeyMaps`' curated set discovery
/// enumerates every plausible `T*` key — 193 of them on this same hardware.
/// Nothing bounded that, and neither hosting mode degrades usefully. Measured
/// on macOS 26.4 at 193 rows (a 3113 pt content stack, 1130 pt of usable
/// screen):
///
///   * SwiftUI hosting (`MenuBarExtra(.window)`) does **not** clamp. The window
///     came up 380 × 3113 with its bottom edge 1985 pt below the display. Its
///     top is pinned under the menu bar, so what runs off is the footer — and
///     Ice Cube is `LSUIElement`, so that footer holds the only Quit. In the
///     default configuration the footer leaves the screen at 29 sensors.
///   * Vendored hosting (`NSPopover`) clamps the *window* to the visible frame
///     and leaves the *content* at 3113 pt, bottom-anchored inside it: header,
///     fans, control and charts are drawn off the top. No scroller is inserted.
///
/// So the bound is introduced here, as arithmetic, for the same reason
/// ``SensorsWindowMetrics`` is arithmetic: a fixed frame is the only thing that
/// stops a SwiftUI stack sizing itself, and a fixed frame takes a number.
///
/// **Why the number comes from the INVENTORY, not from the rows on screen.**
/// `SensorStabilizer` guarantees the published list is *monotone*, not fixed —
/// a power-gated cluster reports nothing usable for up to ~85 s after launch,
/// so on Mac14,9 the list grows 8 → 20 rows during the first minute and a half.
/// Sizing to what is reporting would grow the popover 192 pt under the user's
/// cursor: the exact resize `SensorStabilizer` exists to prevent, arriving
/// through the back door. Sizing to the inventory reserves the space once and
/// lets late rows fill it.
///
/// `availableHeight` is a parameter rather than an `NSScreen` lookup so the
/// whole decision is a pure function of two numbers, testable with no display
/// attached.
nonisolated enum SensorListMetrics {
    // MARK: - Measured pieces (macOS 26.4, default text size, 380 pt popover)

    /// One row of the list: a `.caption` line measures 13 pt, and the enclosing
    /// `VStack` adds ``rowSpacing`` beneath every row but the last.
    static let rowPitch: CGFloat = 16

    /// The list's inter-row spacing. Not private: `PopoverTemperatureCards`
    /// builds the `VStack` with it, so the view and this arithmetic cannot
    /// drift — the same reason `SensorsWindowMetrics.titleBarHeight` is not
    /// private.
    static let rowSpacing: CGFloat = 3

    /// Everything in the popover that is **not** the scrollable region and not
    /// the Inside card: header, fan card, control card, chart card, divider,
    /// footer, the section gaps and the outer padding — measured at 629 pt —
    /// plus the 10 pt gap above the Sensors card and that card's own 41 pt of
    /// title and padding.
    ///
    /// Deliberately the *worst* case of the things it covers. Using the average
    /// would let the clamp promise a fit it cannot deliver to the user who
    /// turned everything on, and that user is precisely the one who also turned
    /// this list on.
    ///
    /// **It stopped being the whole story when Inside shipped.** This number is
    /// a measurement, and a measurement of "the tallest configuration" goes
    /// stale the moment a new card can appear above the list. Inside did
    /// exactly that: with it on, the reserved list was computed as though 240 pt
    /// of schematic were not there, the popover grew past the bottom of the
    /// screen, and the footer — Settings, Quit — went with it. So the Inside
    /// card is ``insideCardHeight`` and is added by ``layout(sensorCount:availableHeight:showsInside:)``
    /// rather than folded in here: it is opt-in and off by default, and baking
    /// it into the constant would cost every user who does not run it 240 pt of
    /// sensor list to pay for a card they never see.
    static let popoverChrome: CGFloat = 680

    /// What the Inside card adds when it is shown in the popover: the
    /// schematic's own height, the card padding around it, and the section gap
    /// above it.
    ///
    /// Spelled out rather than computed from `InsideStage.popoverHeight` and
    /// `Theme.Metrics`, because this enum is `nonisolated` and both of those are
    /// MainActor-isolated — the same reason `SensorsWindowMetrics` writes its
    /// measurements as plain numbers. `insideCardHeightMatchesTheCard` pins the
    /// sum, so the two still cannot drift; the check just happens in a test
    /// rather than in the type system.
    ///
    /// 210 (`InsideStage.popoverHeight`) + 2 × 10 (`cardPadding`) + 10
    /// (`sectionSpacing`).
    static let insideCardHeight: CGFloat = 240

    // MARK: - The bounds

    /// Never reserve less than this. Roughly six rows: a short list rather than
    /// a peephole, even if ``popoverChrome`` is one day an underestimate. It is
    /// also exactly what simulated mode draws (`MockSMCProvider` has six
    /// sensors), so `ICECUBE_SIMULATED=1` looks identical before and after.
    static let minimumListHeight: CGFloat = 6 * rowPitch - rowSpacing

    /// Never reserve more than this, however tall the display. Twenty-two rows
    /// keeps the whole popover a menu rather than a window, and is more rows
    /// than any curated map in `SMCKeyMaps` (M2 has 20). A future map that
    /// outgrows it scrolls, which is the designed behaviour, not a regression.
    static let maximumListHeight: CGFloat = 22 * rowPitch - rowSpacing

    // MARK: - The decision

    /// What the sensor card should do, decided once so the reserved height and
    /// the "there is more" cue can never disagree.
    struct Layout: Equatable {
        /// The exact height to give the scroll region.
        let height: CGFloat
        /// Whether the region cannot show every row at once.
        let scrolls: Bool
    }

    /// How tall the list would be if nothing stopped it.
    static func contentHeight(sensorCount: Int) -> CGFloat {
        sensorCount <= 0 ? 0 : rowPitch * CGFloat(sensorCount) - rowSpacing
    }

    /// How tall the sensor list should be, and whether it has to scroll.
    ///
    /// - Parameters:
    ///   - sensorCount: how many sensors this Mac **has** — the inventory
    ///     count, floored by the rows currently published so the region is
    ///     never shorter than what it must draw.
    ///   - availableHeight: `NSScreen.visibleFrame.height` for the screen the
    ///     popover hangs on, or `.infinity` when there is no screen to ask —
    ///     which falls back to ``maximumListHeight``, not to the floor.
    ///   - showsInside: whether the Inside card is above the list right now.
    ///     Deliberately **not** defaulted: a default is how the Inside card
    ///     went unaccounted for in the first place, and the next card added to
    ///     the popover should have to answer this question out loud.
    static func layout(sensorCount: Int, availableHeight: CGFloat, showsInside: Bool) -> Layout {
        let wanted = contentHeight(sensorCount: sensorCount)
        let chrome = popoverChrome + (showsInside ? insideCardHeight : 0)
        // The ceiling is floored first, so a small display cannot push the
        // screen-relative limit below the floor and leave the two clamps
        // fighting.
        //
        // Argument order inside `min` is load-bearing and not interchangeable:
        // Swift's `min(x, y)` is `y < x ? y : x`, so a NaN *second* argument
        // yields `x` while a NaN *first* argument yields NaN — and NaN here
        // would collapse the region to the floor. `availableHeight` is the one
        // that can be strange, so it goes second. Pinned by a test.
        let cap = max(minimumListHeight, min(maximumListHeight, availableHeight - chrome))
        return Layout(height: min(wanted, cap), scrolls: wanted > cap)
    }
}
