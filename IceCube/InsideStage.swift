// InsideStage.swift — where every part of the cooling schematic sits, for a given canvas size.

import Foundation
import IceCubeKit

/// The geometry of the drawing, computed once per frame.
///
/// **Top-down, oriented the way the machine on the desk is oriented**: hinge
/// and exhaust at the top, front edge nearest you at the bottom, and fan 0
/// ("Left" in `F{i}ID`) drawn on the left. So "the left fan is louder" means
/// the one on your left.
///
/// Getting there took three tries and the two failures are worth recording,
/// because both were the same mistake. The first two versions put the blowers
/// side by side near the middle of the upper area with a curved heat pipe slung
/// between them, and both read as a **face** — two eyes and a smile. Shrinking
/// the circles and re-routing the pipe did not help. Then the layout was turned
/// on its side into a left-to-right flow, which killed the face and lost the
/// point: a diagram of a laptop should be oriented like the laptop.
///
/// What actually fixes it is drawing the machine truthfully rather than
/// symmetrically:
/// 1. **The blowers go to the far corners**, where they physically are — about
///    70 % of the width apart. Eyes sit a third of a face apart; at this
///    spacing the pair stops reading as a pair.
/// 2. **The silicon lives inside a drawn logic board.** A bordered rectangle
///    reads as a circuit board; two floating blocks under two circles read as
///    a mouth.
/// 3. **The fin stacks are wide bars along the back edge**, which puts a strong
///    horizontal line above everything and breaks the vertical symmetry.
/// 4. **Nothing is curved.** The heat pipe runs straight, the way a vapour
///    chamber does.
struct InsideStage {
    /// Beyond this the diagram gains margin, not size.
    static let maximumWidth: CGFloat = 700
    /// A 14-inch deck is about 31 × 22 cm. Keeping the real proportion is both
    /// truthful and the reason the drawing has room for a board and a battery
    /// bay instead of a lake of empty middle.
    static let aspect: CGFloat = 1.42
    /// Blowers stay small: they are the least informative element on screen,
    /// and a temperature is what someone opened the window to read.
    static let maximumBlowerRadius: CGFloat = 26

    let chassis: CGRect
    /// One fin stack per blower, along the back edge above it.
    let fins: [CGRect]
    /// One per fan, at the back corners, ordered as the fans are.
    let blowers: [CGRect]
    /// The logic board the silicon sits on.
    let logicBoard: CGRect
    /// Where the silicon blocks go, inside the board.
    let siliconRow: CGRect
    /// The front bay — battery and the other warm things that are not in the
    /// heat path.
    let componentBay: CGRect
    let componentRow: CGRect
    /// Intake slots down each side.
    let sideVents: [CGRect]
    /// The trackpad notch at the front, which is only there to make the
    /// orientation unambiguous at a glance.
    let frontNotch: CGRect

    init(canvas: CGSize, blowerCount: Int) {
        let available = CGRect(origin: .zero, size: canvas).insetBy(dx: 22, dy: 16)
        var width = min(available.width, Self.maximumWidth)
        var height = width / Self.aspect
        if height > available.height {
            height = available.height
            width = height * Self.aspect
        }
        // Everything below is derived from `shell`, a local — the nested
        // helpers would otherwise capture `self` before its stored properties
        // are initialised, which Swift refuses.
        let shell = CGRect(
            x: available.midX - width / 2,
            y: available.midY - height / 2,
            width: max(width, 1),
            height: max(height, 1)
        )
        chassis = shell

        func x(_ fraction: CGFloat) -> CGFloat {
            shell.minX + shell.width * fraction
        }
        func y(_ fraction: CGFloat) -> CGFloat {
            shell.minY + shell.height * fraction
        }

        let count = max(blowerCount, 0)
        let radius = min(Self.maximumBlowerRadius, shell.width * 0.045)
        var blowerFrames: [CGRect] = []
        var finFrames: [CGRect] = []
        for index in 0 ..< count {
            // Pushed out towards the corners: with two fans these land at 0.15
            // and 0.85, which is far too wide to read as a pair of eyes.
            let t = count == 1 ? 0.5 : 0.15 + 0.70 * CGFloat(index) / CGFloat(count - 1)
            let centreX = x(t)
            let centreY = y(0.235)
            blowerFrames.append(CGRect(
                x: centreX - radius, y: centreY - radius,
                width: radius * 2, height: radius * 2
            ))
            let finWidth = min(shell.width * 0.26, radius * 5)
            finFrames.append(CGRect(
                x: centreX - finWidth / 2, y: y(0.045),
                width: finWidth, height: max(14, shell.height * 0.075)
            ))
        }
        blowers = blowerFrames
        fins = finFrames

        logicBoard = CGRect(x: x(0.28), y: y(0.15), width: shell.width * 0.44, height: shell.height * 0.29)
        siliconRow = logicBoard.insetBy(dx: 10, dy: 12)

        componentBay = CGRect(x: x(0.08), y: y(0.53), width: shell.width * 0.84, height: shell.height * 0.30)
        componentRow = componentBay.insetBy(dx: 12, dy: 10)

        let ventHeight = shell.height * 0.16
        sideVents = [
            CGRect(x: x(0.018), y: y(0.30), width: 10, height: ventHeight),
            CGRect(x: x(0.982) - 10, y: y(0.30), width: 10, height: ventHeight),
        ]
        frontNotch = CGRect(x: x(0.36), y: y(0.90), width: shell.width * 0.28, height: shell.height * 0.055)
    }

    /// Evenly spaced frames along `row`, capped in both directions and centred
    /// vertically in it.
    ///
    /// Spread across the row rather than packed at its centre: a tight centred
    /// cluster is what made the components read as teeth.
    ///
    /// `maxHeight` exists because the blocks used to fill their row's whole
    /// height — on a normal window that meant a 98 pt tall tile wrapped around a
    /// 15 pt number, which is most of what made the drawing look cheap. A tile
    /// should hug what it contains.
    func slots(in row: CGRect, count: Int, maxWidth: CGFloat, maxHeight: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let width = max(38, min(maxWidth, row.width / CGFloat(count) - 10))
        let height = min(maxHeight, row.height)
        return (0 ..< count).map { index in
            let t = (CGFloat(index) + 0.5) / CGFloat(count)
            return CGRect(
                x: row.minX + row.width * t - width / 2,
                y: row.midY - height / 2, width: width, height: height
            )
        }
    }
}
