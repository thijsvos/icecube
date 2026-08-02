// SettingsGeneralTab.swift — login item, units, cadence, alerts and the update check.

import IceCubeKit
import ServiceManagement
import SwiftUI

/// The General pane.
///
/// Storage stays in `SettingsWindowView` and arrives here as bindings. That is
/// deliberate: `launchAtLogin` is seeded from `SMAppService` and re-read in the
/// window's `onAppear`, so moving the `@State` into a tab would make it refresh
/// per tab-switch instead of per window-open — and a stale login-item toggle is
/// one the user can act on wrongly.
struct SettingsGeneralTab: View {
    @Bindable var state: AppState
    @Binding var launchAtLogin: Bool
    @Binding var loginItemError: String?
    let updates: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        generalTab
    }

    private var generalTab: some View {
        @Bindable var alerts = state.alerts
        return Form {
            Section {
                Toggle("Launch Ice Cube at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(Theme.warning)
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
                        .font(.caption).foregroundStyle(Theme.warning)
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

    @ViewBuilder
    private var updateStatusView: some View {
        switch updates.status {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text("Up to date").font(.caption).foregroundStyle(.secondary)
        case let .available(version, url): Link("v\(version) available", destination: url).font(.caption)
        case let .failed(message): Text(message).font(.caption).foregroundStyle(Theme.warning)
        }
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
