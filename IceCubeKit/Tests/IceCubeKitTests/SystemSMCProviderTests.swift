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

    /// `Int(someDouble)` is a trapping conversion: NaN, ±infinity and anything
    /// past `Int.max` crash the process rather than throwing. `FNum` comes
    /// straight off firmware, and this is the app's read path, so the crash
    /// would be the UI dying on a bad reading with no way for the user to tell
    /// why. The daemon's `SensorReader.readFans()` has guarded the identical
    /// read since it was written, with a comment saying why; this copy was
    /// written as `Int(try await connection.readDouble("FNum"))`.
    @Test(
        "A garbage fan count throws instead of trapping",
        arguments: [Double.nan, .infinity, -.infinity, 1e30, -1, 65]
    )
    func garbageFanCountThrows(raw: Double) async {
        let provider = SystemSMCProvider(connection: FakeReadPort(values: ["FNum": raw]))
        await #expect(throws: IceCubeError.self) {
            try await provider.fans()
        }
    }

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

    /// The model is **pinned**, and that is the point of the test rather than
    /// a detail of it. With `HostInfo.modelIdentifier()` read straight from
    /// `sysctl`, this test and the next one passed on the owner's Mac14,9 and
    /// failed on CI, whose model has no curated map and so fell through to
    /// enumeration. A test whose branch depends on the machine running it is
    /// not pinning anything.
    @Test("A Mac with a curated map reports the curated sensors")
    func curatedSensorsAreRead() async throws {
        var values = Self.fans()
        values["Tp01"] = 55
        values["Tp05"] = 54
        values["Tg0f"] = 50
        values["TaLP"] = 40
        let provider = SystemSMCProvider(connection: FakeReadPort(values: values), model: { "Mac14,9" })
        let temps = try await provider.temperatures()
        #expect(temps.contains { $0.key == "Tp01" })
        #expect(temps.contains { $0.key == "TaLP" }, "airflow is curated too, not only the die")
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

        let provider = SystemSMCProvider(connection: port, model: { "Mac14,9" })
        await #expect(throws: IceCubeError.self) { try await provider.temperatures() }
    }

    // MARK: - The enumeration fallback

    /// Every Mac the curated maps do not name — which is most of them, and
    /// every Mac released after the map was last edited. Unreachable in tests
    /// until the model was injected, so the path most users on unmapped
    /// hardware actually take was the one path never exercised.
    @Test("An unmapped Mac falls back to enumerating the SMC")
    func unmappedMacEnumerates() async throws {
        let port = FakeReadPort(
            values: ["TxyZ": 61, "Fake": 99],
            allKeys: ["TxyZ", "Fake"]
        )
        let provider = SystemSMCProvider(connection: port, model: { "Mac99,9" })
        let temps = try await provider.temperatures()
        #expect(temps.map(\.key) == ["TxyZ"], "only T-prefixed keys are temperatures")
    }

    /// Enumeration is a guess, so it filters on all three of prefix, type and
    /// plausibility. Dropping any one of them puts a number on screen that is
    /// not a temperature — the failure mode this app cannot afford, since a
    /// bogus reading drives a curve.
    @Test("Enumeration rejects a T-key that is not a plausible float temperature")
    func enumerationFiltersOnTypeAndPlausibility() async throws {
        let port = FakeReadPort(
            values: ["TxyZ": 61, "Tbad": 900, "Tint": 44],
            types: ["Tint": "ui16"],
            allKeys: ["TxyZ", "Tbad", "Tint"]
        )
        let provider = SystemSMCProvider(connection: port, model: { "Mac99,9" })
        let temps = try await provider.temperatures()
        #expect(temps.map(\.key) == ["TxyZ"], "900 °C is not plausible and a ui16 is not a temperature")
    }

    /// The threshold that decides between the two branches. A curated map that
    /// matches fewer than three keys does not describe this machine, so the
    /// enumeration fallback is better than three labelled sensors and nothing
    /// else — this used to fire on a badly-timed probe and drop a
    /// well-mapped Mac to raw-key labels, which is why admission is now by
    /// existence.
    @Test("A curated map matching fewer than three keys is abandoned for enumeration")
    func thinCuratedMapFallsThrough() async throws {
        let port = FakeReadPort(
            values: ["Tp01": 55, "Tg0f": 50, "TxyZ": 61],
            allKeys: ["Tp01", "Tg0f", "TxyZ"]
        )
        let provider = SystemSMCProvider(connection: port, model: { "Mac14,9" })
        let temps = try await provider.temperatures()
        #expect(temps.contains { $0.key == "TxyZ" }, "an uncurated key can only come from enumeration")
    }

    /// The labels are the tell: curated sensors carry human names, enumerated
    /// ones can only carry the raw key, because nothing knows what they are.
    @Test("Enumerated sensors are labelled with the raw key, curated ones with a name")
    func labelsDistinguishTheBranches() async throws {
        var curatedValues = Self.fans()
        for key in ["Tp01", "Tp05", "Tg0f", "TaLP"] {
            curatedValues[key] = 50
        }
        let curated = SystemSMCProvider(connection: FakeReadPort(values: curatedValues), model: { "Mac14,9" })
        let named = try await #require(curated.temperatures().first { $0.key == "Tp01" })
        #expect(named.label != named.key, "a curated sensor has a name")

        let port = FakeReadPort(values: ["TxyZ": 61], allKeys: ["TxyZ"])
        let enumerated = SystemSMCProvider(connection: port, model: { "Mac99,9" })
        let raw = try await #require(enumerated.temperatures().first)
        #expect(raw.label == raw.key, "nothing knows what TxyZ is, so it must not pretend")
    }

    /// The test that actually pins the injected model, and it took a mutation
    /// to find that the others did not.
    ///
    /// Hardcoding the model back to `"Mac14,9"` — reintroducing exactly the bug
    /// this seam was added to fix — left all five tests above green, because an
    /// unmapped Mac probed against the wrong curated map matches almost nothing,
    /// drops under the three-key threshold, and falls through to enumeration.
    /// Right answer, wrong reason, and no test could tell.
    ///
    /// So: a Mac whose keys **do** match a curated map, that is **not** that
    /// model. Consulting the model gives raw-key labels; ignoring it gives
    /// Mac14,9's human names for a machine that is not a Mac14,9.
    @Test("An unmapped Mac is not given another Mac's sensor names")
    func unmappedMacDoesNotBorrowLabels() async throws {
        let keys = ["Tp01", "Tp05", "Tg0f", "TaLP"]
        let port = FakeReadPort(
            values: Dictionary(uniqueKeysWithValues: keys.map { ($0, 50.0) }),
            allKeys: keys
        )
        let temps = try await SystemSMCProvider(connection: port, model: { "Mac99,9" }).temperatures()
        #expect(temps.count == 4)
        #expect(
            temps.allSatisfy { $0.label == $0.key },
            "these are Mac14,9's keys, but this is not a Mac14,9 — it must not wear its labels"
        )
    }
}
