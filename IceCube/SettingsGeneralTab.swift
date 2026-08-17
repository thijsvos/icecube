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
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion

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
                // A separate switch from the threshold above, on purpose. That
                // one asks "tell me when the Mac is hot"; this one asks "tell me
                // when Ice Cube stopped being able to do anything about it".
                // Someone can reasonably want the second without the first.
                Toggle("Tell me if fan control stops working", isOn: $alerts.reportsControlLoss)
                    .help(
                        "The daemon handing the fans back, a failed write, Ice Cube having to cool "
                            + "the Mac itself, or the fans stuck at maximum for 45 minutes. "
                            + "Grouped so a busy afternoon is one notification, not ten."
                    )
                if state.alerts.permissionDenied {
                    Text("Notifications are denied — allow Ice Cube in System Settings → Notifications.")
                        .font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Section("Updates") {
                LabeledContent("Version", value: UpdateChecker.currentVersion)
                // Opt-out, not opt-in: an unsigned build installed by hand has
                // no other route to telling its user a fix exists. It is one
                // request a day and never downloads anything.
                Toggle("Check for updates automatically", isOn: Bindable(updates).automaticChecksEnabled)
                    .help("One check a day against GitHub Releases. Ice Cube never downloads or installs on its own.")
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
            // The one place an experimental feature can be switched on. Off by
            // default, and while it is off nothing anywhere else offers a route
            // to the window — a feature reachable without this switch would not
            // be experimental, it would just be undocumented.
            Section("Experimental") {
                Toggle("Inside — a live view of the cooling", isOn: $state.isInsideEnabled)
                    .help("Draws the heat path: silicon, blowers and airflow, at this instant.")
                Text(
                    "A picture of where the heat is and whether it is leaving. "
                        + "It redraws continuously while open, so it is off unless you want it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if state.isInsideEnabled {
                    Toggle("Animate the fans and airflow", isOn: Binding(
                        get: { state.insideAnimation ?? !systemReducesMotion },
                        set: { state.insideAnimation = $0 }
                    ))
                    .help("The blowers turn and the air moves. Off draws the same picture, held still.")
                    if systemReducesMotion {
                        // Worth saying out loud: otherwise the switch above
                        // looks broken to the one group of people whose system
                        // setting is quietly overriding it.
                        Text(
                            "Reduce Motion is on in System Settings, so this starts off. "
                                + "Turning it on here applies to this window only."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Button("Open Inside…") {
                        WindowOpener.open(WindowOpener.ID.inside, using: openWindow)
                    }
                    .controlSize(.small)
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
