#!/bin/sh
# generate-icon.sh — renders the Ice Cube app icon (melting ice cube on icy gradient) into AppIcon.icns.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/AppIcon.iconset IceCube/Resources
swift - <<'EOF'
import AppKit

let entries: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in entries {
    let px = entry.px
    let size = NSSize(width: px, height: px)
    let image = NSImage(size: size)
    image.lockFocus()

    // macOS-style rounded square with a teal→deep-blue gradient.
    let inset = CGFloat(px) * 0.05
    let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.75, green: 0.93, blue: 1.0, alpha: 1),  // pale ice
        NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.85, alpha: 1), // glacial blue
    ])!.draw(in: path, angle: -70)

    // A glossy isometric ice cube that is MELTING — faceted faces (so it
    // reads as a cube, not a blob), plus two drips and a puddle. Drawn by
    // hand: original art, no third-party license to carry into an MIT app.
    func poly(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        let scaled = pts.map { NSPoint(x: $0.0 * CGFloat(px), y: $0.1 * CGFloat(px)) }
        path.move(to: scaled[0])
        for pt in scaled.dropFirst() { path.line(to: pt) }
        path.close()
        return path
    }
    func drip(_ x: CGFloat, _ topY: CGFloat, _ w: CGFloat, _ len: CGFloat) -> NSBezierPath {
        poly([(x - w, topY), (x + w, topY), (x + w * 0.5, topY - len * 0.5),
              (x, topY - len), (x - w * 0.5, topY - len * 0.5)])
    }
    let p = CGFloat(px)
    // Puddle + drips (behind the cube).
    NSColor(calibratedWhite: 1.0, alpha: 0.5).set()
    NSBezierPath(ovalIn: NSRect(x: 0.16 * p, y: 0.10 * p, width: 0.56 * p, height: 0.13 * p)).fill()
    NSColor(calibratedRed: 0.85, green: 0.95, blue: 1.0, alpha: 0.95).set()
    drip(0.30, 0.31, 0.045, 0.14).fill()
    drip(0.66, 0.31, 0.05, 0.20).fill()
    // Cube faces: top lightest, left mid, right darkest.
    let top = poly([(0.50, 0.82), (0.79, 0.67), (0.50, 0.54), (0.21, 0.67)])
    let left = poly([(0.21, 0.67), (0.50, 0.54), (0.50, 0.25), (0.21, 0.38)])
    let right = poly([(0.50, 0.54), (0.79, 0.67), (0.79, 0.38), (0.50, 0.25)])
    NSColor(calibratedRed: 0.95, green: 0.99, blue: 1.00, alpha: 0.97).set(); top.fill()
    NSColor(calibratedRed: 0.62, green: 0.85, blue: 0.99, alpha: 0.95).set(); left.fill()
    NSColor(calibratedRed: 0.38, green: 0.68, blue: 0.95, alpha: 0.95).set(); right.fill()
    NSColor(calibratedWhite: 1.0, alpha: 0.85).set()
    for path in [top, left, right] {
        path.lineWidth = p * 0.012
        path.stroke()
    }
    // Shine on the top face.
    NSColor(calibratedWhite: 1.0, alpha: 0.8).set()
    NSBezierPath(ovalIn: NSRect(x: 0.40 * p, y: 0.63 * p, width: 0.09 * p, height: 0.06 * p)).fill()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("render failed at \(px)px")
    }
    try! png.write(to: URL(fileURLWithPath: "build/AppIcon.iconset/\(entry.name).png"))
}
print("iconset rendered")
EOF
iconutil -c icns build/AppIcon.iconset -o IceCube/Resources/AppIcon.icns
echo "AppIcon.icns generated"
