// CoolingHistoryCodingTests.swift — the history file across versions, machines and corruption.

import Foundation
@testable import IceCubeKit
import Testing

/// The file outlives builds, survives Migration Assistant, and gets hand-read
/// when a verdict is disputed. Every way loading can go — including the ways
/// that must refuse — is pinned here.
@Suite("CoolingHistory coding — the file, across versions and across machines")
struct CoolingHistoryCodingTests {
    private static let epoch = Date(timeIntervalSince1970: 1_753_056_000)

    private func makeHistory(serial: String? = "C02TESTSERIAL") -> CoolingHistory {
        let machine = MachineFingerprint(
            modelIdentifier: "Mac14,9", fanCount: 2, fanMaxRPM: [6800, 6800],
            isSimulated: false, serialNumber: serial, salt: "a1b2"
        )
        var history = CoolingHistory(machine: machine, createdAt: Self.epoch)
        for day in 0 ..< 20 {
            for hour in [9.0, 15.0] {
                let date = Self.epoch.addingTimeInterval(Double(day) * 86400 + hour * 3600)
                let record = CoolingRecord(
                    date: date, resistance: 0.913, dieCelsius: 66.7, ambientCelsius: 46.8,
                    watts: 24, band: .decile(8), fanFraction: 0.875, fanRPM: 5950,
                    sampleCount: 21, durationSeconds: 20
                )
                history.append(record, now: date)
            }
        }
        history.markServiced(at: Self.epoch.addingTimeInterval(5 * 86400))
        return history
    }

    private func decode(
        _ data: Data,
        model: String = "Mac14,9",
        simulated: Bool = false,
        serial: String? = "C02TESTSERIAL"
    )
        -> CoolingHistory.LoadOutcome
    {
        CoolingHistory.decode(
            data, modelIdentifier: model, isSimulated: simulated, serialNumber: serial
        )
    }

    /// Rewrites one top-level JSON field, for version/tamper scenarios.
    private func rewriting(_ data: Data, key: String, to value: Any) throws -> Data {
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("A full history round-trips unchanged")
    func fullHistoryRoundTrips() throws {
        let history = makeHistory()
        let outcome = try decode(history.encoded())
        #expect(outcome == .loaded(history))
    }

    /// The forward-compat contract: every post-v1 field is Optional with a
    /// default, so a newer same-version file still decodes on this build.
    @Test("An unknown field from a newer build is ignored")
    func unknownFieldIsIgnored() throws {
        let data = try rewriting(makeHistory().encoded(), key: "futureField", to: "ignored")
        guard case .loaded = decode(data) else {
            Issue.record("an unknown key must not make the file unreadable")
            return
        }
    }

    /// An old build meeting a new file is a downgrade or a stale copy in
    /// /Applications. Overwriting would destroy months of history to save
    /// one launch of recording — losing a launch is cheap, losing a year is
    /// not. Falling through to `.startFresh` here is the mutation this test
    /// exists to catch.
    @Test("A newer schema is read-only, never overwritten and never quarantined")
    func newerSchemaIsReadOnly() throws {
        let data = try rewriting(makeHistory().encoded(), key: "schemaVersion", to: 2)
        #expect(decode(data) == .readOnly(.schemaTooNew(2)))
    }

    @Test("Corrupt JSON starts fresh rather than throwing")
    func corruptJSONStartsFresh() {
        let garbage = Data("not json {]".utf8)
        #expect(decode(garbage) == .startFresh(.unreadable))
    }

    /// The highest-stakes decision in the schema. `R` is not comparable
    /// between machines, so a history that followed `~/Library` through
    /// Migration Assistant would produce exactly the catastrophic false
    /// claim — "30 % worse" about a Mac that changed, not degraded.
    @Test("A history from another Mac is never merged")
    func anotherMacsHistoryIsNeverMerged() throws {
        let data = try makeHistory().encoded()
        // The model identifier carries the fan configuration with it, so a
        // different Mac is caught here; fanCount is deliberately not matched
        // (it is unknowable at load time and a read glitch must not
        // quarantine a year of history).
        #expect(decode(data, model: "Mac15,6") == .startFresh(.machineChanged))
        // A same-model restore — a warranty replacement — is caught by the
        // salted serial hash, because that new Mac is precisely the one most
        // likely to inherit a degraded baseline it does not deserve.
        #expect(decode(data, serial: "DIFFERENT") == .startFresh(.machineChanged))
    }

    /// The asymmetry is deliberate: an IOKit serial read that fails for one
    /// launch must degrade to "same machine", not destroy the history the
    /// hash exists to protect.
    @Test("An unreadable serial does not quarantine the file")
    func unreadableSerialStillLoads() throws {
        let data = try makeHistory().encoded()
        guard case .loaded = decode(data, serial: nil) else {
            Issue.record("a nil serial must fall back to the weaker match, not refuse")
            return
        }
    }

    @Test("A simulated history and a real one never mix")
    func simulatedAndRealNeverMix() throws {
        let data = try makeHistory().encoded()
        #expect(decode(data, simulated: true) == .startFresh(.machineChanged))
    }

    @Test("Dates encode as whole epoch seconds and survive a round trip")
    func datesEncodeAsEpochSeconds() throws {
        let history = makeHistory()
        let data = try history.encoded()
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("1753056000"), "createdAt as raw epoch seconds, greppable")
        guard case let .loaded(decoded) = decode(data) else {
            Issue.record("round trip failed")
            return
        }
        #expect(decoded.createdAt == history.createdAt)
        #expect(decoded.records.map(\.date) == history.records.map(\.date))
    }

    @Test("The salted hash never stores the serial, and matches only with the file's own salt")
    func serialHashIsSaltedAndOpaque() throws {
        let history = makeHistory()
        let text = try #require(try String(data: history.encoded(), encoding: .utf8))
        #expect(!text.contains("C02TESTSERIAL"), "the serial itself must never reach the file")
        let hashed = MachineFingerprint.hash(serialNumber: "C02TESTSERIAL", salt: "a1b2")
        #expect(history.machine.serialHash == hashed)
        #expect(
            MachineFingerprint.hash(serialNumber: "C02TESTSERIAL", salt: "ffff") != hashed,
            "a different salt is a different hash — the salt is doing its job"
        )
    }
}
