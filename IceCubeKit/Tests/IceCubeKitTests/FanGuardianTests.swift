// FanGuardianTests.swift — the auto-mode guardian's ladder, debounces and hysteresis, on a scripted machine.

import Foundation
@testable import IceCubeKit
import Testing

/// The guardian encodes a field finding: macOS does not reliably resume fan
/// control after a fan app touches the SMC, and die temperatures were observed
/// climbing to 92 °C with the fans parked. Before extraction this logic lived
/// inline in the daemon actor and had no tests at all.
@Suite("FanGuardian — cooling when macOS won't")
struct FanGuardianTests {
    /// Mirrors the owner's Mac14,9: one fan, Mn 2317, Mx 6800.
    private func fan(
        id: Int = 0,
        mode: FanMode = .auto,
        actual: Double = 0,
        minRPM: Double = 2317,
        maxRPM: Double = 6800
    ) -> Fan {
        Fan(
            id: id, name: "Fan \(id)", mode: mode,
            actualRPM: actual, targetRPM: 0, minRPM: minRPM, maxRPM: maxRPM
        )
    }

    // MARK: - The built-in curve

    @Test("Below 70 °C the curve asks for the floor, never zero")
    func curveFloor() {
        let targets = FanGuardian.curveTargets(for: [fan()], dieCelsius: 50)
        // Quantizing 2317 to a 100-RPM step gives 2300, which is BELOW the
        // SMC-reported minimum — the clamp in quantizedTarget is what keeps
        // this legal. 0 RPM is forbidden everywhere in Ice Cube.
        #expect(targets[0] == 2317)
        #expect(targets[0]! >= 2317)
    }

    @Test("The curve never commands below Mn or above Mx at any temperature")
    func curveStaysInRange() {
        for die in stride(from: 0.0, through: 120.0, by: 0.5) {
            let target = FanGuardian.curveTargets(for: [fan()], dieCelsius: die)[0]!
            #expect(target >= 2317, "commanded \(target) at \(die) °C")
            #expect(target <= 6800, "commanded \(target) at \(die) °C")
        }
    }

    @Test("The curve is monotonic in temperature and maxes out by 95 °C")
    func curveMonotonic() {
        var previous = 0.0
        for die in stride(from: 60.0, through: 100.0, by: 1.0) {
            let target = FanGuardian.curveTargets(for: [fan()], dieCelsius: die)[0]!
            #expect(target >= previous, "curve went backwards at \(die) °C")
            previous = target
        }
        #expect(FanGuardian.curveTargets(for: [fan()], dieCelsius: 95)[0] == 6800)
        #expect(FanGuardian.curveTargets(for: [fan()], dieCelsius: 110)[0] == 6800)
    }

    // MARK: - Engage debounce and hysteresis

    @Test("A single hot tick does not engage — the debounce needs two")
    func engageDebounce() {
        var guardian = FanGuardian()
        let hot = [fan(actual: 0)]
        #expect(guardian.evaluate(fans: hot, dieCelsius: 80) == .idle)
        #expect(guardian.isActive == false)

        guard case .engage = guardian.evaluate(fans: hot, dieCelsius: 80) else {
            Issue.record("second consecutive hot tick should engage")
            return
        }
        #expect(guardian.isActive)
    }

    @Test("A cool tick between hot ticks resets the debounce")
    func engageDebounceResets() {
        var guardian = FanGuardian()
        let hot = [fan(actual: 0)]
        #expect(guardian.evaluate(fans: hot, dieCelsius: 80) == .idle)
        #expect(guardian.evaluate(fans: hot, dieCelsius: 40) == .idle) // cools off
        #expect(guardian.evaluate(fans: hot, dieCelsius: 80) == .idle) // counter restarted
        #expect(guardian.isActive == false)
    }

    @Test("Warm but already-spinning fans never engage the guardian")
    func spinningFansStandDown() {
        var guardian = FanGuardian()
        // Demand at 80 °C is well under 5000; a fan at 5000 RPM is cooling.
        let spinning = [fan(actual: 5000)]
        #expect(guardian.evaluate(fans: spinning, dieCelsius: 80) == .idle)
        #expect(guardian.evaluate(fans: spinning, dieCelsius: 80) == .idle)
        #expect(guardian.isActive == false)
    }

    @Test("Releases only below 65 °C, not merely below the 75 °C engage point")
    func releaseHysteresis() {
        var guardian = FanGuardian()
        let hot = [fan(actual: 0)]
        _ = guardian.evaluate(fans: hot, dieCelsius: 80)
        _ = guardian.evaluate(fans: hot, dieCelsius: 80)
        #expect(guardian.isActive)

        // 70 °C is below the engage threshold but inside the hysteresis band.
        if case .release = guardian.evaluate(fans: hot, dieCelsius: 70) {
            Issue.record("released inside the hysteresis band — this flaps")
        }
        #expect(guardian.isActive)

        guard case .release = guardian.evaluate(fans: hot, dieCelsius: 64) else {
            Issue.record("should release below 65 °C")
            return
        }
        #expect(guardian.isActive == false)
    }

    @Test("While active, an unchanged target reports idle instead of re-writing")
    func noWriteChurn() {
        var guardian = FanGuardian()
        let hot = [fan(actual: 0)]
        _ = guardian.evaluate(fans: hot, dieCelsius: 80)
        _ = guardian.evaluate(fans: hot, dieCelsius: 80)
        // Same temperature, same quantized target → no write.
        #expect(guardian.evaluate(fans: hot, dieCelsius: 80) == .idle)
        // A real change does write.
        guard case .engage = guardian.evaluate(fans: hot, dieCelsius: 90) else {
            Issue.record("a materially hotter die should re-aim the fans")
            return
        }
    }

