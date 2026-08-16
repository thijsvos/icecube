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
    /// Default false, deliberately: `object(forKey:) == nil` and "the user
    /// turned it off" are indistinguishable through `@AppStorage`, so a
    /// default-true toggle cannot tell a fresh install from a considered no.
    @AppStorage(MenuBarMode.preferenceKey) private var silentOptionClick = false
    /// Seeded in `onAppear`, not here.
    ///
    /// A `@State` default expression runs on every re-init of the view struct,
    /// and a `Window` scene's content is re-initialised whenever the observed
    /// state it reads changes — which for `AppState` is every poll tick, even
    /// while the Settings window is shut. `SMAppService.mainApp.status` is a
    /// synchronous XPC round-trip to the ServiceManagement daemon, so this line
    /// was making one of those once a second for the life of the process to
    /// compute a value `onAppear` immediately overwrites anyway.
    @State private var launchAtLogin = false
    @State private var loginItemError: String?

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
        case .general:
            SettingsGeneralTab(
                state: state, launchAtLogin: $launchAtLogin,
                loginItemError: $loginItemError, updates: state.updates
            )
        case .menu:
            SettingsMenuTab(state: state, silentOptionClick: $silentOptionClick)
        case .fans:
            SettingsFanControlTab(
                state: state, persistCurve: $persistCurve, openWindow: openWindow
            )
        }
    }
}

/// The one-line summary of whether fan control is actually working, shown in
/// the Fan Control tab.
///
/// On `AppState` rather than derived at the point of use, for the same reason
/// `readingAnimation` is: two copies of a derivation are two things that can
/// later disagree. `FanControlStatusTests` already pins the wording itself.
extension AppState {
    var setupStatusText: String {
        FanControlStatus.summary(
            registration: helper.registration,
            connection: helper.connection
        ).settingsText
    }
}
