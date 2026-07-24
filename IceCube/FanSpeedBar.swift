// FanSpeedBar.swift — a slim brand-gradient gauge for fan speed (0…1 of max).

import IceCubeKit
import SwiftUI

/// A rounded, gradient-filled speed gauge — reads as a designed instrument
/// rather than a stock progress bar. `fraction` is 0…1 of the fan's maximum;
/// the fill never fully vanishes while the fan spins (a minimum pill), so a
/// floor-speed fan still looks alive. Only a stopped fan (fraction 0) is empty.
///
/// An optional `target` (0…1) draws a thin tick the fill visibly slides toward
/// — this is how "heading to a speed" is shown, replacing the jumpy inline arrow.
struct FanSpeedBar: View {
    let fraction: Double
    /// Target speed as 0…1 of max, drawn as a tick. Nil hides it.
    var target: Double?
    var height: CGFloat = 6
    /// When false, the fill snaps to each new speed instead of sliding.
    var animated: Bool = true

    var body: some View {
        GeometryReader { geo in
            let clamped = fraction.clamped(to: 0 ... 1)
            // A spinning fan keeps at least a rounded pill of fill; a truly
            // stopped fan (fraction 0) shows nothing.
            let width = clamped <= 0 ? 0 : max(height, geo.size.width * clamped)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)
                Capsule(style: .continuous)
                    .fill(LinearGradient(
                        colors: [Theme.accent.opacity(0.75), Theme.accent],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: width)
                    // Slide to each new speed instead of snapping (0.45 s < the
                    // 1 s poll, so it always settles before the next reading).
                    .animation(animated ? .easeInOut(duration: 0.45) : nil, value: clamped)
                if let target {
                    let tick = target.clamped(to: 0 ... 1)
                    // Only show it once the fill is meaningfully short of the
                    // target — otherwise it just sits on the fill edge as noise.
                    if abs(tick - clamped) > 0.04 {
                        Capsule(style: .continuous)
                            .fill(.primary.opacity(0.45))
                            .frame(width: 2, height: height)
                            .offset(x: (tick * geo.size.width - 1).clamped(to: 0 ... max(0, geo.size.width - 2)))
                            .animation(animated ? .easeInOut(duration: 0.45) : nil, value: tick)
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true) // the RPM text carries the value
    }
}
