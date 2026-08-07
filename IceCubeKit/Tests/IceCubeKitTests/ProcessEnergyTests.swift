// ProcessEnergyTests.swift — the differencing hazards, which only a pure function can be made to reproduce.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("Per-process watts")
struct ProcessEnergyTests {
    typealias Previous = SystemProcessSampler.Previous

    // MARK: - The differencing rules

    @Test("A lifetime counter alone yields no rate")
    func firstReadingHasNoRate() {
        let current = Previous(startAbsTime: 1000, energyNanojoules: 5_000_000_000)
        #expect(SystemProcessSampler.watts(previous: nil, current: current, interval: 2) == nil)
    }

    @Test("Normal case: 2 J over 2 s is 1 W")
    func steadyDrawDividesCorrectly() throws {
        let before = Previous(startAbsTime: 1000, energyNanojoules: 1_000_000_000)
        let after = Previous(startAbsTime: 1000, energyNanojoules: 3_000_000_000)
        let watts = try #require(SystemProcessSampler.watts(previous: before, current: after, interval: 2))
        #expect(abs(watts - 1.0) < 1e-9)
    }

    /// The hazard that motivated carrying `startAbsTime` at all.
    ///
    /// A recycled PID whose newcomer has *more* lifetime energy than its
    /// predecessor produces a large, plausible, entirely fabricated spike — the
    /// worst kind, because nothing about it looks wrong. Keying on the PID alone
    /// would report 100 W here.
    @Test("A recycled PID is not the same process, however plausible the delta")
    func recycledPIDIsRejected() {
        let old = Previous(startAbsTime: 1000, energyNanojoules: 1_000_000_000)
        let newcomer = Previous(startAbsTime: 9999, energyNanojoules: 201_000_000_000)
        #expect(SystemProcessSampler.watts(previous: old, current: newcomer, interval: 2) == nil)
    }

    @Test("A counter that went backwards is a gap, not a negative")
    func counterRegressionIsRejected() {
        let before = Previous(startAbsTime: 1000, energyNanojoules: 5_000_000_000)
        let after = Previous(startAbsTime: 1000, energyNanojoules: 4_000_000_000)
        #expect(SystemProcessSampler.watts(previous: before, current: after, interval: 2) == nil)
    }

    @Test("An interval too short to divide by is refused")
    func tooShortAnIntervalIsRejected() {
        let before = Previous(startAbsTime: 1000, energyNanojoules: 1_000_000_000)
        let after = Previous(startAbsTime: 1000, energyNanojoules: 2_000_000_000)
        #expect(SystemProcessSampler.watts(previous: before, current: after, interval: 0.05) == nil)
        #expect(SystemProcessSampler.watts(previous: before, current: after, interval: 0) == nil)
    }

    @Test("A non-finite interval never becomes a number")
    func nonFiniteIntervalIsRejected() {
        let before = Previous(startAbsTime: 1000, energyNanojoules: 1_000_000_000)
        let after = Previous(startAbsTime: 1000, energyNanojoules: 2_000_000_000)
        #expect(SystemProcessSampler.watts(previous: before, current: after, interval: .infinity) == nil)
        #expect(SystemProcessSampler.watts(previous: before, current: after, interval: .nan) == nil)
    }

    @Test("An idle process reads zero, not nothing")
    func idleProcessIsZeroNotNil() throws {
        let same = Previous(startAbsTime: 1000, energyNanojoules: 7_000_000_000)
        let watts = try #require(SystemProcessSampler.watts(previous: same, current: same, interval: 2))
        #expect(watts == 0)
    }

    // MARK: - The reading's accounting

