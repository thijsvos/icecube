// InsideTileLayout.swift — what goes in one temperature tile, and where, at whatever size it is.

import Foundation

/// The contents of a single tile: an icon, a reading, a label — or as many of
/// those as will fit.
///
/// **Extracted because the version inlined in the drawing overlapped and no test
/// could see it.** At popover size a silicon tile is around 39 pt tall, and the
/// first compact form stacked a 13 pt reading and a 9 pt label at fixed
/// fractions of the height (0.53 and 0.81). Those spans intersect, so the
/// temperature was drawn through the word "CPU".
///
/// Two decisions live here, and both are testable now: how many elements a tile
/// can hold at a given scale, and where they sit. The drawing just renders what
/// it is handed.
struct InsideTileLayout {
    /// One thing to draw, and the size to draw it at.
    struct Element: Equatable {
        /// Centre, as an offset from the tile's top edge.
        let y: CGFloat
        let fontSize: CGFloat

        /// The vertical span the glyphs actually occupy. 1.2 × point size is the
        /// usual approximation for cap height plus descender.
        var span: ClosedRange<CGFloat> {
            let half = fontSize * 0.6
            return (y - half) ... (y + half)
        }
    }

    let icon: Element?
    let value: Element
    let label: Element?

    /// Below this scale a tile holds two things rather than three.
    static let threeElementScale: CGFloat = 0.6

    /// - Parameters:
    ///   - prominent: silicon tiles, which are larger and keep their label.
    ///
    /// Each kind keeps whichever pair identifies it best when one has to go:
    /// "CPU" beats a chip glyph, and a battery glyph beats "Battery 1" squeezed
    /// into 38 pt — which is what the icons were added for in the first place.
    init(height: CGFloat, scale: CGFloat, prominent: Bool) {
        let roomForThree = scale > Self.threeElementScale
        let showsLabel = prominent || roomForThree
        let showsIcon = !prominent || roomForThree
        let rows = (showsIcon ? 1 : 0) + 1 + (showsLabel ? 1 : 0)

        /// Evenly spaced bands, so two elements centre themselves instead of
        /// leaving a hole where the third used to be.
        func band(_ index: Int) -> CGFloat {
            height * (CGFloat(index) + 0.5) / CGFloat(rows)
        }

        var slot = 0
        if showsIcon {
            icon = Element(y: band(slot), fontSize: (prominent ? 15 : 12) * scale)
            slot += 1
        } else {
            icon = nil
        }
        value = Element(y: band(slot), fontSize: (prominent ? 25 : 19) * scale)
        slot += 1
        label = showsLabel
            ? Element(y: band(slot), fontSize: max(9, (prominent ? 11 : 10) * scale))
            : nil
    }

    /// Everything actually drawn, top to bottom.
    var elements: [Element] {
        [icon, value, label].compactMap(\.self)
    }

    /// Whether any two of them would touch. The whole point of the type.
    var hasOverlap: Bool {
        zip(elements, elements.dropFirst()).contains { $0.span.upperBound > $1.span.lowerBound }
    }
}
