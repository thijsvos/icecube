// ChartLayerTests.swift — ring buffer, downsampler budget/spike-survival, and ChartStore row contract.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("RingBuffer")
struct RingBufferTests {
    @Test("Fills, wraps, and always yields the newest elements oldest-first")
    func wrapAround() {
        var ring = RingBuffer<Int>(capacity: 3)
        #expect(ring.isEmpty && ring.elements == [])
        ring.append(1)
        ring.append(2)
        #expect(ring.elements == [1, 2])
        ring.append(3)
        #expect(ring.elements == [1, 2, 3])
        ring.append(4) // overwrites 1
        #expect(ring.elements == [2, 3, 4])
        for i in 5 ... 20 {
            ring.append(i)
        }
        #expect(ring.elements == [18, 19, 20])
        #expect(ring.count == 3)
    }
}

/// The chart window's first-run default regressed once, silently, from 5 min
/// to 1 min: the persisted value was read with `UserDefaults.integer(forKey:)`,
/// which returns 0 for a missing key, and 0 is a valid raw value — so the
/// `?? .fiveMinutes` fallback could never fire. These pin the rule.
@Suite("ChartStore.Window persistence")
struct ChartWindowStorageTests {
    @Test("A never-set preference opens on the 5 minute default, not the 0-raw case")
    func firstRunDefault() {
        #expect(ChartStore.Window.stored(nil) == .fiveMinutes)
        #expect(ChartStore.Window.firstRunDefault == .fiveMinutes)
        // The exact trap: 0 must NOT be how "absent" is spelled.
        #expect(ChartStore.Window.stored(0) == .oneMinute)
        #expect(ChartStore.Window.stored(nil) != ChartStore.Window.stored(0))
    }

    @Test("Every case round-trips through its raw value")
    func roundTrip() {
        for window in ChartStore.Window.allCases {
            #expect(ChartStore.Window.stored(window.rawValue) == window)
        }
    }

    @Test("Out-of-range or corrupted values fall back to the default")
    func corruptedValue() {
        #expect(ChartStore.Window.stored(-1) == .fiveMinutes)
        #expect(ChartStore.Window.stored(99) == .fiveMinutes)
        #expect(ChartStore.Window.stored(Int.max) == .fiveMinutes)
    }

    @Test("Raw values are the pre-enum array indices, so stored preferences migrate")
    func migratesFromLegacyIndices() {
        // The old code stored an index into [60, 300, 900, 3600].
        #expect(ChartStore.Window.stored(0).seconds == 60)
        #expect(ChartStore.Window.stored(1).seconds == 300)
        #expect(ChartStore.Window.stored(2).seconds == 900)
        #expect(ChartStore.Window.stored(3).seconds == 3600)
    }

    @Test("Titles and spans stay paired")
    func titlesPairWithSpans() {
        #expect(ChartStore.Window.oneMinute.title == "1 min")
        #expect(ChartStore.Window.fiveMinutes.title == "5 min")
        #expect(ChartStore.Window.fifteenMinutes.title == "15 min")
        #expect(ChartStore.Window.oneHour.title == "1 hr")
        #expect(ChartStore.Window.allCases.map(\.seconds) == [60, 300, 900, 3600])
    }
}

@Suite("ChartDownsampler")
struct ChartDownsamplerTests {
    private let start = Date(timeIntervalSince1970: 1_753_000_000)

    /// One sample per second for `n` seconds, from a value function.
    private func samples(_ n: Int, value: (Int) -> Double) -> [ChartSample] {
        (0 ..< n).map { ChartSample(time: start.addingTimeInterval(Double($0)), value: value($0)) }
    }

    @Test("Never exceeds the budget, whatever the input size")
    func budgetIsHard() {
        let raw = samples(3600) { Double($0 % 100) }
        for budget in [600, 100, 7] {
            let buckets = ChartDownsampler.downsample(
                raw, from: start, to: start.addingTimeInterval(3600), budget: budget
            )
            #expect(buckets.count <= budget, "budget \(budget) → \(buckets.count) buckets")
            #expect(buckets.count >= budget - 1, "should use nearly all buckets for dense input")
        }
    }

