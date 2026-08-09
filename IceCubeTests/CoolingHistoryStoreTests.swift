// CoolingHistoryStoreTests.swift — the history file's custody: load, quarantine, read-only, clear.

import Foundation
import IceCubeKit
import Testing

/// The store is the only place cooling records touch the filesystem, and it
/// guards a file that accumulates for years. Every test runs against a unique
/// directory under `temporaryDirectory`, removed afterwards — the
/// `PresetStoreTests` discipline, for the same reason: this bundle is
/// host-less and unsandboxed, so the no-argument initializer would read and
/// write the developer's real data. It never appears here.
@MainActor
@Suite("CoolingHistoryStore — custody of the history file")
struct CoolingHistoryStoreTests {
    private static let epoch = Date(timeIntervalSince1970: 1_753_056_000)
    private static let identity = CoolingHistoryStore.Identity(
        modelIdentifier: "Mac14,9", isSimulated: false, serialNumber: "C02TESTSERIAL"
    )

    /// Runs `body` against a history file in a directory that is removed
    /// afterwards, whatever happens.
    private func withTempFile(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IceCubeHistoryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.appendingPathComponent("cooling-history.json"))
    }

    private func fans() -> [Fan] {
        [0, 1].map {
            Fan(
                id: $0, name: "Fan \($0)", mode: .system,
                actualRPM: 3740, targetRPM: 3740, minRPM: 2317, maxRPM: 6800
            )
        }
    }

    private func record(_ offset: TimeInterval, r: Double = 0.51) -> CoolingRecord {
        CoolingRecord(
            date: Self.epoch.addingTimeInterval(offset), resistance: r,
            dieCelsius: 49, ambientCelsius: 39, watts: 20, band: .decile(5),
            fanFraction: 0.55, fanRPM: 3740, sampleCount: 21, durationSeconds: 20
        )
    }

    // MARK: - The ordinary life

    @Test("A first run is quiet — no file is not a failure")
    func firstRunIsQuiet() throws {
        try withTempFile { file in
            let store = CoolingHistoryStore(file: file, identity: Self.identity, now: Self.epoch)
            #expect(store.history == nil)
            #expect(store.loadFailure == nil)
            #expect(!store.isReadOnly)
            #expect(!FileManager.default.fileExists(atPath: file.path), "loading must not create anything")
        }
    }

    /// The fingerprint is created on the first record — the first moment the
    /// fans are known — and from then on the file survives a relaunch.
    @Test("The first record creates the fingerprint from the snapshot's fans, and it round-trips")
    func firstRecordCreatesAndPersists() throws {
        try withTempFile { file in
            let store = CoolingHistoryStore(file: file, identity: Self.identity, now: Self.epoch)
            store.append(record(0), fans: fans(), now: Self.epoch)

            let machine = try #require(store.history?.machine)
            #expect(machine.fanCount == 2)
            #expect(machine.fanMaxRPM == [6800, 6800])
            #expect(machine.serialHash != nil, "the serial is hashed in")

            let reloaded = CoolingHistoryStore(file: file, identity: Self.identity, now: Self.epoch)
            #expect(reloaded.history?.records.count == 1)
            #expect(reloaded.loadFailure == nil)
        }
    }

    @Test("Clear keeps the identity, empties the readings, and leaves a readable file behind")
    func clearWritesAnEmptyEnvelope() throws {
        try withTempFile { file in
            let store = CoolingHistoryStore(file: file, identity: Self.identity, now: Self.epoch)
            store.append(record(0), fans: fans(), now: Self.epoch)
            let fingerprint = store.history?.machine
            store.clear(now: Self.epoch.addingTimeInterval(60))

            #expect(store.history?.records.isEmpty == true)
            #expect(store.history?.machine == fingerprint, "identity survives a clear")
            // An absent file and a cleared one must be indistinguishable to
            // the next launch — both load, both empty, neither fails.
            let reloaded = CoolingHistoryStore(file: file, identity: Self.identity, now: Self.epoch)
            #expect(reloaded.history?.records.isEmpty == true)
            #expect(reloaded.loadFailure == nil)
        }
    }

    // MARK: - The refusals

    @Test("A corrupt file is quarantined to a fixed name and recording starts fresh")
    func corruptFileIsQuarantined() throws {
        try withTempFile { file in
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("not json".utf8).write(to: file)

            let store = CoolingHistoryStore(file: file, identity: Self.identity, now: Self.epoch)
            #expect(store.history == nil)
            #expect(store.loadFailure == "cooling-history.corrupt.json")
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent("cooling-history.corrupt.json")
            #expect(FileManager.default.fileExists(atPath: backup.path), "the casualty is kept")
            #expect(!FileManager.default.fileExists(atPath: file.path), "and the slot is free")
            #expect(!store.isReadOnly, "recording resumes into a fresh file")
        }
    }

    /// Not corruption: another Mac's measurements, moved aside whole so a
    /// migrated-back machine could recover them by hand. `R` is not
    /// comparable between machines, so loading them would manufacture
    /// exactly the false degradation claim the fingerprint exists to stop.
    @Test("Another Mac's file is set aside as previous-mac, never merged")
    func anotherMacsFileIsSetAside() throws {
        try withTempFile { file in
            let store = CoolingHistoryStore(file: file, identity: Self.identity, now: Self.epoch)
            store.append(record(0), fans: fans(), now: Self.epoch)

            let moved = CoolingHistoryStore(
                file: file,
                identity: .init(modelIdentifier: "Mac14,9", isSimulated: false, serialNumber: "OTHERSERIAL"),
                now: Self.epoch
            )
            #expect(moved.history == nil)
            #expect(moved.loadFailure == "cooling-history.previous-mac.json")
        }
    }

    /// A downgrade meets a newer file: read nothing, and — the part a test
    /// must pin because nothing visible happens — WRITE nothing. The newer
    /// build's data must survive this launch byte-identical.
    @Test("A newer schema pauses recording and never writes")
    func newerSchemaIsReadOnly() throws {
        try withTempFile { file in
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let newer = Data(#"{"schemaVersion": 99, "shape": "unknowable"}"#.utf8)
            try newer.write(to: file)

            let store = CoolingHistoryStore(file: file, identity: Self.identity, now: Self.epoch)
            #expect(store.isReadOnly)
            #expect(store.history == nil)

            store.append(record(0), fans: fans(), now: Self.epoch)
            store.clear(now: Self.epoch)
            #expect(try Data(contentsOf: file) == newer, "not one byte moves under a newer schema")
        }
    }

    // MARK: - Seeding

    /// The seed exists for the simulated graph's demo and must lose to real
    /// data: it applies only when the file is absent.
    @Test("A seed fills an absent file and never replaces an existing one")
    func seedOnlyFillsAnAbsentFile() throws {
        try withTempFile { file in
            let simulated = CoolingHistoryStore.Identity(
                modelIdentifier: SimulatedCoolingHistory.machine.modelIdentifier,
                isSimulated: true,
                serialNumber: nil
            )
            let seed = SimulatedCoolingHistory.seed(.rising, endingAt: Self.epoch)
            let seeded = CoolingHistoryStore(
                file: file, identity: simulated, seed: seed, now: Self.epoch
            )
            let seededCount = seeded.history?.records.count ?? 0
            #expect(seededCount > 0, "an absent file takes the seed")

            seeded.append(record(60), fans: fans(), now: Self.epoch.addingTimeInterval(60))
            let real = seeded.history?.records.count ?? 0

            let reopened = CoolingHistoryStore(
                file: file, identity: simulated, seed: seed, now: Self.epoch.addingTimeInterval(120)
            )
            #expect(
                reopened.history?.records.count == real,
                "an existing file wins over the seed — recorded data is never reset to fiction"
            )
        }
    }
}
