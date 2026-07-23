// SettingsView.swift — the popover's inline settings section (Phase 2: menu bar display options).

import SwiftUI

/// Settings, rendered **inside the popover** rather than in a separate window.
///
/// Deliberate: macOS dismisses a menu-bar popover on any click outside it, so
/// options in a separate window made the popover vanish mid-adjustment (the
/// exact disappearing-UI behavior this project forbids). Inline options keep
/// every click inside the popover — nothing loses focus, nothing disappears,
/// and the menu bar previews the choice live. When settings grow in Phase 5
/// (intervals, units, notifications), a real window can return for the rest.
struct SettingsSection: View {
    /// The shared observable state; owned by `ZephyrApp`.
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Menu bar shows")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Menu bar shows", selection: $state.menuBarDisplay) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .controlSize(.small)
            Text("The fan icon is always shown; this chooses the text beside it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// What text (if any) accompanies the menu bar fan icon.
enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly
    case temperature
    case fanSpeed
    case both

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .temperature: "Hottest temperature"
        case .fanSpeed: "Fan speed"
        case .both: "Temperature and fan speed"
        }
    }
}
