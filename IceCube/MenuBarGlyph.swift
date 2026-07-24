// MenuBarGlyph.swift — the menu-bar icon: the Noto ice-cube artwork, rendered small and in color.

import AppKit

/// The menu-bar status glyph: the 🧊 ice-cube artwork from Google Noto Emoji
/// (Apache-2.0; see art/README.md), sized for the menu bar.
///
/// It's shown in **color** (not a tinted template) because "looks like ice"
/// comes from the translucency and blue — a monochrome silhouette just reads
/// as a box. It replaced the snowflake, which looked like a live "it's cold"
/// status rather than a brand mark. The temperature number beside it carries
/// the actual temperature.
enum MenuBarGlyph {
    /// The ice cube sized for the menu bar (~18 pt; the source is high-res so
    /// it stays crisp on Retina).
    static let iceCube: NSImage = {
        let image: NSImage = if let url = Bundle.main.url(forResource: "MenuBarIceCube", withExtension: "png"),
                                let loaded = NSImage(contentsOf: url)
        {
            loaded
        } else {
            // Fallback so the menu bar is never empty if the resource is missing.
            NSImage(systemSymbolName: "cube.transparent", accessibilityDescription: "Ice Cube")
                ?? NSImage()
        }
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
