// SettingsWindow.swift — the full settings window (Phase 5): login item, units, cadence, alerts.

import ServiceManagement
import SwiftUI

/// The dedicated settings window. The quick "menu bar shows" options ALSO
/// stay inline in the popover (choosing them there previews the menu bar
/// without dismissing anything); everything else lives here.
struct SettingsWindowView: View {
    @Bindable var state: AppState
    @AppStorage("persistCurve") private var persistCurve = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var updates = UpdateChecker()
    @Environment(\.openWindow) private var openWindow

    /// Reflects/sets the active built-in preset (the same control the menu's
    /// preset row offers, so hiding controls from the menu strands nothing).
    private var presetBinding: Binding<String> {
        Binding(
            get: {
                guard let applied = state.helper.lastAppliedConfig else { return "Auto" }
                return PresetStore.builtins.first {
                    $0.config.mode == applied.mode && $0.config.sharedCurve == applied.sharedCurve
                }?.name ?? "Custom"
            },
            set: { name in
                guard let preset = PresetStore.builtins.first(where: { $0.name == name }) else { return }
                var config = preset.config
                if config.mode == .curve {
                    config.persistsWithoutApp = persistCurve
                }
                Task { await state.helper.apply(config) }
            }
        )
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updates.status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("Up to date").font(.caption).foregroundStyle(.secondary)
        case let .available(version, url):
            Link("v\(version) available — open release page", destination: url)
                .font(.caption)
        case let .failed(message):
            Text(message).font(.caption).foregroundStyle(.orange)
        }
    }

    var body: some View {
        // Local @Bindable so bindings reach the nested @Observable directly.
        @Bindable var chart = state.chartSettings
        return Form {
            Section("General") {
                Toggle("Launch Ice Cube at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("Keep curve running when app quits", isOn: $persistCurve)
                Text("Applies to the next curve or preset you activate. With this on, a curve even survives a reboot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Fan control") {
                if case .connected = state.helper.connection {
                    Picker("Preset", selection: presetBinding) {
                        ForEach(PresetStore.builtins) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                    }
                    Button("Edit curves…") {
                        WindowOpener.open(WindowOpener.ID.curves, using: openWindow)
                    }
                    .controlSize(.small)
                } else {
                    Text("Open the menu and enable fan control first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Display") {
                Picker("Temperature unit", selection: $state.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Update readings every", selection: $state.pollInterval) {
                    ForEach(PollInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Menu bar shows", selection: $state.menuBarDisplay) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
            Section("Menu appearance") {
                Toggle("Show fan controls in the menu", isOn: $chart.showControls)
                Toggle("Show live charts in the menu", isOn: $chart.showCharts)
                Text(
                    "Turn both off for a pure monitoring menu — just temperatures and fan speeds. Fan control still lives here in Settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if chart.showCharts {
                    Picker("Default time window", selection: $chart.windowIndex) {
                        ForEach(Array(DashboardView.windowTitles.enumerated()), id: \.offset) { index, title in
                            Text(title).tag(index)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("CPU temperature graph", isOn: $chart.showCPU)
                    Toggle("GPU temperature graph", isOn: $chart.showGPU)
                    Toggle("Fan RPM graphs", isOn: $chart.showFans)
                    Toggle("Min/max range band", isOn: $chart.showBand)
                    Toggle("Average / target line", isOn: $chart.showSecondary)
                    Picker("Graph height", selection: $chart.height) {
                        ForEach(ChartHeight.allCases) { h in
                            Text(h.title).tag(h)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Show full temperature list in the menu", isOn: $chart.showTemperatureList)
            }
            Section("Alerts") {
                Picker("Notify when hottest sensor reaches", selection: alertBinding) {
                    Text("Off").tag(0)
                    ForEach([85, 90, 95], id: \.self) { threshold in
                        Text(
                            "\(Int(state.temperatureUnit.display(Double(threshold)).rounded()))\(state.temperatureUnit.title)"
                        )
                        .tag(threshold)
                    }
                }
                if state.alerts.permissionDenied {
                    Text("Notifications are denied — allow Ice Cube in System Settings → Notifications.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Updates") {
                LabeledContent("Version", value: UpdateChecker.currentVersion)
                HStack(spacing: 8) {
                    Button("Check for Updates…") {
                        Task { await updates.check() }
                    }
                    .controlSize(.small)
                    updateStatusView
                }
            }
            Section("Helper daemon") {
                LabeledContent("Status", value: helperStateText)
                HStack(spacing: 8) {
                    Button("Re-register") {
                        Task { await state.helper.reregister() }
                    }
                    .help("Force launchd to pick up a freshly built helper")
                    Button("Unregister") {
                        Task { await state.helper.unregister() }
                    }
                    .help("Remove the helper daemon; fans return to automatic")
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
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

    private var alertBinding: Binding<Int> {
        Binding(
            get: { Int(state.alerts.thresholdCelsius ?? 0) },
            set: { state.alerts.thresholdCelsius = $0 > 0 ? Double($0) : nil }
        )
    }

    /// `SMAppService.mainApp` — the supported login-item API; no daemons or
    /// approval involved, just the standard Login Items toggle.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
