// ProcessEnergy.swift — per-process watts, and the seam that keeps simulated mode away from real PIDs.

import Foundation

/// One process's mean power draw over a measured interval.
///
/// **Watts, not a score.** The kernel reports cumulative energy in nanojoules
/// (`ri_energy_nj`), so differencing two samples over a known interval yields a
/// genuine physical quantity. That is the whole reason this type exists in an
/// app that otherwise refuses to show numbers it cannot justify: Activity
/// Monitor's "Energy Impact" is a unitless, undocumented composite, and a fan
/// app that showed one next to real watts from the SMC would be inviting a
/// comparison neither number supports.
public struct ProcessEnergySample: Sendable, Equatable, Identifiable, Codable {
    public let pid: Int32
    /// The executable name (`proc_name`), truncated by the kernel to 16 bytes
    /// on some paths — so "Mattermost Helpe" rather than the full bundle name
    /// is normal and not a bug.
    public let name: String
    /// Mean power over the sampling interval, in watts.
    public let watts: Double

    public var id: Int32 {
        pid
    }

    public init(pid: Int32, name: String, watts: Double) {
        self.pid = pid
        self.name = name
        self.watts = watts
    }
}

/// One pass of per-process sampling: who was drawing power, and how much of the
/// machine could not be seen.
///
/// The unreadable count is not bookkeeping — it is load-bearing. On the
/// project's test machine 205 of 616 PIDs were unreadable without root, and
/// they include `kernel_task` and `WindowServer`, which are often genuinely
/// significant. A list presented without that caveat would read as complete
/// when it is not.
public struct ProcessEnergyReading: Sendable, Equatable {
    public let date: Date
    /// The interval these watts are averaged over, in seconds.
    public let interval: TimeInterval
    /// The biggest draws, highest first, resolved to display names.
    ///
    /// A **display** list, not the whole measurement. Resolving a name costs a
    /// syscall per process and at ~400 readable PIDs that would double the cost
    /// of a pass for rows nobody reads, so only the leaders are named. Use
    /// ``attributedWatts`` for arithmetic — summing this list instead would
    /// quietly fold every un-displayed process into the "unattributed"
    /// remainder and overstate what Ice Cube cannot see.
    public let processes: [ProcessEnergySample]
    /// Total watts across **every readable process**, named or not.
    ///
    /// **Always less than the SMC's system total, and the gap is the point.** It
    /// excludes the display, the SSD, radios, GPU work that never appears in a
    /// process's CPU energy, and every unreadable PID below.
    /// ``ThermalDiagnosis`` reports the remainder rather than hiding it; see
    /// docs/DIAGNOSIS.md for why a list that summed to 100 % would be a lie.
    public let attributedWatts: Double
    /// PIDs that were listed but whose usage could not be read.
    ///
    /// Two causes, deliberately not distinguished: the process belongs to
    /// another user (needs root), or it exited between listing and reading.
    /// Telling them apart would need a second syscall per miss and would not
    /// change what the UI says.
    public let unreadableCount: Int
    /// PIDs listed in this pass, readable or not.
    public let totalCount: Int

    public init(
        date: Date,
        interval: TimeInterval,
        processes: [ProcessEnergySample],
        attributedWatts: Double,
        unreadableCount: Int,
        totalCount: Int
    ) {
        self.date = date
        self.interval = interval
        self.processes = processes
        self.attributedWatts = attributedWatts
        self.unreadableCount = unreadableCount
        self.totalCount = totalCount
    }

    /// The `count` biggest draws.
    public func top(_ count: Int) -> [ProcessEnergySample] {
        Array(processes.prefix(count))
    }
}

/// Per-process power sampling.
///
/// A protocol for exactly the reason ``SMCProviding`` is one: so that a
/// simulated launch reads **no real PID**. Process names say what a person
/// works on, and CLAUDE.md rule 3 requires every feature to be demonstrable
/// with `ICECUBE_SIMULATED=1` — those two together mean the simulated build
/// needs plausible fake processes, not a disabled panel and not the real list.
///
/// Implementations:
/// - ``MockProcessSampler`` — deterministic fiction; what CI and simulated mode use.
/// - ``SystemProcessSampler`` — real `proc_pid_rusage` reads. Needs no root, and
///   silently sees less without it.
public protocol ProcessSampling: Sendable {
    /// Samples now, returning power drawn **since the previous call**.
    ///
    /// A sampler that differences a kernel counter returns `nil` on the first
    /// call of a process's life and whenever too little time has passed to
    /// divide by: a rate cannot be computed from one cumulative reading, and the
    /// honest answer to "what is drawing power right now?" before any interval
    /// has elapsed is "ask again in a moment" — not a number derived from a
    /// single sample.
    ///
    /// ``SystemProcessSampler`` owns that rule. ``MockProcessSampler`` has no
    /// counter to difference and answers on the first call, so a simulated run
    /// never sits on the "measuring" state.
    func sample() async -> ProcessEnergyReading?

