// SensorsWindowMetricsTests.swift — the Sensors window fits its list on every Mac without running off the screen.

import CoreGraphics
import Foundation
import Testing

/// The window height is arithmetic precisely because the platform would not do
/// it for us, and arithmetic nobody checks is how a Mac Studio ends up with a
/// window taller than its display. These pin the three things that matter: the
/// height follows the sensor count, it never escapes the screen, and the view's
/// own minimum can never veto the smallest window we promise to open.
@MainActor
@Suite("SensorsWindowMetrics — how tall the Sensors window opens")
struct SensorsWindowMetricsTests {
    /// Taller than any real display, so the content arithmetic can be asserted
    /// without the screen clamp in the way.
    private func height(_ rows: Int?, screen: CGFloat = .infinity) -> CGFloat {
        SensorsWindowMetrics.frameHeight(rowCount: rows, availableHeight: screen)
    }

    /// The measured row pitch, restated here so the expectations below can say
    /// "one row" in `CGFloat`.
    ///
    /// Typed deliberately. `#expect(aCGFloat == 16 * 24)` does not compare
    /// numbers: with nothing to constrain it the right-hand side infers as
    /// `Int`, swift-testing's binary-operation check unifies the two through
    /// `AnyHashable`, and 384.0 ≠ 384 — a green-looking assertion that fails
    /// for a reason having nothing to do with the code under test. This suite
    /// caught it on itself.
    private let oneRow: CGFloat = 24

    // MARK: Counting rows

    /// Neither section is ever truly empty on screen: "No named temperature
    /// sensors on this model yet…" and "No fans reported (fanless Mac)." each
    /// occupy a row, so a Mac that reports nothing still needs room for two.
    @Test("An empty section still costs a row")
    func emptySectionsCountAsOneRow() {
        #expect(SensorsWindowMetrics.rowCount(temperatures: 0, fans: 0) == 2)
        #expect(SensorsWindowMetrics.rowCount(temperatures: 6, fans: 0) == 7)
        #expect(SensorsWindowMetrics.rowCount(temperatures: 6, fans: 2) == 8)
        #expect(SensorsWindowMetrics.rowCount(temperatures: 22, fans: 2) == 24)
    }

    // MARK: Fitting the content

    /// The whole point of the change, stated as the two machines it was made
    /// for: the six-sensor simulated list must open smaller than the fixed
    /// 480 pt it used to get, and a sensor-rich Mac must open bigger.
    ///
    /// The owner's Mac14,9 has 23 curated sensors but does not report a fixed
    /// number of them — `SystemSMCProvider` admits a sensor only if its very
    /// first read passes the plausibility gate, so consecutive `icecube-diag`
    /// runs on an idle machine returned 16, 20, 16, 20. That is why the
    /// interesting case is expressed in rows rather than as "an M2 Pro".
    @Test("A sensor-rich Mac opens taller than a six-sensor one, and the small one shrank")
    func heightFollowsTheSensorCount() {
        let simulated = height(SensorsWindowMetrics.rowCount(temperatures: 6, fans: 2))
        let sensorRich = height(SensorsWindowMetrics.rowCount(temperatures: 20, fans: 2))
        #expect(simulated == 377, "185 pt of chrome and slack, plus eight 24 pt rows")
        #expect(sensorRich == 713, "the same chrome, plus twenty-two rows")
        #expect(simulated < 480, "the simulated list used to open at a fixed 480 pt")
        #expect(sensorRich > 480, "and twenty-two rows never fitted in 480 pt")
        #expect(sensorRich - simulated == 14 * oneRow, "fourteen extra sensors, fourteen extra rows")
    }

    /// Before the first poll the count is unknown, and unknown must not be read
    /// as "this Mac has no sensors" — macOS saves a window's frame the first
    /// time it opens, so one unlucky open inside that gap would pin the floor
    /// permanently. The fallback is deliberately close to the fixed 480 pt this
    /// whole type replaced: no worse than what came before.
    @Test("An unknown sensor count opens near the old fixed height, not at the floor")
    func theUnmeasuredCaseIsNotTheEmptyCase() {
        #expect(height(nil) == 473)
        #expect(height(nil) > SensorsWindowMetrics.minimumFrameHeight)
        #expect(height(nil) == height(SensorsWindowMetrics.unmeasuredRowCount))
        #expect(height(nil) > height(SensorsWindowMetrics.rowCount(temperatures: 0, fans: 0)))
    }

    /// One sensor is one row of window. Below six rows the floor takes over,
    /// hence the starting index.
    @Test("Each extra sensor adds exactly one row of height")
    func heightGrowsOneRowAtATime() {
        for rows in 6 ..< 24 {
            #expect(height(rows + 1) - height(rows) == oneRow)
        }
    }

    @Test("Height never shrinks as the list grows")
    func monotonic() {
        for rows in 0 ..< 200 {
            #expect(height(rows + 1, screen: 900) >= height(rows, screen: 900))
        }
    }

