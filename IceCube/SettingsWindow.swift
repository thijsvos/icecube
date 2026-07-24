// SettingsWindow.swift — the tabbed settings window: focused tabs instead of one long page.

import ServiceManagement
import SwiftUI

/// The settings window, organized as macOS-style preference tabs (General /
/// Menu / Fan Control / Alerts / Advanced) so no single page is a wall of
/// controls. Each tab is a compact grouped `Form`.
struct SettingsWindowView: View {
    @Bindable var state: AppState
    @AppStorage("persistCurve") private var persistCurve = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var updates = UpdateChecker()
    @Environment(\.openWindow) private var openWindow

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General", menu = "Menu", fans = "Fans", alerts = "Alerts", advanced = "Advanced"
        var id: String {
            rawValue
        }
    }

    @State private var tab: Tab = .general

    var body: some View {
        // A segmented selector + only the current pane in the hierarchy, so
        // the window hugs each tab's content instead of reserving space for
        // the tallest one (which left the sparse tabs looking empty).
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            selectedTab
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var selectedTab: some View {
        switch tab {
        case .general: generalTab
        case .menu: menuTab
        case .fans: fanControlTab
        case .alerts: alertsTab
        case .advanced: advancedTab
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Launch Ice Cube at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                Picker("Temperature unit", selection: $state.temperatureUnit) {
                    ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Update readings every", selection: $state.pollInterval) {
                    ForEach(PollInterval.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Updates") {
                LabeledContent("Version", value: UpdateChecker.currentVersion)
                HStack(spacing: 8) {
                    Button("Check for Updates…") { Task { await updates.check() } }
                        .controlSize(.small)
                    updateStatusView
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Menu (what the popover / menu bar shows)

    private var menuTab: some View {
        @Bindable var chart = state.chartSettings
        return Form {
            Section("Menu bar") {
                Picker("Show beside the icon", selection: $state.menuBarDisplay) {
                    ForEach(MenuBarDisplayMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("In the menu") {
                Toggle("Fan controls", isOn: $chart.showControls)
                Toggle("Full temperature list", isOn: $chart.showTemperatureList)
                Toggle("Live charts", isOn: $chart.showCharts)
                Text("Turn controls and charts off for a pure monitoring menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if chart.showCharts {
                Section("Charts") {
                    Picker("Time window", selection: $chart.windowIndex) {
                        ForEach(Array(DashboardView.windowTitles.enumerated()), id: \.offset) { i, t in
                            Text(t).tag(i)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("CPU graph", isOn: $chart.showCPU)
                    Toggle("GPU graph", isOn: $chart.showGPU)
                    Toggle("Fan RPM graphs", isOn: $chart.showFans)
                    Toggle("Min/max band", isOn: $chart.showBand)
                    Toggle("Average / target line", isOn: $chart.showSecondary)
                    Picker("Height", selection: $chart.height) {
                        ForEach(ChartHeight.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Fan Control

    private var fanControlTab: some View {
        Form {
            Section {
                if case .connected = state.helper.connection {
                    Picker("Active preset", selection: presetBinding) {
                        ForEach(PresetStore.builtins) { Text($0.name).tag($0.name) }
                    }
                    Button("Edit curves…") {
                        WindowOpener.open(WindowOpener.ID.curves, using: openWindow)
                    }
                    .controlSize(.small)
                } else {
                    Text("Open the menu and enable fan control first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Keep the curve running when Ice Cube quits", isOn: $persistCurve)
                Text("Applies to the next preset or curve you activate. With this on, a curve even survives a reboot.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Alerts

    private var alertsTab: some View {
        Form {
            Section {
                Picker("Notify when the hottest sensor reaches", selection: alertBinding) {
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
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Advanced (helper daemon)

    private var advancedTab: some View {
        Form {
            Section("Helper daemon") {
                LabeledContent("Status", value: helperStateText)
                HStack(spacing: 8) {
                    Button("Re-register") { Task { await state.helper.reregister() } }
                        .help("Force launchd to pick up a freshly built helper")
                    Button("Unregister") { Task { await state.helper.unregister() } }
                        .help("Remove the helper daemon; fans return to automatic")
                }
                .controlSize(.small)
                Text("The root helper performs the fan writes. Unregistering returns the fans to macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Shared bits

    @ViewBuilder
    private var updateStatusView: some View {
        switch updates.status {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text("Up to date").font(.caption).foregroundStyle(.secondary)
        case let .available(version, url): Link("v\(version) available", destination: url).font(.caption)
        case let .failed(message): Text(message).font(.caption).foregroundStyle(.orange)
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

    /// Reflects/sets the active built-in preset (mirrors the menu's preset row,
    /// so hiding controls from the menu strands nothing).
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

    private var alertBinding: Binding<Int> {
        Binding(
            get: { Int(state.alerts.thresholdCelsius ?? 0) },
            set: { state.alerts.thresholdCelsius = $0 > 0 ? Double($0) : nil }
        )
    }

    /// `SMAppService.mainApp` — the supported login-item API; just the standard
    /// Login Items toggle, no daemon approval involved.
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
