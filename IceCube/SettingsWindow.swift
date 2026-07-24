// SettingsWindow.swift — the settings window: a custom tab bar with per-tab window sizing.

import IceCubeKit
import ServiceManagement
import SwiftUI

/// Settings as three tabs — General, Menu, Fan Control. A custom toolbar-style
/// tab bar (so the selection styling is ours, not the system-accent segmented
/// control) sits above the single current pane, and the window sizes to that
/// pane's natural height — so it resizes to fit each tab with no scroll and no
/// empty space. Relies on the window's `.windowResizability(.contentSize)`.
struct SettingsWindowView: View {
    @Bindable var state: AppState
    @AppStorage("persistCurve") private var persistCurve = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var updates = UpdateChecker()
    @Environment(\.openWindow) private var openWindow

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General", menu = "Menu", fans = "Fan Control"
        var id: String {
            rawValue
        }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .menu: "menubar.rectangle"
            case .fans: "fanblades"
            }
        }
    }

    @State private var tab: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            currentPane
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        // Every control (toggles, pickers, buttons) picks up the ice-blue brand
        // accent instead of the system accent, so Settings matches the app.
        .tint(Theme.accent)
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(Tab.allCases) { item in
                tabButton(item)
            }
        }
        .padding(8)
    }

    /// One tab: a filled, brand-blue icon + bold label on a subtle blue pill
    /// when selected; a quiet grey glyph otherwise.
    private func tabButton(_ item: Tab) -> some View {
        let selected = tab == item
        let fill: Color = selected ? Theme.accent.opacity(0.15) : .clear
        let tintStyle: AnyShapeStyle = selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary)
        return Button {
            // Instant switch — no animation. Animating the tab change
            // interpolates the whole layout while the window resizes, which
            // made the tab bar visibly shift ("move down").
            tab = item
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.icon)
                    .font(.system(size: 16))
                    .symbolVariant(selected ? .fill : .none)
                Text(item.rawValue)
                    .font(.caption.weight(selected ? .semibold : .regular))
            }
            .frame(width: 92)
            .padding(.vertical, 7)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tintStyle)
    }

    @ViewBuilder
    private var currentPane: some View {
        switch tab {
        case .general: generalTab
        case .menu: menuTab
        case .fans: fanControlTab
        }
    }

    // MARK: - General (login, units, cadence, alerts, updates)

    private var generalTab: some View {
        @Bindable var alerts = state.alerts
        return Form {
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
            Section("Alerts") {
                Picker("Notify at", selection: $alerts.threshold) {
                    Text("Off").tag(AlertManager.Threshold.off)
                    ForEach(AlertManager.Threshold.allCases.filter { $0 != .off }) { threshold in
                        Text(
                            "\(Int(state.temperatureUnit.display(Double(threshold.rawValue)).rounded()))\(state.temperatureUnit.title)"
                        )
                        .tag(threshold)
                    }
                }
                if state.alerts.permissionDenied {
                    Text("Notifications are denied — allow Ice Cube in System Settings → Notifications.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Updates") {
                LabeledContent("Version", value: UpdateChecker.currentVersion)
                HStack(spacing: 8) {
                    Button("Check for Updates…") { Task { await updates.check() } }
                        .controlSize(.small)
                    Button("About…") {
                        WindowOpener.open(WindowOpener.ID.about, using: openWindow)
                    }
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
                Toggle("Smoothly animate readings", isOn: $chart.smoothReadings)
                    .help(
                        "Numbers roll in place and gauge bars slide to each new reading; off makes them snap instantly"
                    )
            }
            if chart.showCharts {
                Section("Charts") {
                    Picker("Time window", selection: $chart.window) {
                        ForEach(ChartStore.Window.allCases) { window in
                            Text(window.title).tag(window)
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

    // MARK: - Fan Control (+ the advanced helper controls)

    private var fanControlTab: some View {
        Form {
            Section {
                if case .connected = state.helper.connection {
                    Picker("Active preset", selection: presetBinding) {
                        ForEach(PresetStore.builtins) { Text($0.name).tag($0.kind) }
                        // A user curve, an edited curve or manual mode matches
                        // no built-in. Without a row carrying this tag the
                        // picker renders blank on an out-of-range selection.
                        Text("Custom").tag(Preset.Kind.custom)
                    }
                    Button("Edit curves…") {
                        WindowOpener.open(WindowOpener.ID.curves, using: openWindow)
                    }
                    .controlSize(.small)
                } else {
                    Text("Open the menu and enable fan control first.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Keep the curve running when Ice Cube quits", isOn: $persistCurve)
                    .onChange(of: persistCurve) { _, on in
                        // Push the new setting to the daemon now, so an already-
                        // active curve starts (or stops) persisting immediately.
                        Task { await state.helper.setPersist(on) }
                    }
            }
            Section("Helper daemon") {
                LabeledContent("Status", value: helperStateText)
                HStack(spacing: 8) {
                    Button("Re-register") { Task { await state.helper.reregister() } }
                        .help("Force launchd to pick up a freshly built helper")
                    Button("Unregister") { Task { await state.helper.unregister() } }
                        .help("Remove the helper daemon; fans return to automatic")
                    if state.helper.isReregistering {
                        ProgressView().controlSize(.small)
                        Text("Re-registering…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .controlSize(.small)
                .disabled(state.helper.isReregistering)
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

    /// Reflects/sets the active built-in preset (mirrors the menu's preset row).
    ///
    /// Tagged on ``Preset/Kind`` rather than the display name, so renaming a
    /// built-in can't silently break the picker.
    private var presetBinding: Binding<Preset.Kind> {
        Binding(
            get: {
                guard state.helper.lastAppliedConfig != nil else { return .auto }
                return PresetHighlight.matching(
                    PresetStore.builtins, applied: state.helper.lastAppliedConfig
                )?.kind ?? .custom
            },
            set: { kind in
                guard let preset = PresetStore.builtins.first(where: { $0.kind == kind }) else { return }
                Task { await state.helper.applyPreset(preset, persistCurve: persistCurve) }
            }
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
