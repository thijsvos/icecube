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
    func curveFloor() throws {
        let targets = FanGuardian.curveTargets(for: [fan()], dieCelsius: 50)
        // Quantizing 2317 to a 100-RPM step gives 2300, which is BELOW the
        // SMC-reported minimum — the clamp in quantizedTarget is what keeps
        // this legal. 0 RPM is forbidden everywhere in Ice Cube.
        #expect(targets[0] == 2317)
        #expect(try #require(targets[0]) >= 2317)
    }

    @Test("The curve never commands below Mn or above Mx at any temperature")
    func curveStaysInRange() throws {
        for die in stride(from: 0.0, through: 120.0, by: 0.5) {
            let target = try #require(FanGuardian.curveTargets(for: [fan()], dieCelsius: die)[0])
            #expect(target >= 2317, "commanded \(target) at \(die) °C")
            #expect(target <= 6800, "commanded \(target) at \(die) °C")
        }
    }

    @Test("The curve is monotonic in temperature and maxes out by 95 °C")
    func curveMonotonic() throws {
        var previous = 0.0
        for die in stride(from: 60.0, through: 100.0, by: 1.0) {
            let target = try #require(FanGuardian.curveTargets(for: [fan()], dieCelsius: die)[0])
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

    /// Written against the configured limits rather than literals, so tuning
    /// the thresholds cannot silently invalidate the property being tested —
    /// which is "there is a wide band", not "the band is 65…75".
    @Test("Releases only below the release point, not merely below the engage point")
    func releaseHysteresis() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let hot = [fan(actual: 0)]
        _ = guardian.evaluate(fans: hot, dieCelsius: limits.engageCelsius + 5)
        _ = guardian.evaluate(fans: hot, dieCelsius: limits.engageCelsius + 5)
        #expect(guardian.isActive)

        // Just under the engage point is still inside the band: releasing here
        // would hand back and immediately re-engage.
        if case .release = guardian.evaluate(fans: hot, dieCelsius: limits.engageCelsius - 1) {
            Issue.record("released inside the hysteresis band — this flaps")
        }
        #expect(guardian.isActive)

        guard case .release = guardian.evaluate(fans: hot, dieCelsius: limits.releaseCelsius - 1) else {
            Issue.record("should release below \(limits.releaseCelsius) °C")
            return
        }
        #expect(guardian.isActive == false)
    }

    /// The band must stay wide enough that ordinary temperature noise cannot
    /// walk across it, whatever the thresholds are tuned to.
    @Test("The hysteresis band stays wide enough to prevent flapping")
    func hysteresisBandIsWide() {
        let limits = FanGuardian.Limits()
        #expect(limits.engageCelsius - limits.releaseCelsius >= 8)
    }

    /// The regression that prompted lowering the threshold: macOS holding both
    /// fans at 0 RPM with the die at 69.9 °C, which the old 75 °C floor sat out.
    @Test("Engages when macOS parks the fans at zero in the high 60s")
    func engagesWhenFansParkedInHighSixties() {
        var guardian = FanGuardian()
        let parked = [fan(id: 0, actual: 0), fan(id: 1, actual: 0)]
        _ = guardian.evaluate(fans: parked, dieCelsius: 69.9)
        guard case .engage = guardian.evaluate(fans: parked, dieCelsius: 69.9) else {
            Issue.record("stopped fans at 69.9 °C must not be left alone")
            return
        }
        #expect(guardian.isActive)
    }

    /// The counterweight: a lower floor must not turn the guardian into a
    /// second curve that overrides a macOS which is actually doing its job.
    @Test("A warm machine whose fans macOS is already spinning is left alone")
    func doesNotFightWorkingSystemControl() {
        var guardian = FanGuardian()
        let cooling = [fan(actual: 3000)] // comfortably above the floor demand
        for _ in 0 ..< 4 {
            #expect(guardian.evaluate(fans: cooling, dieCelsius: 69) == .idle)
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

    // MARK: - Keep spinning (why leaving macOS mode feels instant)

    /// The measurement behind this whole section, on a Mac14,9: a fan given a
    /// target **from rest** reads 0 RPM for 1.5 s and needs 4.4 s to reach
    /// speed, and the ramp is firmware-paced — commanding 6800 instead of 4250
    /// produces an identical curve. A fan already turning at 2317 covers the
    /// same ground in about a second. That is the entire difference between
    /// "curve → curve is instant" and "leaving macOS takes forever", and the
    /// only lever software has is to not be at a standstill.
    @Test("Warm fans parked in system mode are held at the floor, not left dead")
    func keepSpinningHoldsTheFloor() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        // `.system` (SMC mode 3) is what our own hand-back writes — and it is
        // exactly what the cool-orphan ladder below does NOT match, which is
        // why these fans used to sit at 0 RPM indefinitely.
        let parked = [fan(id: 0, mode: .system, actual: 0), fan(id: 1, mode: .system, actual: 0)]
        let warm = limits.keepSpinningCelsius + 5

        // First tick, no debounce — see `Limits.floorDebounceTicks`.
        guard case let .holdAtFloor(kick) = guardian.evaluate(fans: parked, dieCelsius: warm) else {
            Issue.record("stopped fans on a warm machine must not be left at rest")
            return
        }
        // Stopped, so both get the breakaway drive rather than their minimum.
        #expect(kick == [0: 4600, 1: 4600])
        // The popover must not claim macOS is in charge while we hold the fans.
        #expect(guardian.isActive)

        // Near the floor now: settle onto it, once, and then stop writing.
        let turning = [fan(id: 0, mode: .forced, actual: 2100), fan(id: 1, mode: .forced, actual: 2050)]
        guard case let .holdAtFloor(settled) = guardian.evaluate(fans: turning, dieCelsius: warm) else {
            Issue.record("a fan that got moving must be dropped back to the floor")
            return
        }
        #expect(settled == [0: 2317, 1: 2317])
        #expect(guardian.evaluate(fans: turning, dieCelsius: warm) == .idle)
    }

    /// The v7 breakaway was removed in v8 because 6800-vs-4250 measured
    /// identical. This is the opposite end of the scale, where the same Mac14,9
    /// fan sat still for 6.5 s on a 2317 command and moved in 1.5 s on ~4550 —
    /// so the property under test is "a stopped fan is not asked for its own
    /// minimum", not any particular number.
    @Test("A fan far below its minimum is never asked for the minimum it can't reach")
    func breakawayOnlyAppliesToStoppedFans() throws {
        let limits = FanGuardian.Limits()
        let stopped = fan(mode: .system, actual: 0)
        let turning = fan(id: 1, mode: .system, actual: 2100)
        let targets = FanGuardian.keepSpinningTargets(for: [stopped, turning], limits: limits)
        let kick = try #require(targets[0])
        #expect(kick > stopped.minRPM)
        #expect(kick <= stopped.maxRPM)
        // A fan that is already moving needs no help — it gets the floor.
        #expect(targets[1] == 2317)
    }

    /// The decision that actually makes leaving macOS mode fast, and the one
    /// the 2 s tick provably cannot make in time: taken while the fans are
    /// still at full speed, so they ramp DOWN to the floor instead of stopping.
    @Test("Handing back on a warm machine keeps the fans, at their floor")
    func handBackHoldsTheFloorWhenWarm() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        // Exactly what the daemon sees the instant it hands back: still fast.
        let spinning = [fan(id: 0, mode: .forced, actual: 4650), fan(id: 1, mode: .forced, actual: 4650)]

        guard case let .holdAtFloor(targets) = guardian.handBack(
            fans: spinning, dieCelsius: limits.keepSpinningCelsius + 5
        ) else {
            Issue.record("a warm machine must not have its fans handed back to a stop")
            return
        }
        #expect(targets == [0: 2317, 1: 2317])
        #expect(guardian.isActive)
        // And it stays held: no re-write, no drift back to a standstill.
        let held = [fan(id: 0, mode: .forced, actual: 2317), fan(id: 1, mode: .forced, actual: 2317)]
        #expect(guardian.evaluate(fans: held, dieCelsius: limits.keepSpinningCelsius + 5) == .idle)
    }

    /// The regression the owner caught on hardware: clicking macOS from a
    /// working Balanced curve, the die read 52.9 °C with the fans at 3226 RPM
    /// holding it there — under the tick's 55 °C bar, so nothing fired and the
    /// fans stopped anyway. The machine was cool *because* it was being cooled.
    @Test("Leaving a working curve holds the fans, even though the die reads cool")
    func handBackHoldsWhenCurveWasDoingItsJob() {
        var guardian = FanGuardian()
        // Exactly the state traced on the Mac14,9 at 15:33.
        let cooled = [fan(id: 0, mode: .forced, actual: 3226), fan(id: 1, mode: .forced, actual: 3250)]
        guard case let .holdAtFloor(targets) = guardian.handBack(fans: cooled, dieCelsius: 52.9) else {
            Issue.record("52.9 °C with the fans at 3226 is a machine being cooled, not a cold one")
            return
        }
        #expect(targets == [0: 2317, 1: 2317])
    }

    /// The hand-back bar has to sit BELOW the tick's, or it re-creates the bug:
    /// the tick catches fans that already stopped (expensive to restart), this
    /// catches fans still turning (free to keep).
    @Test("The hand-back holds at a lower temperature than the tick does")
    func handBackBarSitsBelowTheTickBar() {
        let limits = FanGuardian.Limits()
        #expect(limits.keepSpinningReleaseCelsius < limits.keepSpinningCelsius)
    }

    @Test("Handing back on a cold machine really does hand back")
    func handBackReleasesWhenCold() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let spinning = [fan(mode: .forced, actual: 4650)]
        guard case .release = guardian.handBack(
            fans: spinning, dieCelsius: limits.keepSpinningReleaseCelsius - 1
        ) else {
            Issue.record("macOS mode on a cold machine must mean silence")
            return
        }
        #expect(guardian.isActive == false)
    }

    /// SAFETY: fans whose `[Mn, Mx]` never read cannot be held at a floor that
    /// does not exist — that would command 0 RPM. Hand them back instead.
    @Test("Handing back with no usable fan range releases rather than inventing one")
    func handBackReleasesWithoutUsableFans() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let broken = [fan(mode: .forced, actual: 4650, minRPM: 0, maxRPM: 0)]
        guard case .release = guardian.handBack(
            fans: broken, dieCelsius: limits.keepSpinningReleaseCelsius + 5
        ) else {
            Issue.record("a fan with no usable range must never be held")
            return
        }
        #expect(guardian.isActive == false)
    }

    @Test("Handing back clears whatever the guardian was doing before")
    func handBackResetsPriorState() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let hot = [fan(actual: 0)]
        _ = guardian.evaluate(fans: hot, dieCelsius: limits.engageCelsius + 10)
        _ = guardian.evaluate(fans: hot, dieCelsius: limits.engageCelsius + 10)
        #expect(guardian.isActive) // driving the curve

        // Cold hand-back: everything must be forgotten, not merely paused.
        _ = guardian.handBack(fans: hot, dieCelsius: 30)
        #expect(guardian.isActive == false)
        // A fresh engage must take the full debounce again.
        #expect(guardian.evaluate(fans: hot, dieCelsius: limits.engageCelsius + 10) == .idle)
    }

    @Test("A genuinely cold machine is still left silent")
    func keepSpinningLeavesColdMachinesAlone() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let parked = [fan(mode: .system, actual: 0)]
        for _ in 0 ..< 5 {
            #expect(guardian.evaluate(fans: parked, dieCelsius: limits.keepSpinningCelsius - 1) == .idle)
        }
        #expect(guardian.isActive == false)
    }

    @Test("A fan macOS is already spinning is never surged to the floor")
    func keepSpinningIgnoresSpinningFans() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let spinning = [fan(mode: .system, actual: 2600)]
        for _ in 0 ..< 5 {
            #expect(guardian.evaluate(fans: spinning, dieCelsius: limits.keepSpinningCelsius + 5) == .idle)
        }
    }

    /// The window this closes, measured on hardware: handed back from 4400 RPM
    /// the fans read zero about four seconds later. The catch has to happen
    /// during those four seconds — a fan caught mid-coast never stops, so it
    /// never needs the 4.4 s standing start, and the user hears it settle
    /// rather than stop and restart.
    @Test("A fan coasting below its own minimum is caught on the way down")
    func keepSpinningCatchesFansOnTheWayDown() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let warm = limits.keepSpinningCelsius + 5

        // Still above Mn: macOS may yet be driving it, so hands off.
        #expect(guardian.evaluate(fans: [fan(mode: .system, actual: 3000)], dieCelsius: warm) == .idle)
        // Below Mn with nobody forcing it — it is on its way to a standstill.
        let coasting = [fan(mode: .system, actual: 2000)]
        guard case let .holdAtFloor(targets) = guardian.evaluate(fans: coasting, dieCelsius: warm) else {
            Issue.record("a coasting fan must be caught before it reaches zero")
            return
        }
        // Caught close to the floor, so the floor itself will hold it there.
        #expect(targets[0] == 2317)
    }

    /// A fan we are already driving must never be mistaken for one macOS parked.
    @Test("Fans already forced by Ice Cube never trigger the floor hold")
    func keepSpinningIgnoresOurOwnFans() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let ours = [fan(mode: .forced, actual: 0)] // mid-spin-up under our own command
        for _ in 0 ..< 5 {
            #expect(guardian.evaluate(fans: ours, dieCelsius: limits.keepSpinningCelsius + 5) == .idle)
        }
        #expect(guardian.isActive == false)
    }

    @Test("From the floor hold, a hot die escalates straight to the curve")
    func floorHoldEscalatesWhenHot() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let parked = [fan(mode: .system, actual: 0)]
        let warm = limits.keepSpinningCelsius + 5
        _ = guardian.evaluate(fans: parked, dieCelsius: warm)

        // Holding the floor already proves nobody else is cooling, so this must
        // not sit through the engage debounce a second time.
        let held = [fan(mode: .forced, actual: 2317)]
        guard case let .engage(targets, _) = guardian.evaluate(
            fans: held, dieCelsius: limits.engageCelsius + 1
        ) else {
            Issue.record("a floor hold that gets hot must escalate to the curve")
            return
        }
        #expect(targets[0] == FanGuardian.curveTargets(for: held, dieCelsius: limits.engageCelsius + 1)[0])
        #expect(guardian.isActive)
    }

    @Test("The floor hold releases only after a wide cool-down, not on noise")
    func floorHoldReleaseHysteresis() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let parked = [fan(mode: .system, actual: 0)]
        let warm = limits.keepSpinningCelsius + 5
        _ = guardian.evaluate(fans: parked, dieCelsius: warm)
        #expect(guardian.isActive)

        let held = [fan(mode: .forced, actual: 2317)]
        _ = guardian.evaluate(fans: held, dieCelsius: warm) // settle off the breakaway
        // Just under the trigger is still inside the band — releasing here would
        // stop the fans and re-start them a tick later, forever.
        #expect(guardian.evaluate(fans: held, dieCelsius: limits.keepSpinningCelsius - 1) == .idle)
        #expect(guardian.isActive)

        guard case .release = guardian.evaluate(
            fans: held, dieCelsius: limits.keepSpinningReleaseCelsius - 1
        ) else {
            Issue.record("should hand the fans back once truly cool")
            return
        }
        #expect(guardian.isActive == false)
    }

    @Test("The keep-spinning band is wide enough not to flap")
    func floorHoldBandIsWide() {
        let limits = FanGuardian.Limits()
        #expect(limits.keepSpinningCelsius - limits.keepSpinningReleaseCelsius >= 8)
        // Below the engage floor, or the floor hold would pre-empt real cooling.
        #expect(limits.keepSpinningCelsius < limits.engageCelsius)
    }

    @Test("reset() drops the floor hold too, so a revert can't leave it latched")
    func resetClearsFloorHold() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let parked = [fan(mode: .system, actual: 0)]
        let warm = limits.keepSpinningCelsius + 5
        _ = guardian.evaluate(fans: parked, dieCelsius: warm)
        #expect(guardian.isActive)

        guardian.reset()
        #expect(guardian.isActive == false)
        // Re-arms from scratch, including the remembered targets — a hold whose
        // `targets` survived a reset would suppress the next write as "unchanged".
        guard case let .holdAtFloor(targets) = guardian.evaluate(fans: parked, dieCelsius: warm) else {
            Issue.record("after reset the floor hold must re-arm from scratch")
            return
        }
        #expect(targets.isEmpty == false)
    }

    @Test("A fan whose range never read is never held at a fabricated floor")
    func floorHoldSkipsDegenerateFans() {
        let limits = FanGuardian.Limits()
        var guardian = FanGuardian()
        let broken = [fan(mode: .system, actual: 0, minRPM: 0, maxRPM: 0)]
        for _ in 0 ..< 5 {
            #expect(guardian.evaluate(fans: broken, dieCelsius: limits.keepSpinningCelsius + 5) == .idle)
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
        for _ in 0 ..< 3 {
            _ = guardian.evaluate(fans: orphan, dieCelsius: 40)
        }
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
