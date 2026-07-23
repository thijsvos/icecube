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

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch Zephyr at login", isOn: $launchAtLogin)
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
                    Text("Notifications are denied — allow Zephyr in System Settings → Notifications.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
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
