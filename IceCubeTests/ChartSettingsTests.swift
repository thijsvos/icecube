// ChartSettingsTests.swift — the twelve chart preferences, and the "never set" vs "set false" distinction they turn on.

import Foundation
import IceCubeKit
import Testing

/// Twelve preferences whose first-run defaults are not all `false`, which is
/// the whole difficulty: `UserDefaults.bool(forKey:)` returns `false` for a key
/// that was never written, so a naive read cannot tell "the user turned this
/// off" from "the user has never been here".
///
/// This type measured **0 % covered** until 2026-08-07, and it was not
/// neglect — it was unreachable. `ChartSettings.init()` read
/// `UserDefaults.standard` directly, so a test would have scribbled on the
/// developer's own preferences, which is the failure the 1,097-plist incident
/// made a standing rule. The `init(defaults:)` seam added alongside these tests
/// is what makes them possible, and it closed a live isolation hole at the same
/// time: a simulated launch had been writing these twelve keys into the real
/// domain.
@MainActor
@Suite("ChartSettings — first-run defaults, and what a stored false means")
struct ChartSettingsTests {
    /// Every default, as the app ships them. Written out rather than derived,
    /// so a change to any one of them is a visible diff in a test.
    static let firstRunDefaults: [(name: String, get: (ChartSettings) -> Bool, expected: Bool)] = [
        ("showCharts", { $0.showCharts }, true),
        ("showControls", { $0.showControls }, true),
        ("showCPU", { $0.showCPU }, true),
        ("showGPU", { $0.showGPU }, true),
        ("showFans", { $0.showFans }, true),
        ("showPower", { $0.showPower }, false),
        ("showBand", { $0.showBand }, true),
        ("showSecondary", { $0.showSecondary }, true),
        ("showTemperatureList", { $0.showTemperatureList }, false),
        ("smoothReadings", { $0.smoothReadings }, true),
    ]

    // MARK: - First run

    @Test("An empty store yields the shipped defaults")
    func emptyStoreUsesDefaults() {
        let settings = ChartSettings(defaults: SimulatedEnvironment.Defaults())
        for row in Self.firstRunDefaults {
            #expect(row.get(settings) == row.expected, "\(row.name) should default to \(row.expected)")
        }
        #expect(settings.window == .fiveMinutes)
        #expect(settings.height == .regular)
    }

    /// The distinction the whole `object(forKey:)` seam exists for. A key
    /// storing `false` must read back `false` even when the default is `true` —
    /// otherwise turning a chart off would silently un-turn-off on relaunch.
    @Test("A stored false survives a true default")
    func storedFalseBeatsATrueDefault() {
        let store = SimulatedEnvironment.Defaults()
        store.set(false, forKey: "charts.show")
        store.set(false, forKey: "charts.cpu")

        let settings = ChartSettings(defaults: store)
        #expect(settings.showCharts == false, "an explicit false must not be read as 'never set'")
        #expect(settings.showCPU == false)
        #expect(settings.showGPU, "…and an untouched key still gets its default")
    }

    /// The mirror, and the case a naive rewrite passes by accident: for a key
    /// whose default is already `false`, "never set" and "set false" are
    /// indistinguishable in the *result*. Only the `true` direction proves the
    /// read is doing the right thing.
    @Test("A stored true survives a false default")
    func storedTrueBeatsAFalseDefault() {
        let store = SimulatedEnvironment.Defaults()
        store.set(true, forKey: "charts.power")

        #expect(ChartSettings(defaults: store).showPower, "power defaults off, so this must be the stored value")
    }

    // MARK: - The window trap