    @Test("Small inputs pass through untouched (one bucket per sample)")
    func passthrough() {
        let raw = samples(50) { 40 + Double($0) }
        let buckets = ChartDownsampler.downsample(
            raw, from: start, to: start.addingTimeInterval(3600), budget: 600
        )
        #expect(buckets.count == 50)
        #expect(buckets.allSatisfy { $0.min == $0.max && $0.max == $0.avg })
    }

    @Test("A one-tick spike survives aggressive downsampling")
    func spikeSurvives() {
        var raw = samples(3600) { _ in 45.0 }
        raw[1800] = ChartSample(time: raw[1800].time, value: 104.0) // the spike
        let buckets = ChartDownsampler.downsample(
            raw, from: start, to: start.addingTimeInterval(3600), budget: 60
        )
        #expect(buckets.count <= 60)
        #expect(buckets.map(\.max).max() == 104.0, "min-max bucketing must keep the spike")
        #expect(buckets.map(\.min).min() == 45.0)
    }

    @Test("Only samples inside the window are considered; empty window → no buckets")
    func windowFiltering() {
        let raw = samples(3600) { Double($0) }
        let lastMinute = ChartDownsampler.downsample(
            raw, from: start.addingTimeInterval(3540), to: start.addingTimeInterval(3600), budget: 600
        )
        #expect(lastMinute.count == 60, "60 samples in the last minute pass through")
        #expect(lastMinute.allSatisfy { $0.avg >= 3540 })

        let empty = ChartDownsampler.downsample(
            raw, from: start.addingTimeInterval(-7200), to: start.addingTimeInterval(-3600), budget: 600
        )
        #expect(empty.isEmpty)
    }

    @Test("Stats reflect the visible window only, and 'latest' is the newest sample")
    func statsWindow() throws {
        let raw = samples(100) { Double($0) } // 0…99
        let stats = try #require(ChartDownsampler.stats(
            raw, from: start.addingTimeInterval(50), to: start.addingTimeInterval(99)
        ))
        #expect(stats.min == 50)
        #expect(stats.max == 99)
        #expect(stats.latest == 99)
        #expect(abs(stats.avg - 74.5) < 0.0001)
        #expect(ChartDownsampler
            .stats(raw, from: start.addingTimeInterval(500), to: start.addingTimeInterval(600)) == nil)
    }
}

