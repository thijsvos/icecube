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

    /// The warning/manual accent. Orange carries exactly two meanings in Ice
    /// Cube — "you are driving the fans by hand" and "something needs your
    /// attention" — and nothing else, so its appearance is always meaningful.
    ///
    /// A token rather than a bare `.orange` at fourteen call sites: the color
    /// is identical today, but tuning it (or making it appearance-adaptive the
    /// way ``accent`` is) is now a one-line change instead of a grep.
    static let warning = Color.orange

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

    /// The same ramp, already resolved for one appearance.
    ///
    /// ``temperatureColor(_:)`` returns a **dynamic** colour: an
    /// `NSColor(name:)` carrying a closure that AppKit re-runs whenever the
    /// appearance might have changed. That is exactly right for a `View` that
    /// is built once and has to survive the user switching to dark mode — and
    /// exactly wrong inside a `Canvas` draw, which rebuilds everything every
    /// frame anyway.
    ///
    /// Measured: **2.184 µs** to build the dynamic form against **0.074 µs**
    /// for this one, thirty times cheaper — and that is only the construction.
    /// The dynamic colour additionally makes SwiftUI resolve it again during
    /// the render pass (`AppKitPlatformColorDefinition.resolvedHDRColor`, which
    /// is what showed up when the Inside window was profiled at 26 % CPU).
    ///
    /// The caller passes the appearance it is drawing in, so the colour is
    /// still correct in both themes — the decision simply moves from once per
    /// use to once per frame.
    static func temperatureColor(_ celsius: Double, dark: Bool) -> Color {
        let t = ((celsius - 45) / (95 - 45)).clamped(to: 0 ... 1)
        let hue = 0.58 * (1 - t)
        return dark
            ? Color(hue: hue, saturation: 0.55 + 0.25 * t, brightness: 0.78 + 0.12 * t)
            : Color(hue: hue, saturation: 0.72 + 0.22 * t, brightness: 0.60 + 0.12 * t)
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
        /// Gap between a card's uppercase title and its content. Every
        /// `.popoverCard()` uses this, so titles sit on one baseline rhythm
        /// instead of the per-card 6-or-8 guesses this replaced.
        static let cardContentSpacing: CGFloat = 8
        /// Inset around a popover-style window's whole content stack — the
        /// popover itself and the curve editor, which read as the same surface.
        static let popoverPadding: CGFloat = 14
        /// The popover's fixed width. Both the live content *and* the collapsed
        /// off-screen placeholder must use this: if they ever disagree the
        /// window visibly resizes when you reopen it.
        static let popoverWidth: CGFloat = 380
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
