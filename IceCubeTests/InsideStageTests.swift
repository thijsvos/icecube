// InsideStageTests.swift — the schematic's geometry, at every size it is actually asked for.

import Foundation
import IceCubeKit
import SwiftUI
import Testing

/// Pins that the layout is usable at the sizes it is used at.
///
/// **Written after the compact form shipped drawing nothing.** `InsideView`
/// opened with `guard chassis.width > 240, chassis.height > 170`, which are the
/// window's dimensions. The popover asks for the same drawing at 210 pt tall,
/// which produces a 224 × 158 chassis — under that floor, so `draw` returned
/// immediately and the popover showed an empty card. Nothing failed; it just
/// did not appear.
///
/// The floor now lives on ``InsideStage`` and these run at the real sizes.
@MainActor
@Suite("InsideStage — usable at every size it is asked for")
struct InsideStageTests {
    /// Built from the real constants, not from numbers copied out of them.
    ///
    /// The first version of this file wrote `210` as a literal, and so kept
    /// passing when the floor was mutated back to the window-sized one that had
    /// caused the bug — because the height had *also* been raised, and 253 × 178
    /// happens to clear 240 × 170. A test that restates a constant is testing
    /// its own arithmetic.
    private static let popoverCanvas = CGSize(
        width: Theme.Metrics.popoverWidth - Theme.Metrics.cardPadding * 2,
        height: InsideStage.popoverHeight
    )
    private static let windowCanvas = CGSize(width: 620, height: 460)

    @Test("Both the popover and the window produce a drawable stage")
    func bothPresentationsAreDrawable() {
        for (name, canvas) in [("popover", Self.popoverCanvas), ("window", Self.windowCanvas)] {
            let stage = InsideStage(canvas: canvas, blowerCount: 2)
            #expect(
                stage.isDrawable,
                "\(name) at \(canvas) gives \(stage.chassis.size), under the \(InsideStage.minimumDrawable) floor"
            )
        }
    }

    /// **The assertion that would actually have caught the bug**, and the one
    /// the first draft of this file was missing.
    ///
    /// "The popover clears the floor" is not enough: it cleared the broken
    /// floor too, once the height had been nudged up. What matters is that the
    /// floor is a long way below the smallest size really used, so that neither
    /// a smaller popover nor a raised floor can quietly meet in the middle
    /// again.
    @Test("The drawable floor sits well below the smallest size actually used")
    func theFloorHasRealMargin() {
        let smallest = InsideStage(canvas: Self.popoverCanvas, blowerCount: 2).chassis
        #expect(
            InsideStage.minimumDrawable.width < smallest.width * 0.7,
            "floor \(Double(InsideStage.minimumDrawable.width)) against a real \(Double(smallest.width))"
        )
        #expect(
            InsideStage.minimumDrawable.height < smallest.height * 0.7,
            "floor \(Double(InsideStage.minimumDrawable.height)) against a real \(Double(smallest.height))"
        )
    }

    /// The failure was not a crash — every region was computed, the drawing just
    /// never ran. So the property worth pinning is that each region has real
    /// area at the small size, not merely that a chassis exists.
    @Test("Every region has real area at popover size")
    func regionsAreNotDegenerateWhenCompact() {
        let stage = InsideStage(canvas: Self.popoverCanvas, blowerCount: 2)
        let regions: [(String, CGRect)] = [
            ("chassis", stage.chassis),
            ("logicBoard", stage.logicBoard),
            ("siliconRow", stage.siliconRow),
            ("componentBay", stage.componentBay),
            ("componentRow", stage.componentRow),
            ("frontNotch", stage.frontNotch),
        ]
        for (name, rect) in regions {
            #expect(rect.width > 0 && rect.height > 0, "\(name) is \(rect.size) at popover size")
        }
        #expect(stage.blowers.count == 2)
        #expect(stage.fins.count == 2)
        #expect(stage.blowers.allSatisfy { $0.width > 4 }, "a blower must be big enough to see")
    }

    /// Tiles are laid out from the row, so a row too narrow for its contents is
    /// where the compact form would next go wrong.
    @Test("Four component tiles still fit their row at popover size")
    func componentTilesFitWhenCompact() {
        let stage = InsideStage(canvas: Self.popoverCanvas, blowerCount: 2)
        let slots = stage.slots(in: stage.componentRow, count: 4, maxWidth: 92, maxHeight: 66)
        #expect(slots.count == 4)
        #expect(slots.allSatisfy { $0.width >= 20 }, "got \(slots.map { Double($0.width) })")
        // Laid out left to right, and none overlapping.
        for (left, right) in zip(slots, slots.dropFirst()) {
            #expect(left.maxX <= right.minX, "tiles overlap: \(left) then \(right)")
        }
        // Rect-in-rect with a half-point tolerance, not `contains(origin)`.
        // The tile is centred with `row.midY - height / 2`, which for a tile as
        // tall as its row lands a floating-point hair either side of
        // `row.minY` — so testing a corner point tested the rounding, not the
        // layout.
        let bounds = stage.componentRow.insetBy(dx: -0.5, dy: -0.5)
        for slot in slots {
            #expect(bounds.contains(slot), "\(slot) escaped \(stage.componentRow)")
        }
    }

    /// The overlap this was written for: at popover size the silicon row was
    /// 27.6 pt tall — `logicBoard` is 29 % of a 178 pt chassis, then inset by a
    /// flat 12 pt top and bottom — and the drawing stacked a 13 pt reading and a
    /// 9 pt label in it. They ran into each other, on top of the word.
    @Test("Every tile row can hold a reading and a label without them touching")
    func rowsAreTallEnoughForTwoLines() {
        for (name, canvas) in [("popover", Self.popoverCanvas), ("window", Self.windowCanvas)] {
            let stage = InsideStage(canvas: canvas, blowerCount: 2)
            let needed = stage.minimumRowHeightForTwoLines
            #expect(
                stage.siliconRow.height >= needed,
                "\(name): silicon row \(Double(stage.siliconRow.height)) < \(Double(needed))"
            )
            #expect(
                stage.componentRow.height >= needed,
                "\(name): component row \(Double(stage.componentRow.height)) < \(Double(needed))"
            )
        }
    }

    /// Type shrinks with the drawing, but only so far — below the floor a
    /// reading stops being readable, which is worse than a tile that crops.
    @Test("Type scale tracks the drawing and never falls through its floor")
    func typeScaleHasAFloor() {
        let popover = InsideStage(canvas: Self.popoverCanvas, blowerCount: 2)
        let window = InsideStage(canvas: Self.windowCanvas, blowerCount: 2)
        #expect(popover.typeScale >= 0.52)
        #expect(popover.typeScale < window.typeScale, "the compact form must use smaller type")
        #expect(window.typeScale <= 1, "and the window must never scale type up")
    }

    /// A window dragged to nothing must refuse rather than draw a smear — the
    /// floor has a job, it was just set to the wrong number.
    @Test("A genuinely tiny canvas is still refused")
    func degenerateCanvasIsRefused() {
        #expect(!InsideStage(canvas: CGSize(width: 80, height: 60), blowerCount: 2).isDrawable)
        #expect(!InsideStage(canvas: .zero, blowerCount: 2).isDrawable)
    }
}
