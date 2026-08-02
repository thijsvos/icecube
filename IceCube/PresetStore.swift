// PresetStore.swift — built-in presets (Quiet/Balanced/Cold/Max) + user presets persisted as JSON.

import Foundation
import IceCubeKit
import Observation
import os

/// The preset catalog: four fixed built-ins plus user-saved curves, stored at
/// `~/Library/Application Support/IceCube/presets.json` (app-side; the daemon
/// has its own root-owned store for the active config).
@Observable
final class PresetStore {
    /// The four built-ins, in display order.
    ///
    /// Every built-in means "Ice Cube is driving". There used to be a "macOS"
    /// entry here that meant the opposite — hand the fans back — and it was a
    /// persistent source of confusion no amount of naming fixed: first renamed
    /// from "Auto", then fenced off behind a divider, then removed (2026-07-26).
    /// Nobody installs a fan-control app to hand the fans to macOS, and the
    /// honest version of that action is removing the daemon, which lives in
    /// Settings -> "Turn Off Fan Control".
    static let builtins: [Preset] = [
        Preset(name: "Quiet", kind: .quiet, config: .curve(.quiet)),
        Preset(name: "Balanced", kind: .balanced, config: .curve(.balanced)),
        Preset(name: "Cold", kind: .cold, config: .curve(.cold)),
        Preset(name: "Max", kind: .max, config: .curve(.max)),
    ]

    private(set) var userPresets: [Preset] = []

    /// Set when `presets.json` could not be read, naming the backup we moved it
    /// to. The Curves window surfaces this so a load failure is visible rather
    /// than looking like "you never saved anything".
    private(set) var loadFailure: String?

    /// Bumped only when the on-disk shape changes incompatibly.
    private static let schemaVersion = 1

    /// The persisted shape. Versioned so a future field can be migrated instead
    /// of silently failing to decode — the previous format was a bare
    /// `[Preset]` with no version at all, which `load()` still accepts.
    private struct Envelope: Codable {
        let schemaVersion: Int
        let presets: [Preset]
    }

    /// Where presets live in a real install.
    static let defaultFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IceCube/presets.json")

    /// The file this store reads and writes. Injectable for the same reason
    /// `FanControlMemory` takes a ``KeyValueStore``: without a seam there is no
    /// way to exercise this type that does not touch the developer's own data.
    ///
    /// It was worse than untestable. `init()` loads unconditionally, the test
    /// bundle is host-less and unsandboxed, so `.applicationSupportDirectory`
    /// resolves to the real `~/Library/Application Support` — a test calling
    /// `saveUserPreset` would have overwritten the owner's saved curves, and the
    /// corrupt-file test would have moved them to `presets.corrupt-*.json`.
    ///
    /// Tests point this at a unique directory under `temporaryDirectory` and
    /// delete it afterwards. That makes them the first filesystem-touching tests
    /// in the project, which is a deliberate exception rather than a drift: the
    /// no-IO rule exists because `UserDefaults(suiteName:)` left 1,097 plists in
    /// `~/Library/Preferences` that nothing could clean up, and a temp directory
    /// removed in the same test is not that. A `PresetFileStoring` protocol
    /// would have preserved zero-IO, but it moves `moveItem` and
    /// `createDirectory` out of this type — and those are two of the four
    /// branches worth testing.
    private let file: URL

    /// Which file this store is bound to. Read by `SimulatedIsolationTests` to
    /// prove a simulated run cannot reach the owner's real catalog.
    var fileURL: URL {
        file
    }

    /// `HelperConstants.logSubsystem`, not the literal: under test this resolves
    /// to a separate subsystem.
    ///
    /// These files are compiled into the test bundle, so without it a
    /// `swift`/`xcodebuild test` run writes lines like "startup: applying curve
    /// config" into the SAME log a real investigation reads — which already cost
    /// two misdiagnoses this project.
    private let log = Logger(subsystem: HelperConstants.logSubsystem, category: "ui")

    init(file: URL = PresetStore.defaultFile) {
        self.file = file
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
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        // Current format first, then the original un-versioned `[Preset]` so
        // existing installs keep their curves across this change.
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            userPresets = envelope.presets.filter { $0.config.mode != .manual }
            return
        }
        if let legacy = try? decoder.decode([Preset].self, from: data) {
            userPresets = legacy.filter { $0.config.mode != .manual }
            persist() // migrate forward so the next read takes the fast path
            return
        }
        // SAFETY FOR USER DATA: do NOT leave the file in place to be silently
        // overwritten by the next `persist()`. That turned one unreadable file
        // into permanent, invisible loss of every saved curve. Move it aside so
        // it is recoverable, and surface that in the UI.
        quarantineUnreadableFile()
    }

    private func quarantineUnreadableFile() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = file.deletingLastPathComponent()
            .appendingPathComponent("presets.corrupt-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: file, to: backup)
            loadFailure = backup.lastPathComponent
            log.error("presets.json unreadable — kept a copy at \(backup.lastPathComponent, privacy: .public)")
        } catch {
            // Could not move it: still better to report than to overwrite.
            loadFailure = file.lastPathComponent
            log
                .error(
                    "presets.json unreadable and could not be backed up: \(error.localizedDescription, privacy: .public)"
                )
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let envelope = Envelope(schemaVersion: Self.schemaVersion, presets: userPresets)
            try JSONEncoder().encode(envelope).write(to: file, options: .atomic)
        } catch {
            log.error("could not save presets: \(error.localizedDescription, privacy: .public)")
        }
    }
}
