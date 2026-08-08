// SystemSMCProviderTests.swift — the read path's decisions, finally reachable without a Mac.

import Foundation
@testable import IceCubeKit
import Testing

/// A scripted SMC. Answers only the keys it was given, and can be told to fail
/// a specific one — the two shapes every decision in `SystemSMCProvider` turns
/// on.
actor FakeReadPort: SMCReadPort {
    private var values: [String: Double]
    private var strings: [String: String]
    private var types: [String: String]
    private var unreadable: Set<String> = []
    private var allKeys: [String]
    private(set) var reads: [String] = []

    init(
        values: [String: Double] = [:],
        strings: [String: String] = [:],
        types: [String: String] = [:],
        allKeys: [String] = []
    ) {
        self.values = values
        self.strings = strings
        self.types = types
        self.allKeys = allKeys
    }

    func breakRead(_ key: String) {
        unreadable.insert(key)
    }

    func setValue(_ value: Double, for key: String) {
        values[key] = value
    }

    func removeKey(_ key: String) {
        values[key] = nil; strings[key] = nil
    }

    func keyInfo(for key: String) throws(IceCubeError) -> SMCConnection.KeyInfo {
        if unreadable.contains(key) {
            throw IceCubeError.smcCallFailed(key: key, kernReturn: -1)
        }
        guard values[key] != nil || strings[key] != nil else { throw IceCubeError.smcKeyNotFound(key: key) }
        // "flt " — four bytes, space-padded, as the SMC reports it. Writing
        // "flt" here made every sensor fail admission, because
        // `SMCDataType(rawValue:)` could not decode it.
        return SMCConnection.KeyInfo(size: 4, type: types[key] ?? "flt ", attributes: 0)
    }

    func hasKey(_ key: String) -> Bool {
        values[key] != nil || strings[key] != nil
    }

    func readBytes(_ key: String) throws(IceCubeError) -> (bytes: [UInt8], info: SMCConnection.KeyInfo) {
        try ([0, 0, 0, 0], keyInfo(for: key))
    }

    func readDouble(_ key: String) throws(IceCubeError) -> Double {
        reads.append(key)
        if unreadable.contains(key) {
            throw IceCubeError.smcCallFailed(key: key, kernReturn: -1)
        }
        guard let value = values[key] else { throw IceCubeError.smcKeyNotFound(key: key) }
        return value
    }

    func readString(_ key: String) throws(IceCubeError) -> String {
        if unreadable.contains(key) {
            throw IceCubeError.smcCallFailed(key: key, kernReturn: -1)
        }
        guard let text = strings[key] else { throw IceCubeError.smcKeyNotFound(key: key) }
        return text
    }

    func keyCount() throws(IceCubeError) -> Int {
        allKeys.count
    }

    func key(atIndex index: Int) throws(IceCubeError) -> String {
        guard index < allKeys.count else { throw IceCubeError.smcKeyNotFound(key: "#\(index)") }
        return allKeys[index]
    }
}

/// 362 lines at **0 % coverage** until 2026-08-08, and unreachable rather than
/// neglected: the provider held a concrete `SMCConnection`, which opens
/// `AppleSMC` in its initialiser, so there was no way to build one without a
/// Mac.
///
/// PR #62 recorded this as *"a refactor, not a test"* and declined it. That was
/// fair, and it was also fifteen lines — `SMCReadPort`, mirroring the
/// `SMCControlPort` the daemon has had since `SensorReader` was written. The
/// asymmetry is why one was testable and the other was not.
@Suite("SystemSMCProvider — the read path's decisions")
struct SystemSMCProviderTests {
    static func fans(count: Int = 2, mode: String = "Md") -> [String: Double] {
        var values: [String: Double] = ["FNum": Double(count)]
        for i in 0 ..< count {
            values["F\(i)\(mode)"] = 1
            values["F\(i)Ac"] = 3000
            values["F\(i)Tg"] = 3200
            values["F\(i)Mn"] = 2317
            values["F\(i)Mx"] = 6800
        }
        return values
    }

    // MARK: - Fans

    @Test("A fan's fields come through, and its range is usable")
    func fansAreRead() async throws {
        let provider = SystemSMCProvider(connection: FakeReadPort(values: Self.fans()))
        let fans = try await provider.fans()
        #expect(fans.count == 2)
        #expect(fans[0].actualRPM == 3000)
        #expect(fans[0].targetRPM == 3200)
        #expect(fans[0].hasUsableRange)
    }

    /// Per-key degradation, and the fallback is chosen rather than convenient:
    /// a missing *target* falls back to the **actual** speed, not to zero,
    /// because a fan reported as targeting 0 RPM reads as a stopped fan.
    @Test("A missing target falls back to the measured speed, not to zero")
    func missingTargetFallsBackToActual() async throws {
        var values = Self.fans(count: 1)
        values["F0Tg"] = nil
        let provider = SystemSMCProvider(connection: FakeReadPort(values: values))
        let fan = try await #require(provider.fans().first)
        #expect(fan.targetRPM == fan.actualRPM)
    }

