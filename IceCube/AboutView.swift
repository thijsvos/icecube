// AboutView.swift — the About window: app identity, version, license, and where to find the source.

import AppKit
import SwiftUI

/// A small, crafted About panel.
///
/// This was deliberately linkless while the project was unpublished — "a dead
/// GitHub link would read worse than none — the repo link lands here once
/// Phase 6 goes public." The repo went public on 2026-07-27 and the links did
/// not follow, so for six weeks the one window people open to find the source
/// of an open-source app was the one place that would not tell them. The
/// condition its own comment set has been met; these are the links.
///
/// URLs come from ``UpdateChecker``'s `repository` constant rather than being
/// typed here, so there is one place a rename has to touch.
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

            HStack(spacing: 14) {
                Link("Source", destination: UpdateChecker.repositoryURL)
                Link("Report an issue", destination: UpdateChecker.issuesURL)
            }
            .font(.callout)

            Divider().frame(width: 180)

            VStack(spacing: 2) {
                // The licence names itself and links to itself; "MIT licensed"
                // as plain text is a claim the reader cannot check from here.
                Link("Open source · MIT licensed", destination: UpdateChecker.licenseURL)
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