    // MARK: - The cool-orphan ladder

    @Test("An orphaned fan takes three ticks, then re-parks before escalating")
    func orphanLadder() {
        var guardian = FanGuardian()
        let orphan = [fan(mode: .auto, actual: 0)]
        #expect(guardian.evaluate(fans: orphan, dieCelsius: 40) == .idle)
        #expect(guardian.evaluate(fans: orphan, dieCelsius: 40) == .idle)
        guard case let .reparkOrphans(fans) = guardian.evaluate(fans: orphan, dieCelsius: 40) else {
            Issue.record("third consecutive orphaned tick should re-park")
            return
        }
        #expect(fans.count == 1)
    }

    @Test("Only after re-parking fails does the guardian hold the floor itself")
    func orphanEscalation() {
        var guardian = FanGuardian()
        let orphan = [fan(mode: .auto, actual: 0)]
        for _ in 0 ..< 3 { _ = guardian.evaluate(fans: orphan, dieCelsius: 40) }
        // Second pass through the debounce escalates to stage 2.
        _ = guardian.evaluate(fans: orphan, dieCelsius: 40)
        _ = guardian.evaluate(fans: orphan, dieCelsius: 40)
        guard case let .holdAtFloor(targets) = guardian.evaluate(fans: orphan, dieCelsius: 40) else {
            Issue.record("a system that never resumed should be held at the floor")
            return
        }
        #expect(targets[0] == 2317)
    }

    @Test("A healthy fan clears the orphan counters")
    func orphanCountersClear() {
        var guardian = FanGuardian()
        let orphan = [fan(mode: .auto, actual: 0)]
        let healthy = [fan(mode: .auto, actual: 2400)]
        _ = guardian.evaluate(fans: orphan, dieCelsius: 40)
        _ = guardian.evaluate(fans: orphan, dieCelsius: 40)
        #expect(guardian.evaluate(fans: healthy, dieCelsius: 40) == .idle)
        // Counter restarted: two more orphaned ticks must not reach the ladder.
        #expect(guardian.evaluate(fans: orphan, dieCelsius: 40) == .idle)
        #expect(guardian.evaluate(fans: orphan, dieCelsius: 40) == .idle)
    }

    /// This is the bug the extraction fixes. `revertEverything` used to clear
    /// the engage debounce but leave `deadFanTicks`/`recoveryStage` behind, so
    /// a revert taken mid-ladder let the next orphaned tick fire early and skip
    /// the gentle "re-park and hand back" stage entirely.
    @Test("reset() clears every counter, so a revert can't leave the ladder primed")
    func resetClearsEveryCounter() {
        var guardian = FanGuardian()
        let orphan = [fan(mode: .auto, actual: 0)]
        _ = guardian.evaluate(fans: orphan, dieCelsius: 40)
        _ = guardian.evaluate(fans: orphan, dieCelsius: 40) // ladder primed at 2/3

        guardian.reset()

        // Must take the full three ticks again, and must start at stage 1.
        #expect(guardian.evaluate(fans: orphan, dieCelsius: 40) == .idle)
        #expect(guardian.evaluate(fans: orphan, dieCelsius: 40) == .idle)
        guard case .reparkOrphans = guardian.evaluate(fans: orphan, dieCelsius: 40) else {
            Issue.record("after reset the ladder must restart at the gentle stage")
            return
        }
    }

    @Test("reset() also drops active state and its remembered targets")
    func resetClearsActiveState() {
        var guardian = FanGuardian()
        let hot = [fan(actual: 0)]
        _ = guardian.evaluate(fans: hot, dieCelsius: 80)
        _ = guardian.evaluate(fans: hot, dieCelsius: 80)
        #expect(guardian.isActive)

        guardian.reset()
        #expect(guardian.isActive == false)
        // A fresh engage must be commanded, not suppressed as "unchanged".
        _ = guardian.evaluate(fans: hot, dieCelsius: 80)
        guard case .engage = guardian.evaluate(fans: hot, dieCelsius: 80) else {
            Issue.record("after reset the guardian must re-engage from scratch")
            return
        }
    }

    @Test("A fan whose range never read (Mn == Mx == 0) is skipped, never driven")
    func degenerateRange() {
        let broken = fan(minRPM: 0, maxRPM: 0)
        // Mapping a fraction into a 0…0 range would command 0 RPM, which is
        // forbidden everywhere in Ice Cube. Skipped entirely, not clamped to 0.
        #expect(FanGuardian.curveTargets(for: [broken], dieCelsius: 90).isEmpty)

        // A degenerate fan alongside a healthy one must not suppress the healthy one.
        let mixed = FanGuardian.curveTargets(for: [broken, fan(id: 1)], dieCelsius: 90)
        #expect(mixed.count == 1)
        #expect(mixed[1] != nil)
        #expect(mixed[0] == nil)
    }

    @Test("A degenerate fan never triggers an engage on its own")
    func degenerateFanNeverEngages() {
        var guardian = FanGuardian()
        let broken = [fan(actual: 0, minRPM: 0, maxRPM: 0)]
        #expect(guardian.evaluate(fans: broken, dieCelsius: 90) == .idle)
        #expect(guardian.evaluate(fans: broken, dieCelsius: 90) == .idle)
        #expect(guardian.isActive == false)
    }
}
