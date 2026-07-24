// FanControlSection.swift — the popover's fan-control area: onboarding, approval, manual sliders, revert.

import IceCubeKit
import SwiftUI

/// The control section of the popover. What it shows depends on where the
/// helper stands: onboarding (not registered) → approval prompt → manual
/// controls. Manual mode gets an unmissable orange tint (PLAN.md §1.2), and
/// "Auto" is always the biggest, easiest action.
struct FanControlSection: View {
    @Bindable var helper: HelperManager
    /// Live fan readings (for slider ranges and current values).
    let fans: [Fan]

    /// Slider positions, per fan id. Committed to the daemon on release only
    /// — dragging must not spam the SMC with writes.
    @State private var sliderTargets: [Int: Double] = [:]

    private var isManual: Bool {
        helper.status?.mode == .manual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Control").premiumSectionLabel()
            content
            if let error = helper.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Metrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .fill(isManual ? AnyShapeStyle(.orange.opacity(0.12)) : AnyShapeStyle(.quinary))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius, style: .continuous)
                .strokeBorder(isManual ? .orange.opacity(0.5) : .clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch helper.registration {
        case .unknown, .notRegistered:
            onboarding
        case .requiresApproval:
            approvalPrompt
        case .enabled:
            enabledContent
        }
    }

    // MARK: - Onboarding & approval

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fan control is off", systemImage: "fan.slash")
                .font(.callout.weight(.medium))
            Text("A small admin helper does the fan writes — only safe, clamped "
                + "speeds, and it reverts to automatic if Ice Cube stops. Approved "
                + "once in System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Enable Fan Control") {
                helper.register()
            }
            .controlSize(.small)
            .primaryGlassButton()
        }
    }

    private var approvalPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("One approval needed", systemImage: "checkmark.shield")
                .font(.callout.weight(.medium))
            Text("macOS wants your OK: System Settings → General → " +
                "Login Items & Extensions → allow “Ice Cube” in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                helper.openApprovalSettings()
            }
            .controlSize(.small)
            .primaryGlassButton()
        }
    }

    // MARK: - Enabled: connection states & manual controls

    @ViewBuilder
    private var enabledContent: some View {
        switch helper.connection {
        case .disconnected:
            Label("Helper enabled — connecting…", systemImage: "bolt.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .versionMismatch(helperVersion):
            VStack(alignment: .leading, spacing: 6) {
                Label("Helper is outdated (v\(helperVersion))", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Update Helper (Re-register)") {
                    Task { await helper.reregister() }
                }
                .controlSize(.small)
            }
        case .connected:
            controls
        }
    }

    private var isCurve: Bool {
        helper.status?.mode == .curve
    }

    /// The daemon's safety guardian is driving the fans itself under Auto —
    /// the Mac got hot and macOS wasn't cooling it.
    private var guardianCooling: Bool {
        helper.status?.mode == .auto && (helper.status?.guardianActive ?? false)
    }

    private var statusText: String {
        if isManual {
            return "MANUAL fan control"
        }
        if isCurve {
            return "Curve active"
        }
        if guardianCooling {
            return "Automatic · cooling"
        }
        return "Automatic"
    }

    private var statusIcon: String {
        if isManual {
            return "hand.raised.fill"
        }
        if isCurve {
            return "chart.xyaxis.line"
        }
        if guardianCooling {
            return "wind"
        }
        return "gearshape"
    }

    private var statusColor: AnyShapeStyle {
        if isManual {
            return AnyShapeStyle(.orange)
        }
        if isCurve || guardianCooling {
            return AnyShapeStyle(Theme.accent)
        }
        return AnyShapeStyle(.secondary)
    }

    /// The preset quick-switch row (PLAN.md §1.2). Applying a curve preset
    /// needs the editor's persist setting, stored app-wide.
    @AppStorage("persistCurve") private var persistCurve = false

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(PresetStore.builtins) { preset in
                Button(preset.name) {
                    Task {
                        var config = preset.config
                        if config.mode == .curve {
                            config.persistsWithoutApp = persistCurve
                        }
                        await helper.apply(config)
                    }
                }
                .buttonStyle(.bordered)
                .tint(isActivePreset(preset) ? Theme.accent : nil)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    @Environment(\.openWindow) private var openWindow

    /// Highlight from the last config this app sent, cross-checked against
    /// the mode the daemon actually reports.
    private func isActivePreset(_ preset: Preset) -> Bool {
        guard let applied = helper.lastAppliedConfig,
              helper.status?.mode == preset.config.mode else { return false }
        return applied.mode == preset.config.mode
            && applied.sharedCurve == preset.config.sharedCurve
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            presetRow
            HStack {
                Label(statusText, systemImage: statusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                Spacer()
                Button("Curves…") {
                    WindowOpener.open(WindowOpener.ID.curves, using: openWindow)
                }
                .controlSize(.small)
                .help("Edit the temperature→fan curve")
                if isManual || isCurve {
                    Button("Revert to Auto") {
                        Task { await helper.revertToAuto() }
                    }
                    .controlSize(.small)
                    .tint(.orange)
                    .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button("Take Manual Control") {
                        engageManual()
                    }
                    .controlSize(.small)
                }
            }
            if guardianCooling {
                Text("Ice Cube is cooling the Mac — macOS left the fans idle while it ran hot. "
                    + "It hands back once things cool down.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isManual {
                ForEach(fans) { fan in
                    sliderRow(fan)
                }
                if helper.status?.lastWriteVerified == false {
                    Label(
                        "Last write not verified — the system may be resisting control.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private func sliderRow(_ fan: Fan) -> some View {
        HStack(spacing: 8) {
            Text(fan.name)
                .font(.caption)
                .frame(width: 40, alignment: .leading)
            Slider(
                value: Binding(
                    get: { sliderTargets[fan.id] ?? fan.targetRPM },
                    set: { sliderTargets[fan.id] = $0 }
                ),
                in: fan.minRPM ... max(fan.maxRPM, fan.minRPM + 1),
                onEditingChanged: { editing in
                    if !editing {
                        commitTargets()
                    } // commit on release only
                }
            )
            .controlSize(.small)
            Text("\(Int(sliderTargets[fan.id] ?? fan.targetRPM))")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                .accessibilityLabel("\(fan.name) fan target \(Int(sliderTargets[fan.id] ?? fan.targetRPM)) RPM")
        }
    }

    // MARK: - Actions

    /// Enters manual mode holding the fans where they are now (no jump in
    /// noise), ready for the user to slide.
    private func engageManual() {
        for fan in fans {
            sliderTargets[fan.id] = min(max(fan.actualRPM, fan.minRPM), fan.maxRPM)
        }
        commitTargets()
    }

    private func commitTargets() {
        let targets = sliderTargets
        guard !targets.isEmpty else { return }
        Task { await helper.applyManual(targets: targets) }
    }
}
