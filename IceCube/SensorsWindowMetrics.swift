// SensorsWindowMetrics.swift — how tall the Sensors window opens: as tall as its own list, clamped to the screen.

import CoreGraphics

/// Decides the Sensors window's opening height from the list it is about to
/// draw.
///
/// **Why arithmetic and not layout.** The obvious answer — let the content size
/// the window — does not exist on this platform. Measured on macOS 26.4: a
/// SwiftUI `Window` never reads its content's `idealHeight` (every variation
/// opened at the same 450 pt fallback, with and without
/// `.windowResizability`), and a `List` has no ideal height to offer anyway
/// (`fittingSize.height` is 0 and `intrinsicContentSize.height` is −1 at 2, 6,
/// 12, 22 and 40 rows alike). `.windowResizability(.contentSize)` does make a
/// window fit its content, but only for content that self-sizes, and it then
/// reports `minSize == maxSize` — a window the user can no longer resize, which
/// the raw-key table needs. That leaves `.defaultSize`, and `.defaultSize`
/// takes a number. So the number is computed here, and every constant below is
/// a measurement rather than a guess.
///
/// **Why it has to vary.** The readable list is one row per sensor, and the
/// sensor count is not a property of the app — it is a property of the Mac.
/// Six in simulated mode, ~22 on the owner's M2 Pro, and on a Mac outside
/// `SMCKeyMaps`' curated models, where discovery falls back to enumerating
/// every plausible key, considerably more. One fixed height cannot serve that
/// range: 480 pt was half a window of dead space on the first and a peephole on
/// the last.
///
/// **Why clamped rather than exact.** An enumerating Mac wants a window several
/// times taller than the display. Past the point where the window dominates the
/// screen, more height stops helping and scrolling is what a `List` is for — so
/// the ceiling is screen-relative with an absolute backstop, and the floor
/// keeps a fanless Mac with no recognized sensors from opening a sliver.
///
/// `availableHeight` is a parameter rather than an `NSScreen` lookup so the
/// whole decision stays a pure function of two numbers, testable with no
/// display attached; the one `NSScreen` call lives at the call site in
/// `IceCubeApp`.
///
/// The "All SMC keys" table is deliberately **not** an input. It is a toggle
/// inside an already-open window, and nothing resizes a window after it is
/// created — from there the user's own resize is what persists.
nonisolated enum SensorsWindowMetrics {
    // MARK: - Measured pieces (macOS 26.4, default text size)

    /// One data row of the readable list. Measured row pitch is exactly 24 pt
    /// with no inter-row spacing, and a temperature row measures the same as a
    /// fan row despite the flame icon and the RPM-range caption.
    private static let rowHeight: CGFloat = 24

    /// Everything in the list that is not a data row: 10 pt top inset, two
    /// 28 pt `Section` headers, the 20 pt gap between the sections, 10 pt
    /// bottom inset.
    private static let listChrome: CGFloat = 10 + 28 + 20 + 28 + 10

    /// The controls strip — `.mini` controls under `.padding(10)`, measured at
    /// 44 pt — plus the 1 pt `Divider` below it.
    private static let controlsBar: CGFloat = 45

    /// `.defaultSize` is a **frame** height while `.frame(minHeight:)` is in
    /// content points: ask for 365 and the window frame is 365 with 333 left
    /// for SwiftUI. Every conversion between the two goes through this, which
    /// is why it is not private.
    static let titleBarHeight: CGFloat = 32

    /// Half a row of tolerance. The constants above were measured on macOS 26.4
    /// against a 14.0 deployment target, and the two failure directions are not
    /// symmetric: too tall is a strip of empty list background, too short clips
    /// the last row — and macOS then saves that clipped frame. Half a row
    /// absorbs the drift without reintroducing the dead space this type exists
    /// to remove.
    private static let slack: CGFloat = rowHeight / 2

    // MARK: - The bounds

    /// The smallest window we open, and the floor the user can drag to. Roughly
    /// six rows: a short list rather than a peephole.
    static let minimumFrameHeight: CGFloat = 320

    /// The absolute ceiling. Beyond this a 560 pt-wide window reads as a broken
    /// column rather than a sensor list, however many sensors there are.
    static let maximumFrameHeight: CGFloat = 860

    /// How much of the usable height to leave alone. `visibleFrame` has
    /// already excluded the menu bar and the Dock (measured here: 1169 pt of
    /// screen, 1130 pt visible) — this is a second margin on top, so that a
    /// long sensor list produces a tall window rather than one that swallows
    /// the whole desktop.
    private static let screenMargin: CGFloat = 120

    /// The floor for `SensorsBrowserView`'s own `.frame(minHeight:)`, derived
    /// from ``minimumFrameHeight`` rather than picked separately.
    ///
    /// A content minimum silently overrides `.defaultSize` **upward**: with the
    /// 440 pt floor this view used to carry, a scene asking to open at 365
    /// came up at 472 — 440 plus the title bar — and reported
    /// `window.minSize.height == 472`. Two independently chosen numbers is how
    /// that happens; one derivation is how it stops.
    static let minimumContentHeight: CGFloat = minimumFrameHeight - titleBarHeight

    // MARK: - The decision

    /// How many rows the readable list will draw.
    ///
    /// An empty section is not free: "No named temperature sensors on this
    /// model yet…" and "No fans reported (fanless Mac)." each occupy a row, so
    /// both sections count for at least one.
    static func rowCount(temperatures: Int, fans: Int) -> Int {
        max(1, temperatures) + max(1, fans)
    }

    /// What to assume before the first poll has told us how many sensors this
    /// Mac has.
    ///
    /// "Not measured yet" is emphatically not "this Mac has no sensors", and
    /// treating them alike is expensive: a window opened in that gap would come
    /// up at the floor, and macOS saves the frame of a window the first time it
    /// opens — permanently, for the life of the scene id. The gap is under
    /// 100 ms on a Mac whose sensors are curated, but on an unmapped model
    /// discovery walks every key on the machine, which is 1–2 s — and the
    /// unmapped user is exactly who gets sent to this window to export
    /// diagnostics. Twelve rows lands at 473 pt: near enough the fixed 480 this
    /// type replaced that an unlucky first open is no worse off than before.
    static let unmeasuredRowCount = 12

    /// The height to hand `.defaultSize` — frame points, title bar included.
    ///
    /// - Parameters:
    ///   - rowCount: what ``rowCount(temperatures:fans:)`` returned, or `nil`
    ///     before the first snapshot has landed (see ``unmeasuredRowCount``).
    ///   - availableHeight: `NSScreen.visibleFrame.height` for the screen the
    ///     window will land on, or `.infinity` when there is no screen to ask —
    ///     which falls back to ``maximumFrameHeight``, not to the floor.
    static func frameHeight(rowCount: Int?, availableHeight: CGFloat) -> CGFloat {
        let rows = max(0, rowCount ?? unmeasuredRowCount)
        let wanted = titleBarHeight + controlsBar + listChrome + slack + rowHeight * CGFloat(rows)
        // The ceiling is floored first. On a small enough display the
        // screen-relative limit would otherwise drop below `minimumFrameHeight`
        // and the two clamps would fight, yielding a window shorter than the
        // minimum we just promised.
        //
        // Argument order inside `min` is load-bearing and not interchangeable:
        // Swift's `min(x, y)` returns `y < x ? y : x`, so a NaN second argument
        // yields `x` while a NaN first argument yields NaN — and a NaN here
        // would collapse the whole thing to the floor. `availableHeight` is the
        // one that can be strange, so it goes second. Pinned by a test.
        let ceiling = max(minimumFrameHeight, min(maximumFrameHeight, availableHeight - screenMargin))
        return min(max(wanted, minimumFrameHeight), ceiling)
    }
}
