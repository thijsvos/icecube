// AboutView.swift — the About window: app identity, version, and license (links added at publish time).

import AppKit
import SwiftUI

/// A small, crafted About panel. Deliberately linkless for now: the project is
/// unpublished, and a dead GitHub link would read worse than none — the repo
/// link lands here once Phase 6 goes public.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            // The real app icon, displayed (never modified).
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)

            VStack(spacing: 3) {
                Text("Ice Cube")
                    .font(.title2.weight(.semibold))
                Text("Version \(UpdateChecker.currentVersion)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text("Fan control and thermal monitoring for Apple Silicon Macs.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Divider().frame(width: 180)

            VStack(spacing: 2) {
                Text("Open source · MIT licensed")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text("Ice-cube glyph: Noto Emoji (Apache 2.0)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(28)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}
