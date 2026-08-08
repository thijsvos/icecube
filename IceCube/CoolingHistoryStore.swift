// CoolingHistoryStore.swift — the cooling history's home on disk: load, quarantine, persist, clear.

import Foundation
import IceCubeKit
import Observation
import os

/// Owns `~/Library/Application Support/IceCube/cooling-history.json` — the
/// only place cooling records touch the filesystem. All policy (what gets
/// recorded, retention, the verdict) lives in IceCubeKit; this type is the
/// file seam, shaped after `PresetStore` for the same reasons that file
/// documents at length.
@Observable
final class CoolingHistoryStore {
    /// Who this machine is, for the fingerprint that stops a history
    /// following `~/Library` onto a different Mac. The serial is used only
    /// to compute a salted hash and is never stored or logged.
    struct Identity {
        let modelIdentifier: String
        let isSimulated: Bool
        let serialNumber: String?
    }

    /// Where history lives in a real install — beside `presets.json`, in the
    /// directory README's uninstall section already names.
    static let defaultFile = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("IceCube/cooling-history.json")

    /// The current history, or `nil` before the first record ever (also the
    /// read-only state's value — see ``isReadOnly``).
    private(set) var history: CoolingHistory?

    /// Set when the file could not be read, naming the backup it was moved
    /// to — surfaced beside the trend so a load failure is visible rather
    /// than looking like "you never recorded anything".
    private(set) var loadFailure: String?

    /// True when the on-disk file was written by a newer build. Nothing is
    /// loaded and **nothing is written** — recording pauses for this launch
    /// rather than destroying months of a newer schema's data. Losing a
    /// launch is cheap; losing a year is not.
    private(set) var isReadOnly = false

    /// Injectable for the same reason `PresetStore.file` is: the test bundle
    /// is host-less and unsandboxed, so the default path is the developer's
    /// real data. Tests use a temp directory removed in a `defer`; the
    /// no-argument path never appears in a test.
    private let file: URL

    /// Read by `SimulatedIsolationTests` to prove a simulated run cannot
    /// reach the real file.
    var fileURL: URL {
        file
    }

    private let identity: Identity
    private let log = Logger(subsystem: HelperConstants.logSubsystem, category: "ui")

    /// - Parameters:
    ///   - seed: fabricated history applied **only when the file is absent**.
    ///     Passed exclusively by the simulated graph; the live graph has no
    ///     seed, so no code path puts invented readings in a real file.
    init(
        file: URL = CoolingHistoryStore.defaultFile,
        identity: Identity,
        seed: CoolingHistory? = nil,
        now: Date = Date()
    ) {
        self.file = file
        self.identity = identity
        load(seed: seed, now: now)
    }

    // MARK: - Recording

    /// Appends one settled reading and persists at once. Records arrive at
    /// most every five minutes (`CoolingRecorder.minimumSpacing`), so one
    /// atomic write per record needs no debounce, no timer and no terminate
    /// hook — and a SIGKILL can lose at most the minutes since the last one.
    ///
    /// The fingerprint is created here, on the first record, because that is
    /// the first moment the fans are known — `fans` comes from the same
    /// snapshot the record did.
    func append(_ record: CoolingRecord, fans: [Fan], now: Date) {
        guard !isReadOnly else { return }
        if history == nil {
            history = CoolingHistory(
                machine: MachineFingerprint(
                    modelIdentifier: identity.modelIdentifier,
                    fanCount: fans.count,
                    fanMaxRPM: fans.map { Int($0.maxRPM) },
                    isSimulated: identity.isSimulated,
                    serialNumber: identity.serialNumber
                ),
                createdAt: now
            )
        }
        history?.append(record, now: now)
        persist()
    }

    /// Records an "I cleaned it" boundary; the trend's baseline never spans one.
    func markServiced(at date: Date) {
        guard !isReadOnly, history != nil else { return }
        history?.markServiced(at: date)
        persist()
    }

    /// Deletes every reading, keeping the machine identity. Writes an empty
    /// envelope rather than removing the file — an absent file and a cleared
    /// one must be indistinguishable to the next launch.
    func clear(now: Date = Date()) {
        guard !isReadOnly, let existing = history else { return }
        let count = existing.records.count + existing.days.map(\.count).reduce(0, +)
        history = CoolingHistory(machine: existing.machine, createdAt: now)
        persist()
        loadFailure = nil
        log.notice("cooling history: cleared \(count) readings at the user's request")
    }

    // MARK: - Disk

    private func load(seed: CoolingHistory?, now: Date) {
        guard let data = try? Data(contentsOf: file) else {
            // First run — not an error, and the only moment a seed applies.
            if let seed {
                history = seed
                persist()
            }
            return
        }
        switch CoolingHistory.decode(
            data,
            modelIdentifier: identity.modelIdentifier,
            isSimulated: identity.isSimulated,
            serialNumber: identity.serialNumber
        ) {
        case var .loaded(loaded):
            // Prune on load, so a retention-policy change shrinks existing
            // files at the next launch rather than never.
            loaded.compact(now: now)
            history = loaded
            log
                .notice(
                    "cooling history: loaded \(loaded.records.count) recent readings, \(loaded.days.count) day summaries"
                )
        case let .readOnly(reason):
            isReadOnly = true
            log
                .error(
                    "cooling history: file is from a newer build (\(String(describing: reason), privacy: .public)) — recording paused, nothing overwritten"
                )
        case let .startFresh(reason):
            switch reason {
            case .machineChanged:
                // Not corruption: another Mac's data, moved aside whole so a
                // migrated-back machine could recover it by hand.
                quarantine(to: "cooling-history.previous-mac.json")
            case .unreadable, .schemaTooNew:
                quarantine(to: "cooling-history.corrupt.json")
            }
        }
    }

    /// Moves the unusable file aside — to a **fixed** name, deliberately
    /// unlike `PresetStore`'s timestamped backups: presets are irreplaceable
    /// user work so every copy is kept, while history is regenerable
    /// measurement and only the most recent casualty is diagnostically
    /// interesting. An unbounded pile of quarantine files would be the worse
    /// outcome here.
    private func quarantine(to name: String) {
        let backup = file.deletingLastPathComponent().appendingPathComponent(name)
        do {
            _ = try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: file, to: backup)
            loadFailure = name
            log.error("cooling history: file unreadable — kept a copy at \(name, privacy: .public)")
        } catch {
            // Could not move it: still better to report than to overwrite.
            loadFailure = file.lastPathComponent
            log
                .error(
                    "cooling history: file unreadable and could not be backed up: \(error.localizedDescription, privacy: .public)"
                )
        }
    }

    private func persist() {
        guard let history, !isReadOnly else { return }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try history.encoded().write(to: file, options: .atomic)
        } catch {
            log.error("cooling history: could not save: \(error.localizedDescription, privacy: .public)")
        }
    }
}
