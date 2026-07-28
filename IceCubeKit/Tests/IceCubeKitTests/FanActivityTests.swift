// FanActivityTests.swift — the fan-row display rules: stale targets, the firmware dead time, and a zero maxRPM.

import Foundation
@testable import IceCubeKit
import Testing

private func fan(
    mode: FanMode = .forced,
    actual: Double = 3000,
    target: Double = 3000,
    min: Double = 2317,
    max: Double = 6800
) -> Fan {
    Fan(id: 0, name: "Left", mode: mode, actualRPM: actual, targetRPM: target, minRPM: min, maxRPM: max)
}

@Suite("FanActivity — what a fan's numbers mean on screen")
struct FanActivityTests {
    // MARK: The stale-target trap

    /// The bug this rule exists for. `F{i}Tg` keeps the last value written even
    /// after control returns to macOS, so a fan sitting still under Automatic
    /// showed a permanent "→ 2317" — promising something nothing was working
    /// toward.
    @Test("A fan macOS controls advertises no destination, however stale F{i}Tg is")
    func systemModeHasNoTarget() {
        for mode in [FanMode.system, .auto] {
            let activity = FanActivity(fan(mode: mode, actual: 0, target: 2317))
            #expect(activity.rampTargetRPM == nil, "\(mode) must not claim a destination")
            #expect(activity.rampTargetFraction == nil)
            #expect(activity.readout == .speed(rpm: 0), "a stopped fan on auto reads 0, not 'starting'")
        }
    }

    // MARK: The firmware dead time

    /// Measured on a Mac14,9: a stopped fan given a target reads exactly 0 RPM
    /// for ~1.5 s. Showing "0 RPM" there says nothing is happening at the
    /// precise moment someone decides the app is broken.
    @Test("A commanded fan that has not moved yet reads as starting")
    func startingFromRest() {
        #expect(FanActivity(fan(actual: 0, target: 4400)).readout == .starting)
        #expect(FanActivity(fan(actual: 99, target: 4400)).readout == .starting)
    }

    @Test("Once the tachometer moves it reports the speed")
    func movingReportsSpeed() {
        #expect(FanActivity(fan(actual: 100, target: 4400)).readout == .speed(rpm: 100))
        #expect(FanActivity(fan(actual: 2400, target: 4400)).readout == .speed(rpm: 2400))
    }

    /// KNOWN GAP, pinned deliberately so the fix is a visible decision rather
    /// than an accident. `isStarting` compares `targetRPM > minRPM`, but a Quiet
    /// or Balanced curve on a cool Mac commands EXACTLY `minRPM` — so a fan
    /// starting from rest under those presets is *not* reported as starting,
    /// in part of the very scenario the rule was written for. Changing `>` to
    /// `>=` is a behaviour change and belongs in its own commit.
    @Test("A fan commanded to exactly its minimum is NOT reported as starting (known gap)")
    func startingMissesTheFloorCase() {
        let atFloor = FanActivity(fan(actual: 0, target: 2317, min: 2317))
        #expect(atFloor.readout == .speed(rpm: 0), "today's behaviour, not the desired one")
    }

    // MARK: Ramp hint

    @Test("A fan well short of its target shows where it is heading")
    func rampingUpShowsTarget() {
        #expect(FanActivity(fan(actual: 2400, target: 4400)).rampTargetRPM == 4400)
    }

    /// Below the threshold the gauge tick alone tells the story — a hint on
    /// screen almost permanently would be noise.
    @Test("A fan near its target shows no ramp hint")
    func nearTargetIsQuiet() {
        #expect(FanActivity(fan(actual: 4150, target: 4400)).rampTargetRPM == nil, "250 RPM short")
        #expect(FanActivity(fan(actual: 4099, target: 4400)).rampTargetRPM == 4400, "301 RPM short")
    }

    /// Winding down is not something a user waits on.
    @Test("Spinning down shows no ramp hint")
    func rampingDownIsQuiet() {
        #expect(FanActivity(fan(actual: 5000, target: 2400)).rampTargetRPM == nil)
    }

    // MARK: Fractions

    /// A fan at its floor must show a visibly partial bar. An empty bar means
    /// stopped, and only that.
    @Test("Fill is measured from zero, so a fan at its floor is not empty")
    func fillMeasuredFromZero() {
        let atFloor = FanActivity(fan(actual: 2317, target: 2317))
        #expect(atFloor.fillFraction > 0.3, "2317/6800 ≈ 0.34, not 0")
        #expect(FanActivity(fan(mode: .system, actual: 0, target: 0)).fillFraction == 0)
    }

    /// `maxRPM` is genuinely 0 when the range read fails — every fraction here
    /// divides by it, and a NaN reaches SwiftUI as a blank or a crash.
    @Test("A zero maxRPM yields finite fractions, never NaN")
    func zeroMaxIsSafe() {
        let broken = FanActivity(fan(actual: 3000, target: 3000, min: 0, max: 0))
        #expect(broken.fillFraction == 0)
        #expect(broken.fillFraction.isFinite)
        #expect(broken.rampTargetFraction == nil)
    }

    @Test("Fractions stay within 0…1 even when the fan overshoots its maximum")
    func fractionsClamp() {
        let over = FanActivity(fan(actual: 9000, target: 9000, max: 6800))
        #expect(over.fillFraction == 1)
        #expect(over.rampTargetFraction == 1)
    }
}
