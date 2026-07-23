#!/bin/sh
# generate-icon.sh — renders the Ice Cube app icon (ice cube glyph on icy gradient) into AppIcon.icns.
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

    // A glossy isometric ice cube, drawn by hand (an SF cube reads as a
    // plain geometric box — this one has faces, translucency, and shine).
    func poly(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
        let path = NSBezierPath()
        let scaled = pts.map { NSPoint(x: $0.0 * CGFloat(px), y: $0.1 * CGFloat(px)) }
        path.move(to: scaled[0])
        for pt in scaled.dropFirst() { path.line(to: pt) }
        path.close()
        return path
    }
    let top = poly([(0.50, 0.80), (0.78, 0.66), (0.50, 0.52), (0.22, 0.66)])
    let left = poly([(0.22, 0.66), (0.50, 0.52), (0.50, 0.20), (0.22, 0.34)])
    let right = poly([(0.50, 0.52), (0.78, 0.66), (0.78, 0.34), (0.50, 0.20)])
    NSColor(calibratedRed: 0.94, green: 0.99, blue: 1.00, alpha: 0.97).set(); top.fill()
    NSColor(calibratedRed: 0.55, green: 0.82, blue: 0.97, alpha: 0.92).set(); left.fill()
    NSColor(calibratedRed: 0.30, green: 0.62, blue: 0.92, alpha: 0.92).set(); right.fill()
    NSColor(calibratedWhite: 1.0, alpha: 0.85).set()
    for path in [top, left, right] {
        path.lineWidth = CGFloat(px) * 0.012
        path.stroke()
    }
    // Specular glints on the right face.
    NSColor(calibratedWhite: 1.0, alpha: 0.75).set()
    let glint = NSBezierPath(
        roundedRect: NSRect(x: 0.585 * CGFloat(px), y: 0.30 * CGFloat(px),
                            width: 0.045 * CGFloat(px), height: 0.16 * CGFloat(px)),
        xRadius: 0.02 * CGFloat(px), yRadius: 0.02 * CGFloat(px)
    )
    glint.transform(using: AffineTransform(rotationByDegrees: 24))
    glint.fill()

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
