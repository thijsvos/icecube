// LiquidGlass.swift — availability-guarded Liquid Glass helpers (macOS 26) with macOS 14/15 fallbacks.

import SwiftUI

/// Ice Cube deploys back to macOS 14, but the explicit Liquid Glass APIs exist
/// only on macOS 26. These helpers apply real glass on Tahoe and fall back to
/// today's styling on older systems, so call sites stay clean and single-source.
///
/// Note: standard controls, `TabView`, `Form`, sheets, and the `MenuBarExtra`
/// popover chrome already adopt Liquid Glass *automatically* on macOS 26 because
/// the app is built with the macOS 26 SDK — these helpers are only for the few
/// custom elements where we opt in deliberately.
extension View {
    /// A prominent (filled) glass button on macOS 26; `.borderedProminent`
    /// below. Use for the single primary action in a view.
    @ViewBuilder
    func primaryGlassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// A translucent glass button on macOS 26; `.bordered` below. Use for
    /// secondary actions.
    @ViewBuilder
    func secondaryGlassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// Glass surface for a small **floating** control cluster (a pod that hovers
    /// over content).
    ///
    /// On macOS 26 it's real Liquid Glass; below it approximates with
    /// `.ultraThinMaterial`. Do NOT use this on content (charts) or inside the
    /// already-glass popover — only for floating control clusters over content.
    @ViewBuilder
    func floatingGlass(in shape: some Shape = Capsule()) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(shape.fill(.ultraThinMaterial))
                .overlay(shape.stroke(.white.opacity(0.12)))
        }
    }
}
