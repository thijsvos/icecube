// CoolingRecorderTests.swift — what earns a place in a file kept for a year.

import Foundation
@testable import IceCubeKit
import Testing

/// The live readout may answer freely — a wrong glyph lasts one second. A
/// record is averaged into verdicts for a year, so the recorder's every gate
/// is stricter than the live rule, and each is pinned here with the mutation
/// it must catch.
@Suite("CoolingRecorder — the gate between the live window and the file")
struct CoolingRecorderTests {
    private let epoch = Date(timeIntervalSince1970: 1_753_000_000)
    private let base = ContinuousClock().now

    private func fans(fraction: Double, second: Double? = nil) -> [Fan] {
        [fraction, second ?? fraction].enumerated().map { id, f in
            Fan(
                id: id, name: "Fan \(id)", mode: .system,
                actualRPM: f * 6800, targetRPM: f * 6800, minRPM: 2317, maxRPM: 6800
            )
        }
    }

    private func snapshot(_ offset: TimeInterval, fans: [Fan]) -> SMCSnapshot {
        SMCSnapshot(date: epoch.addingTimeInterval(offset), fans: fans, temperatures: [], power: nil)
    }

    private func settled(
        _ offset: TimeInterval,
        watts: Double = 20,
        samples: Int = 21,
        duration: TimeInterval = 20,
        maxGap: TimeInterval = 1
    ) -> CoolingEfficiency.SettledWindow {
        CoolingEfficiency.SettledWindow(
            endedAt: epoch.addingTimeInterval(offset),
            resistance: 0.51,
            dieCelsius: 49,
            ambientCelsius: 39,
            watts: watts,
            sampleCount: samples,
            duration: duration,
            maxGapSeconds: maxGap
        )
    }

    // MARK: - The gates

    @Test("An unsettled window records nothing, and says why")
    func anUnsettledWindowRecordsNothing() {
        var recorder = CoolingRecorder()
        let record = recorder.ingest(
            snapshot(0, fans: fans(fraction: 0.55)), settled: nil, elapsed: base
        )
        #expect(record == nil)
        #expect(recorder.lastRefusal == .unsettled)
    }

    /// THERMAL.md measured 9 % spread at 8.6–9.0 W against 2 % at 21–24 W. A
    /// datum whose own noise is 9 % cannot support a 10 % claim — but the
    /// live readout keeps its 5 W floor, because showing a number now and
    /// keeping one forever are different questions.
    @Test("The record floor is higher than the display floor")
    func theRecordFloorIsHigherThanTheDisplayFloor() {
        var recorder = CoolingRecorder()
        let refused = recorder.ingest(
            snapshot(0, fans: fans(fraction: 0.55)), settled: settled(0, watts: 9.5), elapsed: base
        )
        #expect(refused == nil)
        #expect(recorder.lastRefusal == .lowPower(9.5))

        let accepted = recorder.ingest(
            snapshot(1, fans: fans(fraction: 0.55)),
            settled: settled(1, watts: 10.5),
            elapsed: base.advanced(by: .seconds(1))
        )
        #expect(accepted != nil)
        #expect(CoolingEfficiency.minimumWatts == 5, "and the live floor is untouched")
    }

    /// The headline test: `isSettled` accepts two samples spanning 20 s —
    /// correct for a glyph replaced next second, not for a record kept a
    /// year. The two rules are deliberately different and this pins both
    /// sides at once.
    @Test("A two-sample window is settled enough to show and not enough to keep")
    func aTwoSampleWindowIsSettledEnoughToShowAndNotEnoughToKeep() {
        let live: [CoolingEfficiency.Sample] = [
            .init(date: epoch, dieCelsius: 49, ambientCelsius: 39, watts: 20),
            .init(date: epoch.addingTimeInterval(20), dieCelsius: 49, ambientCelsius: 39, watts: 20),
        ]
        #expect(CoolingEfficiency.isSettled(live), "the live rule accepts two points")

        var recorder = CoolingRecorder()
        let record = recorder.ingest(
            snapshot(20, fans: fans(fraction: 0.55)),
            settled: settled(20, samples: 2, maxGap: 20),
            elapsed: base
        )
        #expect(record == nil, "the recorder does not")
        #expect(recorder.lastRefusal == .sparseWindow(samples: 2, widestGap: 20))
    }

    /// The poll interval is user-configurable (1, 2 or 5 s), so a bare
    /// sample count cannot be the gate: it would refuse a clean 5 s cadence
    /// forever. Density — the widest gap — is what distinguishes a slow
    /// cadence from a throttled loop.
    @Test("A clean 5-second cadence records; an App-Napped window does not")
    func aSlowCadenceIsNotAThrottledLoop() {
        var recorder = CoolingRecorder()
        let clean = recorder.ingest(
            snapshot(0, fans: fans(fraction: 0.55)),
            settled: settled(0, samples: 5, maxGap: 5),
            elapsed: base
        )
        #expect(clean != nil, "five samples at a clean 5 s cadence are a full window")

        var second = CoolingRecorder()
        let gappy = second.ingest(
            snapshot(0, fans: fans(fraction: 0.55)),
            settled: settled(0, samples: 12, maxGap: 11),
            elapsed: base
        )
        #expect(gappy == nil, "twelve samples with an 11 s hole are a throttled loop")
        #expect(second.lastRefusal == .sparseWindow(samples: 12, widestGap: 11))
    }

