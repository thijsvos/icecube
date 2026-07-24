#!/bin/sh
# generate-icon.sh — composites the Noto ice-cube artwork onto Ice Cube's gradient into AppIcon.icns.
# The ice-cube glyph is 🧊 U+1F9CA from Google Noto Emoji (Apache-2.0); see art/README.md.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build/AppIcon.iconset IceCube/Resources
swift - <<'EOF'
import AppKit

let source = NSImage(contentsOfFile: "art/noto-ice-1f9ca.png")!

let entries: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in entries {
    let px = CGFloat(entry.px)
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()

    // Rounded-square glacial gradient background (macOS icon convention).
    let inset = px * 0.05
    let rect = NSRect(x: inset, y: inset, width: px - 2 * inset, height: px - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.80, green: 0.95, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.92, alpha: 1),
    ])!.draw(in: bg, angle: -70)

    // The ice cube, centered at ~74% with a soft drop shadow.
    let s = px * 0.74
    let dst = NSRect(x: (px - s) / 2, y: (px - s) / 2 + px * 0.02, width: s, height: s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.22)
    shadow.shadowBlurRadius = px * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -px * 0.015)
    shadow.set()
    source.draw(in: dst)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("render failed at \(entry.px)px")
    }
    try! png.write(to: URL(fileURLWithPath: "build/AppIcon.iconset/\(entry.name).png"))
}
print("iconset rendered")
EOF
iconutil -c icns build/AppIcon.iconset -o IceCube/Resources/AppIcon.icns
echo "AppIcon.icns generated"
