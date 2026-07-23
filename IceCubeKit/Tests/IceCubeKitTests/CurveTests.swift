// CurveTests.swift — curve invariants, interpolation, follower hysteresis/ramp, config back-compat.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("FanCurve")
struct FanCurveTests {
    @Test("Interpolation is exact at points, linear between, flat outside")
    func interpolation() {
        let curve = FanCurve(points: [
            CurvePoint(celsius: 60, fraction: 0),
            CurvePoint(celsius: 80, fraction: 0.5),
            CurvePoint(celsius: 100, fraction: 1),
        ])
        #expect(curve.fraction(at: 60) == 0)
        #expect(curve.fraction(at: 80) == 0.5)
        #expect(curve.fraction(at: 100) == 1)
        #expect(curve.fraction(at: 70) == 0.25)
        #expect(curve.fraction(at: 90) == 0.75)
        #expect(curve.fraction(at: 20) == 0, "flat below the first point")
        #expect(curve.fraction(at: 115) == 1, "flat above the last point")
    }

    @Test("Normalization sorts, clamps, dedups, and forces non-decreasing fractions")
    func normalization() {
        let messy = FanCurve(points: [
            CurvePoint(celsius: 90, fraction: 0.2), // decreasing vs the 80 below
            CurvePoint(celsius: 50, fraction: -3), // clamps to 0
            CurvePoint(celsius: 80, fraction: 1.7), // clamps to 1
            CurvePoint(celsius: 80.2, fraction: 0.5), // dedup: within 0.5 °C of 80
            CurvePoint(celsius: .nan, fraction: 0.5), // dropped
        ])
        #expect(messy.points.map(\.celsius) == [50, 80, 90])
        #expect(messy.points.map(\.fraction) == [0, 1, 1], "running max repairs the dip")
    }

    @Test("Any garbage input yields finite 0…1 output, monotone in temperature")
    func propertySweep() {
        // Deterministic pseudo-random curves via a simple LCG.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func rand() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(seed >> 11) * 0x1p-53
        }
        for _ in 0 ..< 200 {
            let count = 1 + Int(rand() * 9)
            let curve = FanCurve(points: (0 ..< count).map { _ in
                CurvePoint(celsius: rand() * 200 - 40, fraction: rand() * 2 - 0.5)
            })
            var last = -0.0001
            for t in stride(from: -30.0, through: 130.0, by: 1.6) {
                let f = curve.fraction(at: t)
                #expect(f.isFinite && f >= 0 && f <= 1)
                #expect(f >= last - 0.0001, "output must never decrease as temp rises")
                last = f
            }
        }
    }

    @Test("Built-ins are usable and shaped as advertised")
    func builtins() {
        for curve in [FanCurve.quiet, .balanced, .cold, .max] {
            #expect(curve.isUsable)
        }
        #expect(FanCurve.quiet.fraction(at: 50) == 0, "quiet is silent when cool")
        #expect(FanCurve.quiet.fraction(at: 90) == 1, "quiet hits full speed by 90 °C")
        #expect(FanCurve.max.fraction(at: 35) == 1, "max is always full speed")
        #expect(FanCurve.balanced.fraction(at: 75) == 0.75)
        #expect(FanCurve.balanced.fraction(at: 85) == 1, "balanced is flat-out by 85 °C")
        // Cold keeps a strong steady speed across the idle band (no steep knee
        // there to hunt on) and reaches full speed only under real load.
        #expect(FanCurve.cold.fraction(at: 30) == 0.5, "cold always moves air firmly")
        #expect(FanCurve.cold.fraction(at: 80) == 1, "cold is flat-out by 80 °C")
        let idleBandSwing = FanCurve.cold.fraction(at: 55) - FanCurve.cold.fraction(at: 35)
        #expect(idleBandSwing < 0.2, "cold's idle band (35–55 °C) is flat-ish, so fans don't hunt")
    }
}

@Suite("CurveFollower")
struct CurveFollowerTests {
    private let curve = FanCurve(points: [
        CurvePoint(celsius: 60, fraction: 0),
        CurvePoint(celsius: 100, fraction: 1),
    ])

    /// A follower with smoothing/asymmetry disabled, to test the deadband and
    /// ramp stages in isolation.
    private func plainFollower(hysteresis: Double, ramp: Double) -> CurveFollower {
        CurveFollower(hysteresisCelsius: hysteresis, rampUpPerTick: ramp, rampDownPerTick: ramp, smoothingAlpha: 1)
    }

    @Test("Hysteresis: wiggles below the deadband do not move the output")
    func hysteresisDeadband() {
        var follower = plainFollower(hysteresis: 3, ramp: 1)
        let base = follower.step(dieCelsius: 80, curve: curve)
        #expect(follower.step(dieCelsius: 81.5, curve: curve) == base, "+1.5 °C ignored")
        #expect(follower.step(dieCelsius: 78.6, curve: curve) == base, "−1.4 °C ignored")
        #expect(follower.step(dieCelsius: 84, curve: curve) > base, "+4 °C accepted")
    }