    /// SAFETY-relevant. `Mn`/`Mx` each degrade to 0 independently, and
    /// `hasUsableRange` is what stops a fan with a broken floor being driven —
    /// the daemon clamp is the only real guard, so a `0…6800` range would mean
    /// no floor at all.
    @Test("A fan whose minimum did not read is not driveable")
    func brokenFloorIsNotUsable() async throws {
        var values = Self.fans(count: 1)
        values["F0Mn"] = nil
        let provider = SystemSMCProvider(connection: FakeReadPort(values: values))
        let fan = try await #require(provider.fans().first)
        #expect(!fan.hasUsableRange, "0…6800 is not a range, it is a missing floor")
    }

    @Test("A Mac reporting no fans is not an error")
    func zeroFansIsFine() async throws {
        let provider = SystemSMCProvider(connection: FakeReadPort(values: ["FNum": 0]))
        #expect(try await provider.fans().isEmpty)
    }

    @Test("The mode key is found under either spelling", arguments: ["Md", "md"])
    func modeKeyCasing(suffix: String) async throws {
        let provider = SystemSMCProvider(connection: FakeReadPort(values: Self.fans(count: 1, mode: suffix)))
        #expect(try await provider.fans().first?.mode == .forced)
    }

    /// Two fans on a laptop are Left and Right; anything else is numbered. The
    /// off-by-one is deliberate and worth pinning, because the daemon numbers
    /// them differently and the two have been confused before.
    @Test("Two fans are named by side, and more are numbered from one")
    func fanNaming() async throws {
        let two = SystemSMCProvider(connection: FakeReadPort(values: Self.fans(count: 2)))
        #expect(try await two.fans().map(\.name) == ["Left", "Right"])

        let three = SystemSMCProvider(connection: FakeReadPort(values: Self.fans(count: 3)))
        #expect(try await three.fans().first?.name == "Fan 1")
    }

    // MARK: - Power

    /// The rule that makes the power reading trustworthy: a candidate must
    /// **exist and read plausibly**. Of the 79 `P***` keys on Mac14,9 only 38
    /// carry a live value, so presence alone would happily latch onto one
    /// reading 0 W forever while looking like it had worked.
    @Test("A power key that exists but reads implausibly is not chosen")
    func implausiblePowerKeyIsRejected() async throws {
        let port = FakeReadPort(values: ["PSTR": 0, "PDTR": 28.9])
        #expect(try await SystemSMCProvider(connection: port).power() == 28.9, "0 W is not a reading")
    }

    @Test("The first plausible candidate wins")
    func firstPlausibleCandidateWins() async throws {
        let port = FakeReadPort(values: ["PSTR": 19.6, "PDTR": 28.9])
        #expect(try await SystemSMCProvider(connection: port).power() == 19.6)
    }

    /// `nil` is a real answer — a Mac with no usable power key has no wattage
    /// to show, and the app omits the figure rather than inventing one.
    @Test("A Mac with no usable power key reports nothing, and does not fail")
    func noPowerKeyIsNil() async throws {
        let port = FakeReadPort(values: ["PSTR": 0, "PDTR": 0])
        #expect(try await SystemSMCProvider(connection: port).power() == nil)
    }

    /// The resolution is latched, so one unlucky read must not un-resolve a key
    /// that was already proven good.
    @Test("One implausible read does not disown a resolved power key")
    func resolvedPowerKeySurvivesABadRead() async throws {
        let port = FakeReadPort(values: ["PSTR": 19.6])
        let provider = SystemSMCProvider(connection: port)
        #expect(try await provider.power() == 19.6)

        await port.setValue(0, for: "PSTR")
        let second = try await provider.power()
        #expect(second == nil || second == 0, "the key stays resolved; only this reading is unusable")
    }

    // MARK: - Sensors

    @Test("A Mac with curated sensors reports them")
    func curatedSensorsAreRead() async throws {
        var values = Self.fans()
        values["Tp01"] = 55
        values["Tg0f"] = 50
        values["TaLP"] = 40
        let provider = SystemSMCProvider(connection: FakeReadPort(values: values))
        let temps = try await provider.temperatures()
        #expect(temps.contains { $0.key == "Tp01" })
    }

    /// Discovery treats "no such key" as an **answer** and anything else as a
    /// failure that must **propagate** — because caching a sensor set built
    /// from a transport hiccup would disown real sensors for the life of the
    /// process, and the list is cached exactly once.
    ///
    /// The first version of this test asserted the opposite, that the sensor
    /// was quietly dropped. The code is right and the test was wrong: dropping
    /// it is precisely the per-launch lottery the existence-based admission
    /// rule was written to end.
    @Test("A transport failure during discovery propagates rather than truncating the set")
    func transportFailurePropagates() async throws {
        var values = Self.fans()
        values["Tp01"] = 55
        values["Tg0f"] = 50
        let port = FakeReadPort(values: values)
        await port.breakRead("Tp01")

        let provider = SystemSMCProvider(connection: port)
        await #expect(throws: IceCubeError.self) { try await provider.temperatures() }
    }

    // NOT TESTED: the enumeration fallback for an unmapped Mac.
    //
    // `performSensorDiscovery` picks the curated map via
    // `HostInfo.modelIdentifier()`, a bare `sysctlbyname` with no seam — so on
    // the M2 this suite runs on, the curated branch always wins and the
    // fallback is unreachable. Faking it would mean asserting against a path
    // the test cannot actually enter.
    //
    // Injecting the model is a second, smaller seam (`model: @Sendable () ->
    // String`, defaulted) and it would unlock this branch plus every non-M2
    // shape. Recorded rather than quietly skipped.
}