    /// The settle rule bounds power and die and never looks at the fans —
    /// the exact axis records are banded on. Deleting the fan window is the
    /// mutation this test exists for.
    @Test("Fans ramping through a settled window are refused")
    func fansRampingThroughASettledWindowAreRefused() {
        var recorder = CoolingRecorder()
        // Build the fan window across 20 s of unsettled ticks while the
        // fans walk 0.50 → 0.70 of maximum.
        for i in 0 ... 19 {
            _ = recorder.ingest(
                snapshot(Double(i), fans: fans(fraction: 0.50 + Double(i) * 0.01)),
                settled: nil,
                elapsed: base.advanced(by: .seconds(i))
            )
        }
        let record = recorder.ingest(
            snapshot(20, fans: fans(fraction: 0.70)),
            settled: settled(20),
            elapsed: base.advanced(by: .seconds(20))
        )
        #expect(record == nil)
        guard case let .fansMoving(swing)? = recorder.lastRefusal else {
            Issue.record("expected .fansMoving, got \(String(describing: recorder.lastRefusal))")
            return
        }
        #expect(swing > 0.15)
    }

    /// Two fans at 0.9 and 0.0 are not "0.45 of maximum" — they are an
    /// incident, and `ThermalDiagnosis.Cooling.stalled` already names it in
    /// seconds. The doc there is the real owner of this case.
    @Test("One stopped fan is refused rather than averaged")
    func oneStoppedFanIsRefusedRatherThanAveraged() {
        var recorder = CoolingRecorder()
        let record = recorder.ingest(
            snapshot(0, fans: fans(fraction: 0.875, second: 0)),
            settled: settled(0),
            elapsed: base
        )
        #expect(record == nil)
        guard case let .fansDisagree(spread)? = recorder.lastRefusal else {
            Issue.record("expected .fansDisagree, got \(String(describing: recorder.lastRefusal))")
            return
        }
        #expect(abs(spread - 0.875) < 0.001)
    }

    // MARK: - Spacing

    /// The throttle is global, not per-episode, which makes "never more
    /// than 288 records a day" provable — and the whole retention budget
    /// (`maximumRawRecords` = 7 × 288) is built on that property.
    @Test("At most one record per spacing, however long it stays settled")
    func atMostOneRecordPerSpacing() {
        var recorder = CoolingRecorder()
        var emitted = 0
        for i in 0 ..< 3600 {
            let record = recorder.ingest(
                snapshot(Double(i), fans: fans(fraction: 0.55)),
                settled: settled(Double(i)),
                elapsed: base.advanced(by: .seconds(i))
            )
            if record != nil {
                emitted += 1
            }
        }
        #expect(emitted == 12, "an hour of continuous settledness is twelve records, got \(emitted)")
    }

    /// A machine that settles and breaks every 25 s must not emit every
    /// 25 s — the mutation is resetting the throttle on episode boundaries.
    @Test("A broken and re-settled window still cannot beat the spacing")
    func aBrokenWindowCannotBeatTheSpacing() {
        var recorder = CoolingRecorder()
        var emitted = 0
        for i in 0 ..< 3600 {
            let isSettledTick = (i / 25).isMultiple(of: 2) // settle 25 s, break 25 s
            let record = recorder.ingest(
                snapshot(Double(i), fans: fans(fraction: 0.55)),
                settled: isSettledTick ? settled(Double(i)) : nil,
                elapsed: base.advanced(by: .seconds(i))
            )
            if record != nil {
                emitted += 1
            }
        }
        #expect(emitted <= 12, "episode boundaries must not reset the throttle, got \(emitted)")
    }

    // MARK: - Shapes of machine

    @Test("A fanless Mac records normally, into its own band")
    func aFanlessMacRecordsNormally() throws {
        var recorder = CoolingRecorder()
        let emitted = recorder.ingest(snapshot(0, fans: []), settled: settled(0), elapsed: base)
        let record = try #require(emitted)
        #expect(record.band == .fanless)
        #expect(record.fanRPM == 0)
    }

    @Test("Values are rounded on the way in, so the file and memory agree")
    func valuesAreRoundedOnTheWayIn() {
        let record = CoolingRecord(
            date: Date(timeIntervalSince1970: 1_753_000_000.7),
            resistance: 0.913_043_478_260_869_6,
            dieCelsius: 66.7321,
            ambientCelsius: 46.8555,
            watts: 24.049,
            band: .decile(8),
            fanFraction: 0.875_123,
            fanRPM: 5950.4,
            sampleCount: 21,
            durationSeconds: 20.4
        )
        #expect(record.resistance == 0.913)
        #expect(record.dieCelsius == 66.7)
        #expect(record.ambientCelsius == 46.9)
        #expect(record.watts == 24.0)
        #expect(record.fanFraction == 0.875)
        #expect(record.fanRPM == 5950)
        #expect(record.date == Date(timeIntervalSince1970: 1_753_000_001))
    }

    @Test("The refusal names the most fundamental failed gate")
    func theRefusalNamesTheFirstFailedGate() {
        var recorder = CoolingRecorder()
        // Disagreeing fans AND low power AND a sparse window: the fan
        // incident is the most fundamental and must be the one named.
        _ = recorder.ingest(
            snapshot(0, fans: fans(fraction: 0.875, second: 0)),
            settled: settled(0, watts: 6, samples: 2, maxGap: 18),
            elapsed: base
        )
        guard case .fansDisagree? = recorder.lastRefusal else {
            Issue.record("expected .fansDisagree first, got \(String(describing: recorder.lastRefusal))")
            return
        }
    }
}
