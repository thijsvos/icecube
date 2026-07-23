// SettingsView.swift — the Settings window: menu bar display options (Phase 2 scope).

import SwiftUI

/// App settings. Phase 2 ships the menu-bar display choice; sampling
/// intervals, units, and notification thresholds arrive in Phase 5.
struct SettingsView: View {
    /// The shared observable state; owned by `ZephyrApp`.
    @Bindable var state: AppState

    var body: some View {
        Form {
            Picker("Show in menu bar:", selection: $state.menuBarDisplay) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            Text("The fan icon is always shown; this chooses the text beside it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 340)
        .fixedSize()
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