    /// Forgets the previous cumulative reading, so the next ``sample()`` starts
    /// a fresh interval instead of differencing against a stale one.
    ///
    /// Called when the diagnosis window opens. Without it, a sampler that
    /// survives the window being closed divides one interval's energy by the
    /// entire time the window was shut: reopen after an hour and every process
    /// shows a few hundredths of a watt for one tick before self-correcting.
    /// That reads as "nothing is using power", which is exactly the wrong
    /// answer to have on screen at the moment someone opens the window to ask.
    ///
    /// No default implementation, deliberately — a sampler that silently
    /// ignored this would reintroduce the bug with the compiler saying nothing.
    func reset() async
}

/// A deterministic fake process list for simulated mode and tests.
///
/// Like ``MockSMCProvider``, every reading is a pure function of the injected
/// clock — no stored state, no `SystemRandomNumberGenerator` — so two runs with
/// the same clock produce identical output and a test can assert exact values.
///
/// The fiction is shaped to exercise the UI's honest cases rather than to look
/// impressive: the attributed total stays well under the simulated machine's
/// `PSTR` so the "unattributed remainder" row always has something to say, and
/// a plausible number of PIDs are marked unreadable so that caveat is visible
/// in screenshots too.
public struct MockProcessSampler: ProcessSampling {
    /// Nothing to forget: every reading is a pure function of the clock, so
    /// there is no cumulative counter being differenced.
    public func reset() async {}

    private let now: @Sendable () -> Date

    /// The first fake PID, chosen **above Darwin's PID ceiling** (99999) so a
    /// simulated PID can never name a process that actually exists.
    ///
    /// Not cosmetic. `SimulatedIsolationTests` proves the privacy guarantee by
    /// asserting no reported PID is live, and the mock originally numbered from
    /// 1000 — a range this very machine reaches (PIDs observed up to 99423), so
    /// the test passed by luck and would have failed at random. Putting the
    /// fiction out of reach makes the guarantee structural instead of lucky.
    public static let firstFakePID: Int32 = 900_001

    /// Names chosen to be obviously synthetic on inspection while still
    /// exercising realistic layout: a long name that will need truncating, a
    /// helper-style name with parentheses, and short ones.
    private static let cast = [
        "Simulated Compiler",
        "Simulated Browser (Renderer)",
        "Simulated Indexer",
        "WindowServer",
        "Simulated Sync",
        "Simulated Daemon",
    ]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func sample() async -> ProcessEnergyReading? {
        let date = now()
        let t = date.timeIntervalSince1970
        // One slow cycle so the ordering visibly changes while someone watches,
        // without the list churning every tick.
        let phase = t / 45

        let processes = Self.cast.enumerated().map { index, name in
            // Each process gets its own phase offset, so they cross over.
            let wave = (sin(phase + Double(index) * 1.3) + 1) / 2 // 0…1
            let scale = 4.0 / Double(index + 1) // leaders draw more
            return ProcessEnergySample(
                pid: Self.firstFakePID + Int32(index),
                name: name,
                watts: (0.15 + wave * scale).rounded(toPlaces: 2)
            )
        }
        .sorted { $0.watts > $1.watts }

        // A little above the named list, standing in for the long tail of small
        // processes a real machine has — so the simulated remainder is not
        // accidentally the cleanest number on screen.
        let attributed = processes.reduce(0) { $0 + $1.watts } + 0.9

        return ProcessEnergyReading(
            date: date,
            interval: 1,
            processes: processes,
            attributedWatts: attributed,
            unreadableCount: 118,
            totalCount: 402
        )
    }
}

private extension Double {
    /// Rounds to `places` decimals. Keeps the mock's output readable in tests
    /// and stops a wall of noise digits in screenshots.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