    @Test("Ramp limiting: a demand jump arrives in bounded steps, up and down")
    func rampLimiting() {
        var follower = plainFollower(hysteresis: 0, ramp: 0.1)
        #expect(follower.step(dieCelsius: 60, curve: curve) == 0)
        #expect(abs(follower.step(dieCelsius: 100, curve: curve) - 0.1) < 0.0001)
        #expect(abs(follower.step(dieCelsius: 100, curve: curve) - 0.2) < 0.0001)
        var value = 0.2
        for _ in 0 ..< 10 {
            value = follower.step(dieCelsius: 100, curve: curve)
        }
        #expect(abs(value - 1.0) < 0.0001, "converges to the demand")
        #expect(abs(follower.step(dieCelsius: 60, curve: curve) - 0.9) < 0.0001, "steps down too")
    }

    @Test("Asymmetric ramp: fans rise faster than they fall (anti-hunting)")
    func asymmetricRamp() {
        var follower = CurveFollower(
            hysteresisCelsius: 0, rampUpPerTick: 0.2, rampDownPerTick: 0.05, smoothingAlpha: 1
        )
        _ = follower.step(dieCelsius: 60, curve: curve) // start at 0
        let up = follower.step(dieCelsius: 100, curve: curve) // demand 1.0
        #expect(abs(up - 0.2) < 0.0001, "rises by the up rate")
        let down = follower.step(dieCelsius: 60, curve: curve) // demand 0.0
        #expect(abs(up - down - 0.05) < 0.0001, "falls by the smaller down rate")
    }

    @Test("EMA smoothing swallows a brief spike but tracks a sustained rise")
    func smoothing() {
        // No deadband, instant ramp — isolate the EMA stage.
        var follower = CurveFollower(
            hysteresisCelsius: 0, rampUpPerTick: 1, rampDownPerTick: 1, smoothingAlpha: 0.2
        )
        _ = follower.step(dieCelsius: 60, curve: curve) // settle at 60 °C → 0
        // A single 100 °C spike: smoothed temp only moves ~0.2 of the way,
        // so the output barely twitches (nowhere near full).
        let afterSpike = follower.step(dieCelsius: 100, curve: curve)
        #expect(afterSpike < 0.3, "one spike barely moves the smoothed input")
        // A sustained 100 °C load: the average climbs to it over several ticks.
        var value = afterSpike
        for _ in 0 ..< 30 {
            value = follower.step(dieCelsius: 100, curve: curve)
        }
        #expect(value > 0.95, "a sustained rise is tracked fully")
    }

    @Test("First tick starts at the curve's demand (no artificial spin-up from zero)")
    func firstTick() {
        var follower = CurveFollower(hysteresisCelsius: 4, rampUpPerTick: 0.05, smoothingAlpha: 0.2)
        #expect(follower.step(dieCelsius: 100, curve: curve) == 1.0)
    }

    @Test("Non-finite temperatures are ignored; output stays finite and clamped")
    func nonFiniteInput() {
        var follower = plainFollower(hysteresis: 3, ramp: 1)
        let base = follower.step(dieCelsius: 80, curve: curve)
        let next = follower.step(dieCelsius: .nan, curve: curve)
        #expect(next == base, "NaN reading keeps the last accepted state")
        #expect(next.isFinite && next >= 0 && next <= 1)
    }
}

@Suite("FanConfig curve fields")
struct FanConfigCurveTests {
    @Test("Phase 3-era JSON (no curve fields) still decodes")
    func backCompat() throws {
        let old = #"{"mode":"manual","manualTargets":{"0":4000},"persistsWithoutApp":false}"#
        let config = try JSONDecoder().decode(FanConfig.self, from: Data(old.utf8))
        #expect(config.mode == .manual)
        #expect(config.manualTargets == [0: 4000])
        #expect(config.sharedCurve == nil)
        #expect(config.hysteresisCelsius == 4, "missing field decodes to the current default")
    }

    @Test("Curve resolution: per-fan override wins, shared curve is the fallback")
    func curveResolution() {
        var config = FanConfig.curve(.balanced)
        config.perFanCurves[1] = .quiet
        #expect(config.curve(for: 0) == .balanced)
        #expect(config.curve(for: 1) == .quiet)
        #expect(config.isUsableCurveConfig)
        #expect(!FanConfig.auto.isUsableCurveConfig)
    }

    @Test("Round-trips through JSON with curves intact")
    func roundTrip() throws {
        let config = FanConfig.curve(.quiet, persists: true)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(FanConfig.self, from: data)
        #expect(decoded == config)
        #expect(decoded.sharedCurve == .quiet)
        #expect(decoded.persistsWithoutApp)
    }
}
