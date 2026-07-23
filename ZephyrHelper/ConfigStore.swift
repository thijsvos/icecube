// ConfigStore.swift — daemon-side persistence: the curve config that survives reboot (root-owned, atomic).

import Foundation
import os
import ZephyrKit

/// Persists the daemon's curve config at `/Library/Application Support/Zephyr/`
/// (PLAN.md §4.3.7): root-owned, atomic replace, versioned schema.
///
/// Rules:
/// - Only **curve** configs with `persistsWithoutApp == true` are ever saved —
///   manual mode never persists (safety invariant), and a non-persistent curve
///   must die with the daemon.
/// - Anything invalid, corrupt, or from a future schema loads as `nil` → the
///   daemon starts in auto. A broken file must cost the boot promise, never
///   safety.
enum ConfigStore {
    private static let directory = URL(fileURLWithPath: "/Library/Application Support/Zephyr")
    private static let file = directory.appendingPathComponent("config.json")
    private static let log = Logger(subsystem: "io.github.thijsvos.zephyr", category: "curve")

    private struct Envelope: Codable {
        let schemaVersion: Int
        let config: FanConfig
    }

    /// Saves `config` if it qualifies for persistence; clears otherwise.
    static func save(_ config: FanConfig) {
        guard config.mode == .curve, config.persistsWithoutApp, config.isUsableCurveConfig else {
            clear()
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Envelope(schemaVersion: 1, config: config))
            // Atomic: write a temp file, then rename over the target.
            let temp = directory.appendingPathComponent("config.json.tmp")
            try data.write(to: temp, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
            log.notice("persisted curve config (survives reboot)")
        } catch {
            log.error("could not persist config: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The persisted config, or `nil` when absent/invalid (auto is the answer).
    static func load() -> FanConfig? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1,
              envelope.config.mode == .curve,
              envelope.config.persistsWithoutApp,
              envelope.config.isUsableCurveConfig
        else {
            log.error("persisted config invalid or from an unknown schema — ignoring it (starting in auto)")
            clear()
            return nil
        }
        return envelope.config
    }

    /// Removes the persisted config (revert-to-auto, unregister, corruption).
    static func clear() {
        try? FileManager.default.removeItem(at: file)
    }
}