    // MARK: The clamps

    @Test("A fanless Mac with no recognized sensors still opens a usable window")
    func theFloorHolds() {
        let rows = SensorsWindowMetrics.rowCount(temperatures: 0, fans: 0)
        #expect(height(rows) == SensorsWindowMetrics.minimumFrameHeight)
    }

    /// A content minimum overrides `.defaultSize` upward and there is no
    /// warning when it does — the old 440 pt floor turned a requested 365 pt
    /// window into 472. `SensorsBrowserView` therefore takes its floor from
    /// this type instead of choosing one, and this is the assertion that keeps
    /// the derivation honest if either number is ever edited.
    @Test("The view's minimum never vetoes the smallest window we open")
    func contentFloorFitsInsideTheWindowFloor() {
        #expect(
            SensorsWindowMetrics.minimumContentHeight + SensorsWindowMetrics.titleBarHeight
                <= height(0)
        )
    }

    /// A Mac whose sensors are enumerated rather than curated wants a window
    /// several times taller than the display it is on.
    @Test("A 50-sensor Mac caps out instead of running off the screen")
    func theScreenCapHolds() {
        let rows = SensorsWindowMetrics.rowCount(temperatures: 50, fans: 4)
        #expect(height(rows, screen: 900) < 900)
        #expect(height(rows, screen: .infinity) == SensorsWindowMetrics.maximumFrameHeight)
    }

    /// The inverted-range trap: clamp a value to `[floor, ceiling]` where the
    /// screen has pushed the ceiling below the floor and the result is a window
    /// smaller than the minimum that was just promised. Cheap to write, and the
    /// only way to hit it in the field is on hardware nobody here owns.
    @Test("An absurdly small screen still yields a usable window")
    func aTinyScreenCannotInvertTheClamp() {
        for screen in [CGFloat.zero, 100, 200, 400] {
            #expect(height(40, screen: screen) >= SensorsWindowMetrics.minimumFrameHeight)
        }
    }

    /// A NaN screen height must not collapse the window to the floor — and the
    /// only thing standing between it and that outcome is the argument order
    /// inside `min`, since `min(x, y)` is `y < x ? y : x` and therefore returns
    /// `x` for a NaN `y` but NaN for a NaN `x`. Nothing about swapping two
    /// arguments looks like a behaviour change, which is exactly why this is a
    /// test and not a comment.
    @Test("A nonsense screen height falls back to the cap, not to the floor")
    func nanCannotPoisonTheClamp() {
        for screen in [CGFloat.nan, .signalingNaN, .infinity] {
            #expect(height(40, screen: screen) == SensorsWindowMetrics.maximumFrameHeight)
        }
        #expect(height(nil, screen: .nan) == 473, "and it leaves smaller windows alone")
    }
}

/// The popover has no height discipline of its own, and neither hosting mode
/// degrades usefully when the list outgrows the screen. Measured on macOS 26.4
/// at 193 sensors: SwiftUI's `MenuBarExtra` did not clamp at all — a 380×3113
/// window whose bottom edge sat 1985 pt below a 1130 pt display, taking the
/// footer with it. Ice Cube has no Dock icon, so that footer holds the only
/// Quit; in the default configuration it leaves the screen at 29 sensors, and
/// this Mac reports 20.
@MainActor
@Suite("SensorListMetrics — the popover's sensor list stays inside the screen")
struct SensorListMetricsTests {
    private func layout(_ count: Int, screen: CGFloat = 1130) -> SensorListMetrics.Layout {
        SensorListMetrics.layout(sensorCount: count, availableHeight: screen)
    }

    /// A curated Mac shows its whole list, exactly, with no scroller and no
    /// "N total" chip — the common case must look untouched.
    @Test("A curated Mac's list fits and does not scroll")
    func curatedListFitsExactly() {
        let twenty = layout(20)
        #expect(!twenty.scrolls)
        #expect(twenty.height == SensorListMetrics.contentHeight(sensorCount: 20))
    }

