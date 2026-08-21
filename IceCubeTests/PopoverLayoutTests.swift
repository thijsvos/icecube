// PopoverLayoutTests.swift — the footer stays reachable however tall the content gets.

import Foundation
import Testing

/// The bug this suite exists for, measured rather than reasoned about.
///
/// On the reporting machine the popover came out **1216 pt** in **1130 pt** of
/// visible screen, hanging from y=41, so the bottom 127 pt — the divider, the
/// update row and the whole footer — were off the edge with no scroll bar to
/// reach them. Settings and Quit were simply gone.
///
/// The first attempt at this bug added the Inside card's 240 pt to
/// `SensorListMetrics.popoverChrome`, which shrank the sensor list by 137 pt
/// and changed nothing the user could see. That is the tell: the popover's
/// height is not a constant plus a list, it is a stack of user-chosen cards.
/// Six chart series at up to 92 pt each, an opt-in 240 pt schematic. No
/// arithmetic over the *content* can promise the footer survives, so the footer
/// stopped being content.
@Suite("PopoverLayout — the footer is never the part that falls off")
struct PopoverLayoutTests {
    /// The measurement from the machine that reported it.
    private static let reportedContent: CGFloat = 1216 - 96
    private static let reportedFooter: CGFloat = 96
    private static let reportedScreen: CGFloat = 1130

    @Test("Content that fits is left alone, so a small popover stays small")
    func shortContentIsUnconstrained() {
        #expect(
            PopoverLayout.scrollHeight(contentHeight: 300, footerHeight: 96, availableHeight: 1130) == nil,
            "a 300 pt popover on a 1130 pt screen must not be stretched to fill it"
        )
    }

    /// The regression, in the numbers it was reported in.
    @Test("The reported 1216 pt popover is capped so the footer survives")
    func theReportedOverflowIsCapped() throws {
        let height = PopoverLayout.scrollHeight(
            contentHeight: Self.reportedContent,
            footerHeight: Self.reportedFooter,
            availableHeight: Self.reportedScreen
        )
        let scroll = try #require(height)
        #expect(scroll < Self.reportedContent, "it has to give way somewhere")
        #expect(
            scroll + Self.reportedFooter + PopoverLayout.bottomMargin <= Self.reportedScreen,
            "the whole popover, footer included, has to be on the screen"
        )
    }

    /// The property that makes this structural rather than arithmetic: it holds
    /// for content of *any* height, including heights no current combination of
    /// settings can produce. That is the point — the previous fix was correct
    /// for the configurations it was measured against and wrong for the one the
    /// user had.
    @Test(
        "However tall the content, the popover fits and the footer is on screen",
        arguments: [400.0, 900.0, 1120.0, 1216.0, 2000.0, 5000.0]
    )
    func anyContentHeightLeavesTheFooterReachable(content: Double) {
        for screen in [CGFloat(1130), 900, 1400, 1800] {
            for footer in [CGFloat(60), 96, 140] {
                let scroll = PopoverLayout.scrollHeight(
                    contentHeight: CGFloat(content),
                    footerHeight: footer,
                    availableHeight: screen
                ) ?? CGFloat(content)
                let total = scroll + footer
                let fits = total <= screen || scroll == PopoverLayout.minimumScrollHeight
                #expect(fits, "content \(content) on \(Double(screen)) pt: popover \(Double(total)) pt")
            }
        }
    }

    /// `SensorListMetrics` learned this the hard way and this type inherits the
    /// lesson: a poisoned screen height must not collapse the popover.
    @Test("No screen, or a poisoned one, leaves the content unconstrained")
    func noScreenMeansNoConstraint() {
        for screen in [CGFloat.infinity, .nan, .signalingNaN] {
            #expect(
                PopoverLayout.scrollHeight(contentHeight: 4000, footerHeight: 96, availableHeight: screen) == nil,
                "a popover must never be sized from a number that is not one"
            )
        }
    }

    @Test("Before the first measurement arrives nothing is constrained")
    func zeroContentIsUnconstrained() {
        #expect(PopoverLayout.scrollHeight(contentHeight: 0, footerHeight: 96, availableHeight: 1130) == nil)
    }
}