    /// `attributedWatts` must be the total across *every* readable process, not
    /// the sum of the displayed leaders. Conflating them silently inflates the
    /// "unattributed" remainder — the one figure whose whole purpose is to be
    /// honest about what Ice Cube cannot see.
    @Test("Attributed watts are the whole measurement, not the visible list")
    func attributedIsNotTheDisplayedSum() {
        let reading = ProcessEnergyReading(
            date: Date(),
            interval: 1,
            processes: [ProcessEnergySample(pid: 1, name: "big", watts: 4)],
            attributedWatts: 9.5,
            unreadableCount: 10,
            totalCount: 100
        )
        #expect(reading.attributedWatts == 9.5)
        #expect(reading.processes.reduce(0) { $0 + $1.watts } == 4)
    }

    @Test("top(_:) truncates without reordering")
    func topTruncates() {
        let reading = ProcessEnergyReading(
            date: Date(),
            interval: 1,
            processes: (1 ... 5).map { ProcessEnergySample(pid: Int32($0), name: "p\($0)", watts: Double(6 - $0)) },
            attributedWatts: 15,
            unreadableCount: 0,
            totalCount: 5
        )
        #expect(reading.top(2).map(\.pid) == [1, 2])
        #expect(reading.top(99).count == 5)
    }

    // MARK: - The mock

    @Test("The mock replays exactly for a fixed clock")
    func mockIsDeterministic() async throws {
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
        let first = try #require(await MockProcessSampler(now: clock).sample())
        let second = try #require(await MockProcessSampler(now: clock).sample())
        #expect(first == second)
    }

    @Test("The mock is sorted, positive, and leaves a tail for the remainder")
    func mockIsWellFormed() async throws {
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_123) }
        let reading = try #require(await MockProcessSampler(now: clock).sample())

        #expect(reading.processes == reading.processes.sorted { $0.watts > $1.watts })
        #expect(reading.processes.allSatisfy { $0.watts > 0 })
        #expect(reading.unreadableCount < reading.totalCount)
        // Strictly greater: a simulated run must exercise the "there is more
        // than the list shows" path, not accidentally present a tidy total.
        #expect(reading.attributedWatts > reading.processes.reduce(0) { $0 + $1.watts })
    }

    /// Simulated mode must be able to show the unattributed remainder, which
    /// means the fake attribution has to stay under the fake machine's draw.
    @Test("The mock never attributes more than the simulated Mac draws")
    func mockStaysUnderSimulatedSystemPower() async throws {
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_500) }
        let reading = try #require(await MockProcessSampler(now: clock).sample())
        let systemWatts = try #require(await MockSMCProvider(now: clock).power())
        #expect(reading.attributedWatts < systemWatts)
    }

    // MARK: - The real sampler, against this machine

    /// Runs the real reader and asserts only what must hold on any Mac.
    ///
    /// Deliberately value-free: process names and wattages are whatever the
    /// host happens to be doing, so pinning them would make the suite a
    /// weather report. The invariants are the contract, and one of them —
    /// `attributedWatts` covering more than the displayed leaders — is the only
    /// guard on a truncation bug that cannot be reproduced against scripted
    /// values, because the display list is built inside the syscall loop.
    @Test("The real sampler needs two passes, then reports a coherent reading")
    func realSamplerInvariants() async throws {
        let sampler = SystemProcessSampler()

        // A lifetime counter is not a rate. The first pass may only set a baseline.
        #expect(await sampler.sample() == nil, "the first pass must not invent a rate")

        try await Task.sleep(for: .milliseconds(400))
        let reading = try #require(await sampler.sample(), "a second pass should produce a reading")

        #expect(reading.interval >= 0.2)
        #expect(reading.totalCount > 0)
        #expect(reading.unreadableCount >= 0)
        #expect(reading.unreadableCount <= reading.totalCount)
        #expect(reading.processes.count <= 12, "the display list is capped")
        #expect(reading.processes == reading.processes.sorted { $0.watts > $1.watts })
        #expect(reading.processes.allSatisfy { $0.watts.isFinite && $0.watts > 0 })
        #expect(reading.attributedWatts.isFinite)
        #expect(reading.attributedWatts >= 0)
        // The whole measurement, not the visible slice.
        #expect(reading.attributedWatts >= reading.processes.reduce(0) { $0 + $1.watts } - 1e-9)
    }
}
