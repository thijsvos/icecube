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
            Divider()
            helperMaintenance
        }
    }

    /// Helper daemon maintenance — the dev/debug controls XCODE_GUIDE §4/§6
    /// references ("Re-register helper" is the #1 fix after a rebuild).
    private var helperMaintenance: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Helper daemon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(helperStateText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
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

    private var helperStateText: String {
        let registration = switch state.helper.registration {
        case .unknown: "unknown"
        case .notRegistered: "not registered"
        case .requiresApproval: "waiting for approval"
        case .enabled: "enabled"
        case .notFound: "not found in bundle"
        }
        let connection = switch state.helper.connection {
        case .disconnected: "disconnected"
        case let .connected(version): "connected (v\(version))"
        case let .versionMismatch(helper): "version mismatch (v\(helper))"
        }
        return "Registration: \(registration) · XPC: \(connection)"
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
