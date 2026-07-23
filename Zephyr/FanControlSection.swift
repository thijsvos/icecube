// FanControlSection.swift — the popover's fan-control area: onboarding, approval, manual sliders, revert.

import SwiftUI
import ZephyrKit

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
            content
            if let error = helper.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isManual ? AnyShapeStyle(.orange.opacity(0.12)) : AnyShapeStyle(.quinary))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
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
            Text("Controlling fans needs a small helper that runs with " +
                "administrator rights. It only ever writes clamped, safe fan " +
                "speeds, reverts to automatic if Zephyr stops, and you approve " +
                "it once in System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Enable Fan Control") {
                helper.register()
            }
            .controlSize(.small)
        }
    }

    private var approvalPrompt: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("One approval needed", systemImage: "checkmark.shield")
                .font(.callout.weight(.medium))
            Text("macOS wants your OK: System Settings → General → " +
                "Login Items & Extensions → allow “Zephyr” in the background.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                helper.openApprovalSettings()
            }
            .controlSize(.small)
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    isManual ? "MANUAL fan control" : "Fans on automatic",
                    systemImage: isManual ? "hand.raised.fill" : "gearshape"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(isManual ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if let branch = helper.status?.unlockBranch, isManual {
                    Text(branch == "ftst" ? "(unlock path)" : "(direct path)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if isManual {
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