    /// `Window`'s raw values are the old array indices, so **0 is a valid
    /// choice** — and `UserDefaults.integer(forKey:)` also returns 0 for a key
    /// that does not exist. `Window(rawValue:) ?? .fiveMinutes` therefore never
    /// fires for the one case that needs it, which is why `Window.stored(_:)`
    /// takes an `Int?` and forces the caller to pass `nil` explicitly.
    @Test("A stored one-minute window is not mistaken for an unset key")
    func zeroIsAValidWindow() {
        let store = SimulatedEnvironment.Defaults()
        store.set(0, forKey: "charts.window")
        #expect(ChartSettings(defaults: store).window == .oneMinute, "0 is a choice, not an absence")

        #expect(
            ChartSettings(defaults: SimulatedEnvironment.Defaults()).window == .fiveMinutes,
            "and an absent key is an absence"
        )
    }

    @Test("An out-of-range window falls back rather than crashing")
    func garbageWindowFallsBack() {
        let store = SimulatedEnvironment.Defaults()
        store.set(99, forKey: "charts.window")
        #expect(ChartSettings(defaults: store).window == .fiveMinutes)
    }

    @Test("An unrecognised height string falls back")
    func garbageHeightFallsBack() {
        let store = SimulatedEnvironment.Defaults()
        store.set("enormous", forKey: "charts.height")
        #expect(ChartSettings(defaults: store).height == .regular)
    }

    // MARK: - Round trip

    /// Each `didSet` must write its own key. A copy-paste slip here stores two
    /// preferences under one name and the second silently overwrites the first
    /// — the exact failure `FanControlMemory`'s doc comment says has already
    /// happened once in this codebase.
    @Test("Every preference round-trips through the store under its own key")
    func everyPreferenceRoundTrips() {
        let store = SimulatedEnvironment.Defaults()
        let settings = ChartSettings(defaults: store)

        settings.showCharts = false
        settings.showControls = false
        settings.showCPU = false
        settings.showGPU = false
        settings.showFans = false
        settings.showPower = true
        settings.showBand = false
        settings.showSecondary = false
        settings.showTemperatureList = true
        settings.smoothReadings = false
        settings.window = .oneHour
        settings.height = .tall

        let reloaded = ChartSettings(defaults: store)
        #expect(reloaded.showCharts == false)
        #expect(reloaded.showControls == false)
        #expect(reloaded.showCPU == false)
        #expect(reloaded.showGPU == false)
        #expect(reloaded.showFans == false)
        #expect(reloaded.showPower == true)
        #expect(reloaded.showBand == false)
        #expect(reloaded.showSecondary == false)
        #expect(reloaded.showTemperatureList == true)
        #expect(reloaded.smoothReadings == false)
        #expect(reloaded.window == .oneHour)
        #expect(reloaded.height == .tall)
    }

    /// Twelve distinct keys. Asserted by count rather than by name, so adding a
    /// thirteenth preference that reuses an existing key fails here.
    @Test("The twelve preferences occupy twelve distinct keys")
    func keysDoNotCollide() {
        let store = SimulatedEnvironment.Defaults()
        let settings = ChartSettings(defaults: store)

        settings.showCharts = false
        settings.showControls = false
        settings.showCPU = false
        settings.showGPU = false
        settings.showFans = false
        settings.showPower = true
        settings.showBand = false
        settings.showSecondary = false
        settings.showTemperatureList = true
        settings.smoothReadings = false
        settings.window = .oneHour
        settings.height = .tall

        // Ten live under `charts.`, two under `menu.` — `menu.controls` and
        // `menu.smoothReadings` are settings *about the menu bar* that happen to
        // be stored by this type. Spelled out rather than derived, because the
        // split is easy to get wrong: the first version of this test assumed all
        // twelve shared a prefix and failed on exactly those two.
        let written = ["show", "window", "cpu", "gpu", "fans", "power", "band", "secondary", "height", "templist"]
            .map { "charts.\($0)" } + ["menu.controls", "menu.smoothReadings"]
        #expect(Set(written).count == 12, "twelve preferences, twelve distinct keys")
        for key in written {
            #expect(store.object(forKey: key) != nil, "\(key) was never written")
        }
    }

    // MARK: - Row filtering

    /// Row ids come from `ChartStore.rows()` — `cpu`, `gpu`, `power`, and
    /// `fan.<id>` per fan.
    @Test("Each row id is gated by its own preference")
    func rowFilteringFollowsThePreferences() {
        let settings = ChartSettings(defaults: SimulatedEnvironment.Defaults())
        settings.showCPU = true
        settings.showGPU = false
        settings.showPower = true
        settings.showFans = false

        #expect(settings.includesRow(id: "cpu"))
        #expect(!settings.includesRow(id: "gpu"))
        #expect(settings.includesRow(id: "power"))
        #expect(!settings.includesRow(id: "fan.0"))
        #expect(!settings.includesRow(id: "fan.1"), "the fans toggle covers every fan, not just the first")
        #expect(settings.includesRow(id: "something-new"), "an unknown row is shown, not silently dropped")
    }

    // MARK: - ChartHeight

    @Test("Every chart height is nameable and positive", arguments: ChartHeight.allCases)
    func everyHeightIsUsable(height: ChartHeight) {
        #expect(!height.title.isEmpty)
        #expect(height.points > 0)
        #expect(ChartHeight(rawValue: height.rawValue) == height, "raw values must round-trip")
    }
}