@Suite("ChartStore")
struct ChartStoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_753_000_000)

    /// Feeds `seconds` of simulated snapshots into a fresh store.
    private func fedStore(seconds: Int) async -> ChartStore {
        let store = ChartStore()
        for s in 0 ..< seconds {
            let t = epoch.addingTimeInterval(Double(s))
            let snapshot = SMCSnapshot(
                date: t,
                fans: MockSMCProvider.fans(at: t.timeIntervalSince1970),
                temperatures: MockSMCProvider.temperatures(at: t.timeIntervalSince1970)
            )
            await store.ingest(snapshot)
        }
        return store
    }

    // Phase 2's acceptance line asks for "no dropped frames" on the 60-minute
    // window, which PLAN.md §1.2 calls out as the hazard: 3600 samples per
    // series across ~6 series, "squarely in Swift Charts' documented
    // degradation zone" without the <=600-point budget.
    //
    // Measured on a Mac14,9 in release — worst of 50 runs per window:
    //
    //     1-minute    1.6 ms      15-minute   2.0 ms
    //     5-minute    1.6 ms      60-minute   3.3 ms
    //
    // The 60-minute case is the one that was supposed to hurt, and it lands at
    // a fifth of a 60 fps frame — while never actually needing to fit in one:
    // `AppState` calls `rows(window:)` once per 1 Hz poll, only while the
    // popover is visible and unpaused, and `ChartStore` is an actor so the work
    // happens off the main thread entirely. SwiftUI then renders an
    // already-computed array. Against the interval it really runs on, 3.3 ms is
    // 0.3 %.
    //
    // RELEASE ONLY. Debug Swift runs this path 5-20x slower (72 ms was
    // observed for one window), so asserting a millisecond figure in the debug
    // build CI uses would be a flake, not a guard. The deterministic guard is
    // `budgetBindsOnFullHistory` below — if the point budget ever stops
    // binding, that fails everywhere, immediately, with no timing involved.
    #if !DEBUG
        @Test("A full 60-minute history builds its rows in a fraction of a frame")
        func rowsFitInsideAFrame() async {
            let store = await fedStore(seconds: 3600) // the documented worst case
            // Half a 60 fps frame: this is the data path only, and a number that
            // merely squeaked under the full 16.6 ms would leave the chart
            // drawing nothing to work with.
            let halfFrameMilliseconds = 8.3

            for window in [60.0, 300, 900, 3600] {
                // Warmed once — the first call pays one-off allocation costs a
                // live app pays long before anyone opens the popover.
                _ = await store.rows(window: window)

                var worst = 0.0
                for _ in 0 ..< 50 {
                    let started = ContinuousClock.now
                    _ = await store.rows(window: window)
                    let elapsed = Double((ContinuousClock.now - started)
                        .components.attoseconds) / 1e15
                    worst = max(worst, elapsed)
                }
                #expect(
                    worst < halfFrameMilliseconds,
                    "\(Int(window))s window took \(worst) ms — over half a 60 fps frame"
                )
            }
        }
    #endif

    /// The budget is what makes the above true, so pin that it actually binds:
    /// an hour of samples must still come back capped, not thinned "mostly".
    @Test("The point budget binds even on a full hour of history")
    func budgetBindsOnFullHistory() async {
        let store = await fedStore(seconds: 3600)
        let rows = await store.rows(window: 3600)
        for row in rows {
            for series in row.series {
                #expect(
                    series.buckets.count <= ChartStore.pointBudget,
                    "\(row.id)/\(series.id) returned \(series.buckets.count) points"
                )
            }
        }
    }

    @Test("Row set is stable and correctly shaped: CPU, GPU, one row per fan")
    func rowContract() async {
        let store = await fedStore(seconds: 120)
        let rows = await store.rows(window: 60)
        #expect(rows.map(\.id) == ["cpu", "gpu", "fan.0", "fan.1"])
        #expect(rows.map(\.unit) == [.celsius, .celsius, .rpm, .rpm])
        let cpu = rows[0]
        #expect(cpu.series.map(\.id) == ["cpu.max", "cpu.avg"])
        #expect(cpu.yDomainMin == 20 && cpu.yDomainMax == 110)
        let fan = rows[2]
        #expect(fan.title == "Left Fan")
        #expect(fan.yDomainMax == 6800 * 1.05)
        #expect(fan.series[1].isSecondary, "fan target renders as the secondary series")
    }

    @Test("The point budget holds for every series at every window")
    func budgetAcrossWindows() async {
        let store = await fedStore(seconds: 700)
        for window in ChartStore.Window.allCases.map(\.seconds) {
            for row in await store.rows(window: window) {
                for series in row.series {
                    #expect(
                        series.buckets.count <= ChartStore.pointBudget,
                        "\(series.id) at \(Int(window))s: \(series.buckets.count)"
                    )
                    #expect(!series.buckets.isEmpty)
                }
            }
        }
    }

    @Test("CPU max ≥ CPU avg everywhere, and stats.latest matches the newest bucket region")
    func cpuSeriesSemantics() async throws {
        let store = await fedStore(seconds: 300)
        let rows = await store.rows(window: 300)
        let cpu = rows[0]
        let maxSeries = cpu.series[0], avgSeries = cpu.series[1]
        for (top, mean) in zip(maxSeries.buckets, avgSeries.buckets) {
            #expect(top.avg >= mean.avg - 0.0001)
        }
        let stats = try #require(maxSeries.stats)
        #expect(stats.min <= stats.avg && stats.avg <= stats.max)
        #expect(SMCKeyMaps.isPlausibleTemperature(stats.latest))
    }

    @Test("An empty store serves no rows; rows appear after the first ingest")
    func emptyThenFirstIngest() async {
        let store = ChartStore()
        #expect(await store.rows(window: 60).isEmpty)
        let t = epoch
        await store.ingest(SMCSnapshot(
            date: t,
            fans: MockSMCProvider.fans(at: t.timeIntervalSince1970),
            temperatures: MockSMCProvider.temperatures(at: t.timeIntervalSince1970)
        ))
        #expect(await store.rows(window: 60).count == 4)
    }
}
