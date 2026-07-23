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

    // White fan glyph, centered.
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.5, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "cube.transparent", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.35, alpha: 1).set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let symbolRect = NSRect(
            x: (CGFloat(px) - tinted.size.width) / 2,
            y: (CGFloat(px) - tinted.size.height) / 2,
            width: tinted.size.width, height: tinted.size.height
        )
        tinted.draw(in: symbolRect)
    }
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
