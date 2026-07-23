// PresetStore.swift — built-in presets (Auto/Quiet/Balanced/Max) + user presets persisted as JSON.

import Foundation
import IceCubeKit
import Observation
import os

/// The preset catalog: four fixed built-ins plus user-saved curves, stored at
/// `~/Library/Application Support/IceCube/presets.json` (app-side; the daemon
/// has its own root-owned store for the active config).
@MainActor
@Observable
final class PresetStore {
    /// The four built-ins, in display order.
    static let builtins: [Preset] = [
        Preset(name: "Auto", kind: .auto, config: .auto),
        Preset(name: "Quiet", kind: .quiet, config: .curve(.quiet)),
        Preset(name: "Balanced", kind: .balanced, config: .curve(.balanced)),
        Preset(name: "Cold", kind: .cold, config: .curve(.cold)),
        Preset(name: "Max", kind: .max, config: .curve(.max)),
    ]

    private(set) var userPresets: [Preset] = []

    private static let file = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IceCube/presets.json")
    private let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "ui")

    init() {
        load()
    }

    /// Saves the given curve under a user preset name (replaces same-name).
    func saveUserPreset(named name: String, curve: FanCurve) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        userPresets.removeAll { $0.name == trimmed }
        userPresets.append(Preset(name: trimmed, kind: .custom, config: .curve(curve)))
        persist()
    }

    func removeUserPreset(_ preset: Preset) {
        userPresets.removeAll { $0.id == preset.id }
        persist()
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        do {
            userPresets = try JSONDecoder().decode([Preset].self, from: data)
                .filter { $0.config.mode != .manual } // manual presets are forbidden
        } catch {
            log.error("presets.json unreadable (\(error.localizedDescription, privacy: .public)) — starting empty")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(userPresets).write(to: Self.file, options: .atomic)
        } catch {
            log.error("could not save presets: \(error.localizedDescription, privacy: .public)")
        }
    }
}
