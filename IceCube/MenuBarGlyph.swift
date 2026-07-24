// MenuBarGlyph.swift — the menu-bar icon: an original melting-ice-cube silhouette drawn as a template image.

import AppKit

/// The menu-bar status glyph: a small isometric ice cube with two drips and a
/// puddle. Drawn in code as a monochrome **template image** (the system tints
/// it for light/dark), so it stays a crisp brand mark at ~16 pt.
///
/// Why not an SF Symbol or a downloaded icon: there is no ice-cube SF Symbol,
/// and third-party icons carry attribution/redistribution licenses that an
/// MIT app shouldn't inherit. This is original art — brand-consistent with the
/// app icon, and unambiguously "a cube" rather than a temperature symbol (the
/// snowflake it replaced read as a live "it's cold" status, which it never was).
enum MenuBarGlyph {
    /// A 18×18 template image of the melting ice cube.
    static let iceCube: NSImage = {
        let px: CGFloat = 18
        let image = NSImage(size: NSSize(width: px, height: px), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setLineJoin(.round)
            ctx.setFillColor(NSColor.black.cgColor)

            func fill(_ pts: [(CGFloat, CGFloat)]) {
                ctx.move(to: CGPoint(x: pts[0].0 * px, y: pts[0].1 * px))
                for p in pts.dropFirst() {
                    ctx.addLine(to: CGPoint(x: p.0 * px, y: p.1 * px))
                }
                ctx.closePath()
                ctx.fillPath()
            }
            func drip(_ x: CGFloat, _ topY: CGFloat, _ w: CGFloat, _ len: CGFloat) -> [(CGFloat, CGFloat)] {
                [
                    (x - w, topY),
                    (x + w, topY),
                    (x + w * 0.5, topY - len * 0.5),
                    (x, topY - len),
                    (x - w * 0.5, topY - len * 0.5),
                ]
            }

            // Solid cube silhouette (outer hexagon) + puddle + two drips.
            fill([(0.50, 0.82), (0.79, 0.67), (0.79, 0.38), (0.50, 0.25), (0.21, 0.38), (0.21, 0.67)])
            ctx.fillEllipse(in: CGRect(x: 0.16 * px, y: 0.10 * px, width: 0.56 * px, height: 0.13 * px))
            fill(drip(0.30, 0.31, 0.05, 0.14))
            fill(drip(0.66, 0.31, 0.055, 0.20))

            // Punch out the three facet edges so it reads as a 3D cube, not a blob.
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(px * 0.045)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 0.50 * px, y: 0.82 * px)); ctx.addLine(to: CGPoint(x: 0.50 * px, y: 0.54 * px))
            ctx.addLine(to: CGPoint(x: 0.21 * px, y: 0.67 * px))
            ctx.move(to: CGPoint(x: 0.50 * px, y: 0.54 * px)); ctx.addLine(to: CGPoint(x: 0.79 * px, y: 0.67 * px))
            ctx.move(to: CGPoint(x: 0.50 * px, y: 0.54 * px)); ctx.addLine(to: CGPoint(x: 0.50 * px, y: 0.25 * px))
            ctx.strokePath()
            return true
        }
        image.isTemplate = true // let the menu bar tint it for light/dark
        return image
    }()
}
