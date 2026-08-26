// SystemProcessSamplerTests.swift — a rate needs a fresh interval, not a stale one.

import Foundation
@testable import IceCubeKit
import Testing

/// A clock the test drives, so the interval between samples is exact rather
/// than however long the machine took.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 0
    private let step: TimeInterval

    init(step: TimeInterval) {
        self.step = step
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        seconds += step
        return Date(timeIntervalSinceReferenceDate: seconds)
    }
}

/// The bug: the sampler is an actor that outlives the diagnosis window, so its
/// last cumulative reading is from whenever the window was last closed.
/// Differencing against that divides one interval's energy by however long the
/// window was shut — reopen after an hour and every process shows a few
/// hundredths of a watt for one tick before self-correcting.
///
/// That is not a cosmetic glitch. It reads as "nothing is using power" at the
/// exact moment somebody opened the window to ask what is, which is how a real
/// user came to report that "Why is it hot?" had no entries above 0.03 W.
@Suite("SystemProcessSampler — reopening the window starts a fresh interval")
struct SystemProcessSamplerTests {
    @Test("The first sample after a reset reports nothing, as the very first one does")
    func resetForcesAFreshInterval() async {
        let clock = SteppingClock(step: 1) // comfortably over the 0.2 s floor
        let sampler = SystemProcessSampler(now: { clock.next() })

        #expect(await sampler.sample() == nil, "one cumulative reading is not a rate")
        #expect(await sampler.sample() != nil, "two readings a second apart are")

        await sampler.reset()

        let afterReset = await sampler.sample()
        #expect(afterReset == nil, "after a reset it must wait for a real interval, not use the stale one")
        #expect(await sampler.sample() != nil, "and then recover on the next pass")
    }
}
