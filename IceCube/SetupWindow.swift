// SetupWindow.swift — the guided first-run flow for turning on fan control.

import IceCubeKit
import SwiftUI

/// A single-screen, self-updating setup flow.
///
/// Deliberately NOT a multi-page wizard with Next buttons: there is only ever
/// one thing to do, and the steps are driven by real system state rather than
/// by page position. When the user flips the switch in System Settings this
/// window notices and moves on by itself — that live feedback is the whole
/// point, because the old flow's dead end was "I approved it… now what?".
struct SetupWindowView: View {
    let state: AppState
    @State private var model: SetupModel?
    @Environment(\.dismiss) private var dismiss
    /// Set only when the user closes this window, so a relaunch mid-flow (the
    /// move to /Applications) reopens it rather than assuming it was handled.
    @AppStorage("hasDismissedSetup") private var hasDismissedSetup = false

    private func close() {
        hasDismissedSetup = true
        dismiss()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
        // Closing with the title-bar button (or ⌘W) is a dismissal too. Only
        // the Done/Not Now buttons used to record it, so someone who closed the
        // window the ordinary way was offered it again on the next launch.
        // Excludes the relocation relaunch: the window disappearing because we
        // are restarting elsewhere is not the user saying no.
        .onDisappear {
            if model?.isRelocating != true {
                hasDismissedSetup = true
            }
        }
        .task {
            if model == nil {
                model = SetupModel(helper: state.helper)
            }
            // Poll while the window is open so approval in System Settings is
            // reflected here within a second, not on the next 5 s helper pass.
            while !Task.isCancelled {
                await model?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: MenuBarGlyph.iceCube)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ice Cube").font(.title2.weight(.semibold))
                Text("Fan control setup").premiumSectionLabel()
            }
            Spacer()
        }
        .padding(Theme.Metrics.popoverPadding)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let model {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                stepRow(model)
                if model.needsApprovalDirections {
                    Label(SetupGuidance.approvalDirections, systemImage: "arrow.right.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .popoverCard()
                        .transition(.opacity)
                }
                if model.isComplete {
                    completionNote
                } else {
                    reassurance
                }
                HStack {
                    if model.isComplete {
                        Spacer()
                        Button("Done") { close() }
                            .keyboardShortcut(.defaultAction)
                            .primaryGlassButton()
                    } else {
                        Button("Not Now") { close() }
                        Spacer()
                        if let action = model.actionTitle {
                            Button(action) { model.performAction() }
                                .keyboardShortcut(.defaultAction)
                                .primaryGlassButton()
                        }
                    }
                }
                .controlSize(.large)
            }
            .padding(Theme.Metrics.popoverPadding)
        }
    }

    private func stepRow(_ model: SetupModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            stepIcon(model)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title).font(.headline)
                Text(model.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .popoverCard()
    }

    @ViewBuilder
    private func stepIcon(_ model: SetupModel) -> some View {
        switch model.step {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2).foregroundStyle(Theme.accent)
        case .blocked:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2).foregroundStyle(Theme.warning)
        case .awaitingApproval, .connecting:
            ProgressView().controlSize(.small)
        case .connectionStuck, .needsUpdate:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2).foregroundStyle(Theme.accent)
        case .moveToApplications:
            Image(systemName: "folder.fill")
                .font(.title2).foregroundStyle(Theme.accent)
        case .needsPermission:
            Image(systemName: "fan.fill")
                .font(.title2).foregroundStyle(Theme.accent)
        }
    }

    /// The honest framing: monitoring already works, so this permission is
    /// genuinely optional. Saying so removes the pressure that makes people
    /// bounce off a permission prompt.
    private var reassurance: some View {
        Label(
            "Temperature and fan-speed monitoring already work without this. "
                + "You can turn fan control on later from the Ice Cube menu.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var completionNote: some View {
        Label(
            "Ice Cube keeps your fans safe: speeds stay inside the limits your Mac "
                + "reports, and everything returns to automatic if Ice Cube stops.",
            systemImage: "checkmark.shield"
        )
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
