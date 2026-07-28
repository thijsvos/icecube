// SleepLatchTests.swift — the parked-for-sleep state machine, and the kIOMessage constants nobody can import.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("SleepLatch — park, stay parked, release")
struct SleepLatchTests {
    private static let tick = Duration.seconds(HelperConstants.tickInterval)

    @Test("A fresh latch is awake and lets the tick run normally")
    func startsAwake() {
        var latch = SleepLatch()
        #expect(!latch.isAsleep)
        #expect(!latch.parkLanded)
        #expect(!latch.sawNap)
        #expect(latch.tick(slept: .zero, tickInterval: Self.tick) == .proceed)
    }

    /// The first `systemWillSleep` must park; the repeats a dark-wake cycle
    /// fires must not, or the daemon writes `Tg` at stopped fans all night.
    @Test("Only the first will-sleep asks for a park")
    func onlyTheFirstWillSleepParks() {
        var latch = SleepLatch()
        // Hoisted out of `#expect`: the macro cannot call a mutating member.
        let firstAsked = latch.willSleep()
        #expect(firstAsked, "the lid just closed")
        #expect(latch.isAsleep)
        let secondAsked = latch.willSleep()
        #expect(!secondAsked, "a dark wake going back to sleep is not a new sleep")
    }

    @Test("A landed park makes the tick stand still")
    func landedParkStaysParked() {
        var latch = SleepLatch()
        _ = latch.willSleep()
        latch.noteParkLanded(true)
        #expect(latch.tick(slept: .zero, tickInterval: Self.tick) == .stayParked)
    }

    /// The audible case: if the hand-back never reached the SMC, the fans are
    /// still spinning and a dark wake is the first chance to fix it.
    @Test("A park that never landed is retried on the next tick")
    func failedParkRetries() {
        var latch = SleepLatch()
        _ = latch.willSleep()
        latch.noteParkLanded(false)
        #expect(latch.tick(slept: .zero, tickInterval: Self.tick) == .retryPark)
    }

    @Test("A measured nap is what proves the machine really slept")
    func napSetsSawNap() {
        var latch = SleepLatch()
        _ = latch.willSleep()
        latch.noteParkLanded(true)
        #expect(!latch.sawNap, "nothing has been observed yet")
        _ = latch.tick(slept: .zero, tickInterval: Self.tick)
        #expect(!latch.sawNap, "an ordinary tick is not a nap")
        _ = latch.tick(slept: .seconds(900), tickInterval: Self.tick)
        #expect(latch.sawNap)
    }

    /// The failsafe for a `kIOMessageSystemHasPoweredOn` that never arrives.
    @Test("Staying awake past the budget releases the latch")
    func missedWakeReleases() {
        var limits = SleepLatch.Limits()
        limits.missedWakeBudget = .seconds(10)
        var latch = SleepLatch(limits: limits)
        _ = latch.willSleep()
        latch.noteParkLanded(true)
        // 4 ticks × 2 s = 8 s: still inside the budget.
        for _ in 0 ..< 4 {
            #expect(latch.tick(slept: .zero, tickInterval: Self.tick) == .stayParked)
        }
        #expect(latch.tick(slept: .zero, tickInterval: Self.tick) == .missedWake, "10 s reached")
    }

    /// The counterweight: a night of 2-second dark wakes must never trip the
    /// failsafe, because each nap resets the awake run.
    @Test("Dark wakes reset the missed-wake budget instead of accumulating")
    func napsResetTheBudget() {
        var limits = SleepLatch.Limits()
        limits.missedWakeBudget = .seconds(10)
        var latch = SleepLatch(limits: limits)
        _ = latch.willSleep()
        latch.noteParkLanded(true)
        for _ in 0 ..< 20 {
            // Four awake ticks (8 s), then a real nap — a dark wake cycle.
            for _ in 0 ..< 4 {
                #expect(latch.tick(slept: .zero, tickInterval: Self.tick) == .stayParked)
            }
            #expect(latch.tick(slept: .seconds(900), tickInterval: Self.tick) == .stayParked)
        }
    }

    @Test("Release reports whether it was latched, and only once")
    func releaseIsIdempotent() {
        var latch = SleepLatch()
        let releasedWhileAwake = latch.release()
        #expect(!releasedWhileAwake, "was never latched")
        _ = latch.willSleep()
        let releasedWhileParked = latch.release()
        #expect(releasedWhileParked)
        #expect(!latch.isAsleep)
        let releasedTwice = latch.release()
        #expect(!releasedTwice, "already released")
    }

    /// A released latch forgets `sawNap` too, so the next sleep starts clean —
    /// otherwise a stale `sawNap` would let the very first heartbeat after the
    /// NEXT lid close unpark us before the machine had slept at all.
    @Test("A new sleep starts from a clean slate")
    func releaseForgetsEverything() {
        var latch = SleepLatch()
        _ = latch.willSleep()
        latch.noteParkLanded(true)
        _ = latch.tick(slept: .seconds(900), tickInterval: Self.tick)
        #expect(latch.sawNap)
        latch.release()
        _ = latch.willSleep()
        #expect(!latch.sawNap, "the previous sleep's nap must not carry over")
        #expect(!latch.parkLanded, "nor its landed park")
    }
}

@Suite("SystemPowerMessage — the constants Swift cannot import")
struct SystemPowerMessageTests {
    /// These are C macros (`#define kIOMessageSystemWillSleep
    /// iokit_common_msg(0x280)`), so Swift reports "macro unavailable" and they
    /// have to be written out by hand. Pinning them against the derivation
    /// `iokit_common_msg(x) = sys_iokit | sub_iokit_common | x = 0xE0000000 | x`
    /// is the only thing standing between a typo and a daemon that silently
    /// never hands the fans back — the exact bug this all exists to fix.
    ///
    /// Cross-checked against `<IOKit/IOMessage.h>` with a C probe on Mac14,9.
    @Test("Every message equals iokit_common_msg of its documented code")
    func messagesMatchTheMacroDerivation() {
        func iokitCommonMessage(_ code: UInt32) -> UInt32 {
            0xE000_0000 | code
        }
        #expect(SystemPowerMessage.canSystemSleep == iokitCommonMessage(0x270))
        #expect(SystemPowerMessage.systemWillSleep == iokitCommonMessage(0x280))
        #expect(SystemPowerMessage.systemWillNotSleep == iokitCommonMessage(0x290))
        #expect(SystemPowerMessage.systemHasPoweredOn == iokitCommonMessage(0x300))
        #expect(SystemPowerMessage.systemWillPowerOn == iokitCommonMessage(0x320))
    }

    /// Well inside IOKit's own 30 s cap, and the measured hand-back on the
    /// owner's Mac was 282 ms. A budget at or over the cap would let a wedged
    /// SMC delay the user's sleep and get Ice Cube named in `pmset -g log`.
    @Test("The acknowledgement budget stays far below IOKit's 30 s cap")
    func acknowledgementBudgetIsSane() {
        #expect(SleepPolicy.acknowledgementBudget > 1)
        #expect(SleepPolicy.acknowledgementBudget < 30)
    }
}
