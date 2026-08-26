// SystemProcessSampler.swift — the real per-process power reader: cumulative kernel energy, differenced into watts.

import Darwin
import Foundation

/// Reads per-process energy from the kernel and turns it into watts.
///
/// ## Where the number comes from
///
/// `proc_pid_rusage` fills a `rusage_info_v6`, whose `ri_energy_nj` field is the
/// **cumulative energy the process has consumed since it started, in
/// nanojoules**. It is a counter, not a rate — so a single reading says nothing
/// about right now. Two readings a known interval apart do:
///
///     watts = (energy₂ − energy₁) × 1e-9 / seconds
///
/// This is public SDK surface (`sys/resource.h`, `rusage_info_v6`), not a
/// private API, and it needs no entitlement and no root.
///
/// ## What it cannot see, measured
///
/// On the project's test machine (Mac14,9, macOS 26.4) a single unprivileged
/// pass saw **616 PIDs, read 410, and was denied 205**. The denied set is
/// other users' processes — which on a Mac means root's, including
/// `kernel_task` and `WindowServer`. Both can be genuinely large. Every reading
/// therefore carries ``ProcessEnergyReading/unreadableCount`` so the UI can say
/// so rather than presenting a partial list as the whole picture.
///
/// It is also **CPU** energy. GPU work does not appear here, which is why
/// ``ThermalDiagnosis`` reads this alongside the SMC's sensor classes: a load
/// that shows small process figures and a large unattributed remainder, with
/// the GPU leading the die sensors, is a graphics load and the app says so.
public actor SystemProcessSampler: ProcessSampling {
    /// What the previous pass saw for one process.
    ///
    /// `startAbsTime` is carried purely as an identity check. PIDs are recycled,
    /// and a recycled PID's cumulative energy restarts near zero — so keying on
    /// the PID alone produces either a negative delta (obvious, catchable) or,
    /// worse, a plausible positive one when the newcomer happens to have
    /// out-earned its predecessor. Comparing the process start time is exact,
    /// costs nothing (it is in the same struct we already read), and removes the
    /// whole class of error.
    struct Previous: Equatable {
        let startAbsTime: UInt64
        let energyNanojoules: UInt64
    }

    /// Watts for one process between two readings, or `nil` when the pair
    /// cannot honestly produce a rate.
    ///
    /// Extracted from the sampling loop because this is where every correctness
    /// hazard in the file lives, and all of them are invisible against real
    /// syscalls: they need a *recycled PID* or a *counter regression* to
    /// reproduce, neither of which can be staged on demand. As a pure function
    /// they are four lines and four tests.
    ///
    /// Returns `nil` when:
    /// - **there is no previous reading** — a lifetime counter says nothing
    ///   about this interval, and apportioning it would over- or under-state a
    ///   new process by however long it had already been running;
    /// - **the start times differ** — the PID was recycled, so the two readings
    ///   describe different processes. Without this the newcomer's lifetime
    ///   energy is read as one interval's worth, which is a large fabricated
    ///   spike rather than an obviously-wrong negative;
    /// - **the counter went backwards** — impossible for a monotonic counter, so
    ///   something is wrong and a guess is worse than a gap;
    /// - **the interval is not usable** — see ``minimumInterval``.
    static func watts(previous: Previous?, current: Previous, interval: TimeInterval) -> Double? {
        guard let previous else { return nil }
        guard previous.startAbsTime == current.startAbsTime else { return nil }
        guard current.energyNanojoules >= previous.energyNanojoules else { return nil }
        guard interval.isFinite, interval >= minimumInterval else { return nil }
        let watts = Double(current.energyNanojoules - previous.energyNanojoules) * 1e-9 / interval
        return watts.isFinite ? watts : nil
    }

    private var previous: [pid_t: Previous] = [:]
    private var previousDate: Date?
    private let now: @Sendable () -> Date

    /// How many processes to resolve display names for.
    ///
    /// Name resolution is a second syscall per process, and at ~400 readable
    /// PIDs that would double the cost of a pass for information nobody sees.
    /// Energy is measured for every process; only the leaders get named.
    private static let namedCount = 12

    /// Shortest interval worth dividing by.
    ///
    /// Below this the quotient is dominated by when the two syscalls happened
    /// rather than by what the process did — the same reasoning that gives
    /// ``CoolingEfficiency`` a power floor.
    private static let minimumInterval: TimeInterval = 0.2

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func reset() {
        previous.removeAll()
        previousDate = nil
    }

    public func sample() async -> ProcessEnergyReading? {
        let date = now()
        let pids = Self.listPIDs()

        let interval = previousDate.map { date.timeIntervalSince($0) }

        var current: [pid_t: Previous] = [:]
        current.reserveCapacity(pids.count)
        var draws: [(pid: pid_t, watts: Double)] = []
        var unreadable = 0

        for pid in pids where pid > 0 {
            guard let usage = Self.usage(of: pid) else {
                unreadable += 1
                continue
            }
            let entry = Previous(
                startAbsTime: usage.ri_proc_start_abstime,
                energyNanojoules: usage.ri_energy_nj
            )
            current[pid] = entry

            guard
                let interval,
                let watts = Self.watts(previous: previous[pid], current: entry, interval: interval),
                watts > 0
            else { continue }
            draws.append((pid, watts))
        }

        // Replaced wholesale rather than merged: exited PIDs must not linger, or
        // a long-uptime app accumulates a dictionary of the dead.
        previous = current
        previousDate = date

        guard let interval, interval >= Self.minimumInterval else { return nil }

        // Summed across every readable process, *before* the display list is
        // truncated. Summing the truncated list instead would fold the several
        // hundred small processes into the "unattributed" remainder and
        // overstate what Ice Cube cannot account for — the one number this
        // feature must not get wrong.
        let attributed = draws.reduce(0) { $0 + $1.watts }

        draws.sort { $0.watts > $1.watts }
        let processes = draws.prefix(Self.namedCount).map {
            ProcessEnergySample(pid: $0.pid, name: Self.name(of: $0.pid), watts: $0.watts)
        }

        return ProcessEnergyReading(
            date: date,
            interval: interval,
            processes: processes,
            attributedWatts: attributed.isFinite ? attributed : 0,
            unreadableCount: unreadable,
            totalCount: pids.count
        )
    }

    // MARK: - libproc

    /// Every PID the kernel will list for us.
    ///
    /// Sized from a first probing call rather than a fixed buffer: a fixed one
    /// silently truncates on a busy machine, and a truncated process list would
    /// quietly drop exactly the heavy processes this feature exists to find.
    private static func listPIDs() -> [pid_t] {
        let probe = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard probe > 0 else { return [] }
        // Head-room: the count can grow between the probe and the real call.
        let capacity = Int(probe) / MemoryLayout<pid_t>.size + 32
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &buffer,
            Int32(capacity * MemoryLayout<pid_t>.size)
        )
        guard written > 0 else { return [] }
        return Array(buffer.prefix(Int(written) / MemoryLayout<pid_t>.size))
    }

    /// `rusage_info_v6` for `pid`, or `nil` when it cannot be read.
    ///
    /// The double rebind is what the C signature demands: `proc_pid_rusage`
    /// takes `rusage_info_t *`, which Swift imports as
    /// `UnsafeMutablePointer<UnsafeMutableRawPointer?>` — a pointer *to* an
    /// opaque pointer — while the kernel actually writes the struct through it.
    private static func usage(of pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        return result == 0 ? info : nil
    }

    /// A display name for `pid`.
    ///
    /// Prefers the executable path's last component over `proc_name`, which the
    /// kernel truncates to 16 bytes — "Mattermost Helpe" and "com.apple.Virtual"
    /// are what that truncation looks like, and the full path avoids it.
    private static func name(of pid: pid_t) -> String {
        // `PROC_PIDPATHINFO_MAXSIZE` is a C macro and does not import into
        // Swift. Its value is `4 * MAXPATHLEN`, and `proc_pidpath` rejects any
        // buffer larger than it.
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let full = Self.string(from: path)
            if let last = full.split(separator: "/").last, !last.isEmpty {
                return String(last)
            }
        }
        var short = [UInt8](repeating: 0, count: 256)
        if proc_name(pid, &short, UInt32(short.count)) > 0 {
            let name = Self.string(from: short)
            if !name.isEmpty {
                return name
            }
        }
        return "pid \(pid)"
    }

    /// Decodes a C string from a byte buffer, stopping at the null terminator.
    ///
    /// `String(cString:)` is deprecated on this SDK and CI compiles with
    /// warnings-as-errors, so the truncation is done by hand.
    private static func string(from buffer: [UInt8]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
