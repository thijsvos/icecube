// InsideTileLayoutTests.swift — the tile's contents never overlap, at any size it is drawn at.

import Foundation
import IceCubeKit
import Testing

/// The bug this exists for: at popover size the reading was drawn through the
/// word "CPU".
///
/// The layout was inline in the drawing, at fixed fractions of the tile height
/// (0.22 / 0.53 / 0.81) chosen against the window's 82 pt tile. A popover tile
/// is around 39 pt, so a 13 pt reading spanning y≈8–21 and a 9 pt label
/// spanning y≈18–27 ran into each other. Nothing could see it but a person.
@MainActor
@Suite("InsideTileLayout — a tile's contents never touch")
struct InsideTileLayoutTests {
    /// Real geometry, from the real stage, at both sizes it is asked for.
    private static func stages() -> [(String, InsideStage)] {
        [
            ("popover", InsideStage(
                canvas: CGSize(
                    width: Theme.Metrics.popoverWidth - Theme.Metrics.cardPadding * 2,
                    height: InsideStage.popoverHeight
                ),
                blowerCount: 2
            )),
            ("window", InsideStage(canvas: CGSize(width: 620, height: 460), blowerCount: 2)),
        ]
    }

    @Test("Nothing overlaps in either presentation, for either kind of tile")
    func noOverlapAtAnyRealSize() {
        for (name, stage) in Self.stages() {
            for (kind, row, prominent) in [
                ("silicon", stage.siliconRow, true),
                ("component", stage.componentRow, false),
            ] {
                let height = stage.slots(in: row, count: 2, maxWidth: 104, maxHeight: 82)
                    .first?.height ?? row.height
                let tile = InsideTileLayout(height: height, scale: stage.typeScale, prominent: prominent)
                #expect(
                    !tile.hasOverlap,
                    "\(name)/\(kind) at \(Double(height)) pt: \(tile.elements.map { Double($0.y) })"
                )
            }
        }
    }

    /// The exact geometry that shipped broken, as a regression case rather than
    /// as a derived one — so it keeps failing even if the stage changes.
    @Test("The 39 pt silicon tile that shipped overlapping no longer does")
    func theTileThatShippedBroken() {
        let broken = InsideTileLayout(height: 39, scale: 0.52, prominent: true)
        #expect(!broken.hasOverlap, "elements at \(broken.elements.map { Double($0.y) })")
        #expect(broken.icon == nil, "three things do not fit in 39 pt; the icon is what goes")
        #expect(broken.label != nil, "\"CPU\" is what identifies a silicon tile — it must stay")
    }

    /// Each kind keeps whichever of the two identifies it best when one has to
    /// go, which is the whole reason the icons were added.
    @Test("When only two fit, silicon keeps its word and a component keeps its icon")
    func eachKindKeepsWhatIdentifiesIt() {
        let silicon = InsideTileLayout(height: 39, scale: 0.52, prominent: true)
        #expect(silicon.label != nil && silicon.icon == nil)
        let component = InsideTileLayout(height: 40, scale: 0.52, prominent: false)
        #expect(component.icon != nil && component.label == nil)
    }

    @Test("At window scale a tile shows all three, still without touching")
    func windowShowsEverything() {
        let full = InsideTileLayout(height: 82, scale: 1, prominent: true)
        #expect(full.icon != nil && full.label != nil)
        #expect(!full.hasOverlap)
        #expect(full.elements.count == 3)
    }

    /// Whatever the size, the order on screen is icon, reading, label.
    @Test("Elements stay in order and inside the tile", arguments: [30.0, 39.0, 55.0, 82.0, 120.0])
    func elementsStayOrderedAndInside(_ height: Double) {
        for scale in [0.52, 0.6, 0.75, 1.0] {
            for prominent in [true, false] {
                let tile = InsideTileLayout(height: height, scale: scale, prominent: prominent)
                let ys = tile.elements.map(\.y)
                #expect(ys == ys.sorted(), "out of order at \(height)/\(scale): \(ys.map(Double.init))")
                #expect(ys.allSatisfy { $0 >= 0 && $0 <= height }, "escaped the tile at \(height)/\(scale)")
            }
        }
    }
}
