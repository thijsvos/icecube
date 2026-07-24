// FanControlSection.swift — the popover's fan-control area: onboarding, approval, manual sliders, revert.

import IceCubeKit
import SwiftUI

/// The control section of the popover. What it shows depends on where the
/// helper stands: onboarding (not registered) → approval prompt → manual
/// controls. Manual mode gets an unmissable orange tint (PLAN.md §1.2), and
/// "Auto" is always the biggest, easiest action.
struct FanControlSection: View {
    // A plain `let`: observation-driven redraw works without @Bindable, which
    // exists only to project `$`-bindings — and this view forms none.
    let helper: HelperManager
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
        // Same tokens as every other card in this VStack — a change to
        // Theme.Metrics.cornerRadius now reaches all four, not three.
        .popoverCard(
            fill: isManual ? AnyShapeStyle(.orange.opacity(0.12)) : AnyShapeStyle(.quinary),
            border: isManual ? .orange.opacity(0.5) : .clear
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

    /// What the panel is reporting right now, derived once.
    ///
    /// The label, glyph and tint used to be three independent if-ladders over
    /// four booleans, each re-deriving the same precedence by hand and each
    /// re-reading `helper.status?`. HelperStatus is versioned and grows (v3
    /// added `guardianActive` itself), so a fifth state now becomes a compile
    /// error in exactly the places that must handle it.
    private enum ControlState {
        case manual, curve, guardianCooling, automatic

        var text: String {
            switch self {
            case .manual: "MANUAL fan control"
            case .curve: "Curve active"
            case .guardianCooling: "Automatic · cooling"
            case .automatic: "Automatic"
            }
        }

        var icon: String {
            switch self {
            case .manual: "hand.raised.fill"
            case .curve: "chart.xyaxis.line"
            case .guardianCooling: "wind"
            case .automatic: "gearshape"
            }
        }

        var style: AnyShapeStyle {
            switch self {
            case .manual: AnyShapeStyle(.orange)
            case .curve, .guardianCooling: AnyShapeStyle(Theme.accent)
            case .automatic: AnyShapeStyle(.secondary)
            }
        }
    }

    private var controlState: ControlState {
        guard let status = helper.status else { return .automatic }
        switch status.mode {
        case .manual: return .manual
        case .curve: return .curve
        // The daemon's guardian is driving the fans itself under Auto — the
        // Mac got hot and macOS wasn't cooling it.
        case .auto: return status.guardianActive ? .guardianCooling : .automatic
        }
    }

    private var isCurve: Bool {
        controlState == .curve
    }

    private var statusText: String {
        controlState.text
    }

    private var statusIcon: String {
        controlState.icon
    }

    private var statusColor: AnyShapeStyle {
        controlState.style
    }

    /// The preset quick-switch row (PLAN.md §1.2). Applying a curve preset
    /// needs the editor's persist setting, stored app-wide.
    @AppStorage("persistCurve") private var persistCurve = false

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(PresetStore.builtins) { preset in
                Button(preset.name) {
                    Task { await helper.applyPreset(preset, persistCurve: persistCurve) }
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
        helper.status?.mode == preset.config.mode
            && PresetHighlight.matches(preset, applied: helper.lastAppliedConfig)
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
            if controlState == .guardianCooling {
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
            sliderTargets[fan.id] = fan.actualRPM.clamped(to: fan.minRPM ... fan.maxRPM)
        }
        commitTargets()
    }

    private func commitTargets() {
        let targets = sliderTargets
        guard !targets.isEmpty else { return }
        Task { await helper.applyManual(targets: targets) }
    }
}
