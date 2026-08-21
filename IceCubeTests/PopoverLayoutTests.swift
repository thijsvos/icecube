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

    private func presentation(
        content: CGFloat,
        footer: CGFloat = 96,
        screen: CGFloat = 1130
    ) -> PopoverLayout.Presentation {
        PopoverLayout.presentation(contentHeight: content, footerHeight: footer, availableHeight: screen)
    }

    /// **The regression that shipped in v0.4.2.** The cards were always wrapped
    /// in a `ScrollView`, and "everything fits" was expressed as a `nil` frame
    /// height. A scroll view has no intrinsic height, so an unconstrained one
    /// collapses to nothing: with Live charts and Inside off — the default —
    /// the popover drew its footer and no content whatsoever.
    ///
    /// It went unnoticed because the tall configuration takes the other branch
    /// and gets an explicit height, and the tall configuration was the only one
    /// measured. This is the assertion that says content which fits must never
    /// be handed to a scroll view.
    @Test(
        "Content that fits is drawn plainly, never in a scroll view",
        arguments: [1.0, 100.0, 300.0, 700.0, 1000.0]
    )
    func contentThatFitsIsNeverScrolled(content: Double) {
        #expect(
            presentation(content: CGFloat(content)) == .natural,
            "\(content) pt fits in 1130 and must render at its natural height"
        )
    }

    @Test("Before the first measurement the cards are drawn so they can measure themselves")
    func unmeasuredContentIsNatural() {
        #expect(presentation(content: 0) == .natural)
    }

    /// The bug this file was originally written for, in the numbers it was
    /// reported in.
    @Test("The reported 1216 pt popover scrolls so the footer survives")
    func theReportedOverflowScrolls() {
        guard case let .scrolling(height) = presentation(
            content: Self.reportedContent,
            footer: Self.reportedFooter,
            screen: Self.reportedScreen
        ) else {
            Issue.record("the popover that ran off the screen has to scroll")
            return
        }
        #expect(height < Self.reportedContent, "it has to give way somewhere")
        #expect(
            height + Self.reportedFooter + PopoverLayout.bottomMargin <= Self.reportedScreen,
            "the whole popover, footer included, has to be on the screen"
        )
    }

    /// The property that makes this structural rather than arithmetic: it holds
    /// for content of any height, including heights no current combination of
    /// settings can produce.
    @Test(
        "However tall the content, the popover fits and the footer is on screen",
        arguments: [400.0, 900.0, 1120.0, 1216.0, 2000.0, 5000.0]
    )
    func anyContentHeightLeavesTheFooterReachable(content: Double) {
        for screen in [CGFloat(1130), 900, 1400, 1800] {
            for footer in [CGFloat(60), 96, 140] {
                let scroll: CGFloat = switch presentation(content: CGFloat(content), footer: footer, screen: screen) {
                case .natural: CGFloat(content)
                case let .scrolling(height): height
                }
                let total = scroll + footer
                let fits = total <= screen || scroll == PopoverLayout.minimumScrollHeight
                #expect(fits, "content \(content) on \(Double(screen)) pt: popover \(Double(total)) pt")
            }
        }
    }

    /// `SensorListMetrics` learned this the hard way and this type inherits the
    /// lesson: a poisoned screen height must not collapse the popover.
    @Test("No screen, or a poisoned one, draws naturally rather than sizing from nonsense")
    func noScreenMeansNatural() {
        for screen in [CGFloat.infinity, .nan, .signalingNaN] {
            #expect(presentation(content: 4000, screen: screen) == .natural)
        }
    }
}
