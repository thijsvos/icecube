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
    // Draw into an EXPLICITLY sized bitmap, not NSImage.lockFocus().
    //
    // lockFocus() renders at the current display's backing scale factor, so on
    // a Retina Mac every tile came out at exactly 2x its declared size —
    // icon_16x16.png was 32x32, icon_512x512@2x.png was 2048x2048. iconutil
    // silently DROPS entries whose pixels disagree with their name, which is
    // why the shipped .icns was missing 16x16 and 128x128 entirely: the two
    // sizes macOS uses for Finder lists and System Settings → Login Items,
    // i.e. the one screen every new user has to visit.
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: entry.px, pixelsHigh: entry.px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

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

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("render failed at \(entry.px)px")
    }
    guard rep.pixelsWide == entry.px, rep.pixelsHigh == entry.px else {
        fatalError("\(entry.name) rendered at \(rep.pixelsWide)px, expected \(entry.px)px")
    }
    try! png.write(to: URL(fileURLWithPath: "build/AppIcon.iconset/\(entry.name).png"))
}
print("iconset rendered")
EOF
iconutil -c icns build/AppIcon.iconset -o IceCube/Resources/AppIcon.icns
echo "AppIcon.icns generated"
