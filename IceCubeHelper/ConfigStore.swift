// ConfigStore.swift — daemon-side persistence: the curve config that survives reboot (root-owned, atomic).

import Foundation
import IceCubeKit
import os

/// Persists the daemon's curve config at `/Library/Application Support/IceCube/`
/// (PLAN.md §4.3.7): root-owned, atomic replace, versioned schema.
///
/// Rules:
/// - Only **curve** configs with `persistsWithoutApp == true` are ever saved —
///   manual mode never persists (safety invariant), and a non-persistent curve
///   must die with the daemon.
/// - Anything invalid, corrupt, or from a future schema loads as `nil` → the
///   daemon starts in auto. A broken file must cost the boot promise, never
///   safety.
struct ConfigStore: FanConfigStoring {
    private static let directory = URL(fileURLWithPath: "/Library/Application Support/IceCube")
    private static let file = Self.directory.appendingPathComponent("config.json")
    private static let log = Logger(subsystem: HelperConstants.logSubsystem, category: "curve")

    private struct Envelope: Codable {
        let schemaVersion: Int
        let config: FanConfig
    }

    /// Saves `config` if it qualifies for persistence; clears otherwise.
    func save(_ config: FanConfig) {
        guard config.mode == .curve, config.persistsWithoutApp, config.isUsableCurveConfig else {
            clear()
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: Self.directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755] // root-owned, not group/other-writable
            )
            let data = try JSONEncoder().encode(Envelope(schemaVersion: 1, config: config))
            // Atomic: write a temp file, then rename over the target.
            let temp = Self.directory.appendingPathComponent("config.json.tmp")
            try data.write(to: temp, options: [])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            _ = try FileManager.default.replaceItemAt(Self.file, withItemAt: temp)
            Self.log.notice("persisted curve config (survives reboot)")
        } catch {
            Self.log.error("could not persist config: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The persisted config, or `nil` when absent/invalid (auto is the answer).
    ///
    /// SECURITY: this runs as root at boot, before the app exists, so it will
    /// not trust a file that isn't root-owned and locked-down. On a machine
    /// where an admin loosened `/Library/Application Support` to group-writable,
    /// a non-root user could otherwise plant a config the daemon runs at boot.
    /// (The blast radius is bounded anyway — a poisoned curve still can't
    /// exceed the clamp or the ceiling — but flying-blind-trust is avoidable.)
    func load() -> FanConfig? {
        guard Self.isTrustworthy(Self.file) else {
            Self.log.error("persisted config is not root-owned / is writable by others — ignoring it")
            clear()
            return nil
        }
        guard let data = try? Data(contentsOf: Self.file) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1,
              envelope.config.mode == .curve,
              envelope.config.persistsWithoutApp,
              envelope.config.isUsableCurveConfig
        else {
            Self.log.error("persisted config invalid or from an unknown schema — ignoring it (starting in auto)")
            clear()
            return nil
        }
        return envelope.config
    }

    /// Removes the persisted config (revert-to-auto, unregister, corruption).
    func clear() {
        try? FileManager.default.removeItem(at: Self.file)
    }

    /// True only if `url` and its parent directory are owned by root (uid 0)
    /// and carry no group/other write bits — i.e. no non-root user could have
    /// tampered with what we're about to trust as root.
    private static func isTrustworthy(_ url: URL) -> Bool {
        func ok(_ path: String) -> Bool {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let owner = attrs[.ownerAccountID] as? NSNumber,
                  let perms = attrs[.posixPermissions] as? NSNumber else { return false }
            return owner.intValue == 0 && (perms.int16Value & 0o022) == 0
        }
        // Missing file is fine (→ no config); only a *present* file must be safe.
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return ok(url.path) && ok(url.deletingLastPathComponent().path)
    }
}
