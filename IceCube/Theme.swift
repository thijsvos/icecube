// Theme.swift — the app's small design system: brand accent, spacing rhythm, and thermal color mapping.

import AppKit
import IceCubeKit
import SwiftUI

private extension NSAppearance {
    /// Whether this appearance is one of the dark variants.
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// One place for the visual language, so colors and spacing stay cohesive
/// rather than ad-hoc per view — the main lever for a "premium" feel.
enum Theme {
    /// The brand/active accent (matches the ice-cube blue). Used for active
    /// states and the fan visualization; warmth (orange/red) is reserved for
    /// genuine heat and warnings so color always carries meaning.
    ///
    /// Adaptive: a bright blue on dark, a deeper blue on light, so it keeps its
    /// presence and contrast in both appearances instead of washing out.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(srgbRed: 0.30, green: 0.62, blue: 0.95, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.45, blue: 0.86, alpha: 1)
    })

    /// A calm→warm thermal color for a temperature reading: cool blue at idle,
    /// through teal/green, to amber and red as the die heats. Muted saturation
    /// so it reads as refined data-coloring, not a garish alarm.
    ///
    /// Anchors: ≤45 °C cool blue · ~65 °C green · ~82 °C amber · ≥95 °C red.
    /// Adaptive: brighter/softer on dark; more saturated and a touch darker on
    /// light, where high-brightness hues would otherwise wash out on white.
    static func temperatureColor(_ celsius: Double) -> Color {
        // Hue sweeps 0.58 (blue) → 0.0 (red).
        let t = ((celsius - 45) / (95 - 45)).clamped(to: 0 ... 1)
        let hue = 0.58 * (1 - t)
        return Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.isDark {
                return NSColor(hue: hue, saturation: 0.55 + 0.25 * t, brightness: 0.78 + 0.12 * t, alpha: 1)
            }
            return NSColor(hue: hue, saturation: 0.72 + 0.22 * t, brightness: 0.60 + 0.12 * t, alpha: 1)
        })
    }

    /// Shared metrics so grouped surfaces line up on one rhythm instead of
    /// per-view guesses — consistent radius/spacing is a core "premium" cue.
    enum Metrics {
        /// Corner radius for grouped surfaces (cards, control panel).
        static let cornerRadius: CGFloat = 10
        /// Inset inside a grouped surface.
        static let cardPadding: CGFloat = 10
        /// Vertical gap between top-level popover sections.
        static let sectionSpacing: CGFloat = 10
    }
}

extension View {
    /// Wraps content as a subtle grouped "card" — the popover's composed-surface
    /// look, matching the fan-control panel so every section shares one visual
    /// language. Full-width so all cards align to the same edges.
    ///
    /// Parameterized so a card that needs a different fill (manual mode's
    /// orange tint) still shares the radius and padding tokens, instead of
    /// re-spelling the whole stack by hand. The defaults render exactly as
    /// before: `.quinary` fill, no border.
    func popoverCard(
        fill: some ShapeStyle = HierarchicalShapeStyle.quinary,
        border: Color = .clear
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
        return frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Metrics.cardPadding)
            .background(shape.fill(fill))
            // Decorative only. Overlays are hit-testable by default, and this
            // one is now unconditional (cards that pass no border get a clear
            // stroke), so without this a 1pt ring around every card would
            // swallow clicks meant for the content beneath it.
            .overlay(shape.strokeBorder(border, lineWidth: 1).allowsHitTesting(false))
    }

    /// A quiet uppercase section label — the hierarchy cue that turns a flat
    /// stack into a legible dashboard, used as a card's title.
    func premiumSectionLabel() -> some View {
        font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}
