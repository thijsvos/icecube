// SettingsFanControlTab.swift — fan-control status, the power rule, and the advanced helper controls.

import IceCubeKit
import SwiftUI

/// The Fan Control pane. Storage stays in `SettingsWindowView`; see
/// ``SettingsGeneralTab`` for why.
struct SettingsFanControlTab: View {
    @Bindable var state: AppState
    @Binding var persistCurve: Bool
    let openWindow: OpenWindowAction

    /// Turning fan control off removes a root LaunchDaemon and erases both the
    /// app's and the daemon's record of the curve the user chose. It was a
    /// single unguarded click, sitting next to "Reinstall" — and the two look
    /// alike enough that the destructive one deserves a sentence first.
    @State private var confirmingTurnOff = false

    var body: some View {
        fanControlTab
    }

    private var fanControlTab: some View {
        Form {
            Section {
                if case .connected = state.helper.connection {
                    Picker("Active preset", selection: presetBinding) {
                        ForEach(state.presets.all) { Text($0.name).tag(Optional($0.id)) }
                        // An edited curve or manual mode matches no preset at
                        // all. Without a row carrying this tag the picker
                        // renders blank on an out-of-range selection.
                        Text("Custom").tag(Preset.ID?.none)
                    }
                    Button("Edit curves…") {
                        WindowOpener.open(WindowOpener.ID.curves, using: openWindow)
                    }
                    .controlSize(.small)
                } else {
                    Text("Open the menu and enable fan control first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                powerProfileRule

                Toggle("Keep the curve running when Ice Cube quits", isOn: $persistCurve)
                    .onChange(of: persistCurve) { _, on in
                        // Push the new setting to the daemon now, so an already-
                        // active curve starts (or stops) persisting immediately.
                        Task { await state.helper.setPersist(on) }
                    }
            }
            // Was "Helper daemon" with Re-register / Unregister buttons and a
            // status reading "not registered · disconnected". Every word of
            // that describes the implementation. The actions are legitimate —
            // one turns fan control off, one repairs it — they just had names
            // only the author could parse.
            Section("Fan Control Setup") {
                LabeledContent("Status", value: state.setupStatusText)
                HStack(spacing: 8) {
                    // Two different jobs, so two different actions. Routing
                    // both into the setup window left no way to force a
                    // reinstall once things *looked* fine — which is exactly
                    // when you need one: a subtly wedged service, or a rebuilt
                    // app whose old service is still running.
                    if state.helper.registration == .enabled {
                        Button("Reinstall") { Task { await state.helper.reregister() } }
                            .help("Restart the background service — fixes it if fan control is stuck")
                    } else {
                        Button("Set Up…") {
                            WindowOpener.open(WindowOpener.ID.setup, using: openWindow)
                        }
                    }
                    Button("Turn Off Fan Control") { confirmingTurnOff = true }
                        .help("Fans go back to being managed by macOS. Monitoring keeps working.")
                        .confirmationDialog(
                            "Turn off fan control?",
                            isPresented: $confirmingTurnOff,
                            titleVisibility: .visible
                        ) {
                            Button("Turn Off Fan Control", role: .destructive) {
                                Task { await state.helper.unregister() }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(
                                "Your fans go back to macOS, the background service is removed, and "
                                    + "your saved curve choice is forgotten. Monitoring keeps working."
                            )
                        }
                    if state.helper.isReregistering {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
                .disabled(state.helper.isReregistering)

                writePathCheck

                // The technical state stays, demoted: it is what a good bug
                // report needs, and the "new Mac model" issue template asks
                // for it. It just isn't the headline any more.
                LabeledContent("Details") {
                    Text(helperStateText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var powerProfileRule: some View {
        let rule = Binding(
            get: { state.helper.powerRule },
            set: { state.helper.powerRule = $0 }
        )
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Switch presets when I plug in or unplug", isOn: rule.isEnabled)
            // Built-ins only, deliberately, and the one preset surface that
            // still is. `PowerProfilePolicy.Rule` **persists** a `Preset.Kind`,
            // so pointing this at a saved curve means changing a stored Codable
            // shape and migrating what is already on disk — a different kind of
            // change from the rest, and one this project does not make in
            // passing. Everywhere else now offers `presets.all`.
            HStack(spacing: 6) {
                Text("On battery use").font(.callout)
                Picker("", selection: rule.onBattery) {
                    ForEach(PresetStore.builtins) { Text($0.name).tag($0.kind) }
                }
                .labelsHidden().fixedSize()
                Text("· plugged in use").font(.callout)
                Picker("", selection: rule.onWall) {
                    ForEach(PresetStore.builtins) { Text($0.name).tag($0.kind) }
                }
                .labelsHidden().fixedSize()
            }
            .controlSize(.small)
            .disabled(!state.helper.powerRule.isEnabled)
            // Says plainly that this responds to a change rather than policing
            // a state — the distinction that keeps it from fighting the user,
            // and the one someone needs to trust it.
            Text("Only when the power source changes. Pick a different preset "
                + "any time and it stays until you next plug in or unplug.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var writePathCheck: some View {
        if case .connected = state.helper.connection {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button("Check Fan Control") {
                        Task { await state.helper.runWritePathSelfTest() }
                    }
                    .controlSize(.small)
                    .help("Confirms this Mac's fans can actually be driven. Nothing changes speed.")
                    if state.helper.isSelfTesting {
                        ProgressView().controlSize(.small)
                        Text("Checking…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(state.helper.isSelfTesting)

                if let report = state.helper.writePathReport {
                    Label(
                        report.summary,
                        systemImage: report.verdict == .verified
                            ? "checkmark.seal.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(report.verdict == .verified ? Theme.accent : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    if report.isWorthReporting {
                        // Only for the two verdicts that tell the project
                        // something it does not already know. Asking every user
                        // to file a clean pass would bury the real reports.
                        Text("Export Diagnostics from the Sensors window and open a "
                            + "\"New Mac model report\" issue — this result is exactly what's needed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var helperStateText: String {
        let registration = switch state.helper.registration {
        case .unknown: "unknown"
        case .notRegistered: "not registered"
        case .requiresApproval: "waiting for approval"
        case .enabled: "enabled"
        }
        let connection = switch state.helper.connection {
        case .disconnected: "disconnected"
        case let .connected(version): "connected (v\(version))"
        case let .versionMismatch(helper): "version mismatch (v\(helper))"
        }
        return "\(registration) · \(connection)"
    }

    /// Selection is a **preset id**, not a `Preset.Kind`.
    ///
    /// Every saved preset carries `kind == .custom`, so a picker tagged by kind
    /// could not tell two of them apart — which is why saved curves could not
    /// appear here at all. Nothing persists this value (it is derived from the
    /// applied config each time), so the built-ins' per-launch UUIDs are fine.
    private var presetBinding: Binding<Preset.ID?> {
        Binding(
            get: {
                // Nothing applied yet lands on "Custom", the picker's catch-all
                // row. It used to fall back to `.auto`, which stopped being a
                // preset when macOS mode was removed — and "Custom" is the
                // honest label for "not one of these" anyway.
                guard state.helper.lastAppliedConfig != nil else { return nil }
                return PresetHighlight.matching(
                    state.presets.all, applied: state.helper.lastAppliedConfig
                )?.id
            },
            set: { id in
                guard let id, let preset = state.presets.all.first(where: { $0.id == id }) else { return }
                Task { await state.helper.applyPreset(preset, persistCurve: persistCurve) }
            }
        )
    }
}
