// ManualTargetsTests.swift — the manual slider's rules, including the two ranges that would trap.

import Foundation
@testable import IceCubeKit
import Testing

private func fan(
    _ id: Int, actual: Double = 3000, target: Double = 3000,
    min: Double = 2317, max: Double = 6800
) -> Fan {
    Fan(id: id, name: "F\(id)", mode: .forced, actualRPM: actual, targetRPM: target, minRPM: min, maxRPM: max)
}

@Suite("ManualTargets — engaging, showing and sending")
struct ManualTargetsTests {
    // MARK: Engage where you are

    @Test("Engaging holds every fan at its current speed")
    func engageHoldsCurrentSpeed() {
        let targets = ManualTargets.engaging([fan(0, actual: 3400), fan(1, actual: 3600)])
        #expect(targets == [0: 3400, 1: 3600])
    }

    /// SAFETY. Engaging clamps into the fan's reported range — the same guard
    /// the daemon applies to every write, because `F{i}Mn`/`F{i}Mx` are
    /// advisory in firmware and 0 RPM can be accepted.
    @Test("Engaging clamps into the fan's range")
    func engageClamps() {
        #expect(ManualTargets.engaging([fan(0, actual: 500)])[0] == 2317, "below Mn")
        #expect(ManualTargets.engaging([fan(0, actual: 9000)])[0] == 6800, "above Mx")
    }

    /// `Mn` and `Mx` are read with independent `try?`s that each fall back to
    /// 0, so an inverted or degenerate range is a MODELLED outcome — and
    /// `ClosedRange(2317...0)` traps. This must return a value, not crash.
    @Test("A degenerate range does not trap")
    func degenerateRangeIsSafe() {
        let broken = ManualTargets.engaging([fan(0, actual: 3000, min: 2317, max: 0)])
        #expect(broken[0]?.isFinite == true)
        let zeroed = ManualTargets.engaging([fan(0, actual: 3000, min: 0, max: 0)])
        #expect(zeroed[0]?.isFinite == true)
    }

    /// Two fans reporting the same id is not supposed to happen, but
    /// `Dictionary(uniquingKeysWith:)` is here because the alternative
    /// (`uniqueKeysWithValues`) traps — and this runs on the path a user takes
    /// to grab the fans by hand.
    @Test("Duplicate fan ids do not trap")
    func duplicateIdsAreSafe() {
        let targets = ManualTargets.engaging([fan(0, actual: 3000), fan(0, actual: 4000)])
        #expect(targets.count == 1)
    }

    // MARK: Send every fan

    /// THE bug this rule exists for. `sliderTargets` is `@State` and starts
    /// empty on every popover reopen, so committing it verbatim sent a
    /// single-entry map: the untouched fan stayed physically forced while
    /// dropping out of the daemon's tracked config, where the read-back verify
    /// then reported it held and the wake re-assert skipped it.
    @Test("Committing one edited slider still sends a target for every fan")
    func commitCoversUntouchedFans() {
        let fans = [fan(0, actual: 3000), fan(1, actual: 3200)]
        let sent = ManualTargets.committing([0: 5000], fans: fans)
        #expect(sent.count == 2, "an untouched fan must not vanish from the config")
        #expect(sent[0] == 5000)
        #expect(sent[1] != nil)
    }

    @Test("An empty fan list sends nothing rather than inventing entries")
    func noFansSendsNothing() {
        #expect(ManualTargets.committing([0: 5000], fans: []).isEmpty)
    }

    /// KNOWN INCONSISTENCY, pinned so the fix is a deliberate commit rather
    /// than an accident. An untouched fan is SENT its clamped `actualRPM` but
    /// SHOWN its `targetRPM`. Reopen mid-ramp, drag one slider, and the other
    /// fan's commanded target silently drops to its tachometer reading while
    /// its slider still shows the old number. Unifying both on `targetRPM` is
    /// the fix — and a behaviour change.
    @Test("What is sent and what is shown disagree for an untouched fan (known gap)")
    func sentAndShownDisagree() {
        let ramping = fan(0, actual: 2400, target: 4400) // mid-ramp
        let sent = ManualTargets.committing([:], fans: [ramping])[0]
        let shown = ManualTargets.displayed([:], for: ramping)
        #expect(sent == 2400, "today: the tachometer reading is committed")
        #expect(shown == 4400, "today: the commanded target is displayed")
        #expect(sent != shown, "this is the gap; fixing it is a separate commit")
    }

    // MARK: Display and range

    @Test("A user's edit wins over the fan's target for display")
    func editWinsForDisplay() {
        #expect(ManualTargets.displayed([0: 5000], for: fan(0, target: 3000)) == 5000)
        #expect(ManualTargets.displayed([:], for: fan(0, target: 3000)) == 3000)
    }

    /// `minRPM ... 0` traps at runtime, and a fan whose `Mx` read failed
    /// reports exactly that.
    @Test("The slider range is never empty, even for an unreadable fan")
    func sliderRangeNeverTraps() {
        for f in [fan(0), fan(0, min: 2317, max: 0), fan(0, min: 0, max: 0)] {
            let range = ManualTargets.sliderRange(for: f)
            #expect(range.upperBound > range.lowerBound, "empty range for \(f.minRPM)…\(f.maxRPM)")
        }
    }
}