    /// The case that took the Quit button off screen.
    @Test("A Mac that enumerates its sensors scrolls instead of growing")
    func enumeratedListScrolls() {
        let many = layout(193)
        #expect(many.scrolls)
        #expect(many.height <= SensorListMetrics.maximumListHeight)
        #expect(
            many.height + SensorListMetrics.popoverChrome <= 1130,
            "the whole popover has to fit the screen it hangs on"
        )
    }

    /// `SensorStabilizer` makes the list monotone: it grows 8 → 20 rows over
    /// ~85 s as power-gated clusters wake. Reserving from the inventory is what
    /// stops that growth resizing the popover under the user's cursor — the
    /// exact jump `SensorStabilizer` exists to prevent.
    @Test("Height is reserved from the inventory, so late sensors do not resize the popover")
    func lateSensorsDoNotResize() {
        #expect(layout(20).height == layout(20).height)
        let atLaunch = layout(20) // inventory known, only 8 reporting
        let laterOn = layout(20) // all 20 reporting
        #expect(atLaunch == laterOn, "the same inventory must give the same height throughout")
    }

    @Test("A tiny screen still yields a usable list, and a NaN one never collapses it")
    func clampsCannotInvertOrBePoisoned() {
        for screen in [CGFloat.zero, 100, 400, 700] {
            #expect(layout(20, screen: screen).height >= SensorListMetrics.minimumListHeight)
        }
        for screen in [CGFloat.nan, .signalingNaN, .infinity] {
            #expect(layout(50, screen: screen).height == SensorListMetrics.maximumListHeight)
        }
    }

    /// Simulated mode is the project's demonstrable baseline, so it must look
    /// identical before and after this change.
    @Test("Simulated mode's six sensors are unchanged")
    func simulatedModeIsUntouched() {
        let six = layout(6)
        #expect(!six.scrolls)
        #expect(six.height == SensorListMetrics.minimumListHeight)
    }

    @Test("No sensors reserves nothing rather than a floor of blank space")
    func emptyListReservesNothing() {
        #expect(SensorListMetrics.contentHeight(sensorCount: 0) == 0)
    }
}

@MainActor
@Suite("Sensors window — the decisions section")
struct SensorsWindowDecisionMetricsTests {
    private func height(_ rows: Int, decisions: Bool) -> CGFloat {
        SensorsWindowMetrics.frameHeight(
            rowCount: rows, availableHeight: 1200, hasDecisions: decisions
        )
    }

    /// The regression this suite exists to stop happening twice.
    ///
    /// The decision timeline was added to the Sensors window as a third
    /// `Section` without telling the arithmetic, so the window asked for a
    /// height that omitted a 28 pt header, a 20 pt gap and the whole timeline —
    /// and macOS saves the frame of a window the first time it opens.
    @Test("A visible decisions section is paid for in the window height")
    func decisionsCostHeight() {
        #expect(
            height(8, decisions: true) - height(8, decisions: false)
                == SensorsWindowMetrics.decisionChrome(hasDecisions: true)
        )
        // Typed: `#expect(aCGFloat == 28 + 20 + 88)` infers Int on the right and
        // compares through AnyHashable, which is false even at equal values.
        let expected: CGFloat = 28 + 20 + 88
        #expect(SensorsWindowMetrics.decisionChrome(hasDecisions: true) == expected)
    }

    /// A fresh install has made no decisions. Charging it for an empty box
    /// would shrink the sensor list to display nothing.
    @Test("An absent decisions section costs nothing")
    func noDecisionsCostNothing() {
        #expect(SensorsWindowMetrics.decisionChrome(hasDecisions: false) == 0)
        // Row counts chosen so neither clamp binds at either setting — the
        // clamps are the subject of `respectsCeiling` and `sensorRichClamps`,
        // and folding them in here would let a clamp bug hide as an
        // arithmetic pass.
        let unclamped: CGFloat = 136
        for rows in [8, 12, 20] {
            #expect(height(rows, decisions: true) - height(rows, decisions: false) == unclamped)
        }
    }

    /// Worth stating outright, because it is a real consequence rather than an
    /// edge case: on the owner's M2 Pro (22 temperatures + 2 fans = 24 rows) a
    /// visible timeline pushes the wanted height past `maximumFrameHeight`, so
    /// the window opens at the cap and the list scrolls. That is the correct
    /// trade — the cap exists to keep the window on screen — but it means the
    /// timeline is not free on sensor-rich Macs, which is exactly why
    /// `decisionSectionHeight` is 88 and not 120.
    @Test("On a sensor-rich Mac the timeline pushes the window to its ceiling")
    func sensorRichClamps() {
        #expect(height(24, decisions: false) < SensorsWindowMetrics.maximumFrameHeight)
        #expect(height(24, decisions: true) == SensorsWindowMetrics.maximumFrameHeight)
    }

    /// The section is fixed-height on purpose: it scrolls internally, so 500
    /// retained decisions cost exactly as much window as one does. Without
    /// that, no arithmetic here could be correct.
    @Test("The timeline's cost does not depend on how many decisions there are")
    func fixedRegardlessOfCount() {
        #expect(SensorsWindowMetrics.decisionSectionHeight == 88)
    }

    /// The ceiling still wins — a sensor-rich Mac with a timeline must not
    /// produce a window taller than the screen allows.
    @Test("The decisions section cannot push the window past its ceiling")
    func respectsCeiling() {
        #expect(height(40, decisions: true) <= SensorsWindowMetrics.maximumFrameHeight)
        #expect(
            SensorsWindowMetrics.frameHeight(rowCount: 40, availableHeight: 600, hasDecisions: true)
                <= 600 - 24
        )
    }
}
