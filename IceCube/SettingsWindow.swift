// SettingsWindow.swift — the settings window: a custom tab bar with per-tab window sizing.

import IceCubeKit
import ServiceManagement
import SwiftUI

/// Settings as three tabs — General, Menu, Fan Control.
///
/// A custom toolbar-style tab bar (so the selection styling is ours, not the
/// system-accent segmented control) sits above the single current pane, and
/// the window sizes to that pane's natural height — so it resizes to fit each
/// tab with no scroll and no empty space. Relies on the window's
/// `.windowResizability(.contentSize)`.
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
        // `launchAtLogin` seeds from SMAppService at view-init only, and this
        // window's view can outlive a change made elsewhere — System Settings →
        // Login Items, or a failed registration. Re-reading on appear keeps the
        // toggle from displaying (and then acting on) a stale value.
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
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
            // Was "Helper daemon" with Re-register / Unregister buttons and a
            // status reading "not registered · disconnected". Every word of
            // that describes the implementation. The actions are legitimate —
            // one turns fan control off, one repairs it — they just had names
            // only the author could parse.
            Section("Fan Control Setup") {
                LabeledContent("Status", value: setupStatusText)
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
                    Button("Turn Off Fan Control") {
                        Task { await state.helper.unregister() }
                    }
                    .help("Fans go back to being managed by macOS. Monitoring keeps working.")
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

    // MARK: - Shared bits

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

    /// The one-line answer to "is fan control working?", in plain language.
    private var setupStatusText: String {
        switch state.helper.registration {
        case .enabled:
            switch state.helper.connection {
            case .connected: "On"
            case .versionMismatch: "Update needed"
            case .disconnected: "Starting up…"
            }
        case .requiresApproval: "Waiting for your approval"
        case .notRegistered, .unknown: "Off"
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

    /// "Does fan control actually work on this Mac?" — answerable, at last.
    ///
    /// Worth a button rather than only running in the background: Ice Cube's
    /// write path is verified on exactly one machine, and on any other the
    /// honest answer until now was a shrug. The check writes each fan's current
    /// target back to itself and reverts, so pressing it changes nothing you
    /// can hear.
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

    /// Reflects/sets the active built-in preset (mirrors the menu's preset row).
    ///
    /// Tagged on ``Preset/Kind`` rather than the display name, so renaming a
    /// built-in can't silently break the picker.
    private var presetBinding: Binding<Preset.Kind> {
        Binding(
            get: {
                // Nothing applied yet lands on "Custom", the picker's catch-all
                // row. It used to fall back to `.auto`, which stopped being a
                // preset when macOS mode was removed — and "Custom" is the
                // honest label for "not one of the built-ins" anyway.
                guard state.helper.lastAppliedConfig != nil else { return .custom }
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
