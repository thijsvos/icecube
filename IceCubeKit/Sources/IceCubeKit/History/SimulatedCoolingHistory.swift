// SimulatedCoolingHistory.swift — months of invented cooling records, so simulated mode can demo the trend.

import Foundation

/// Fabricates a plausible cooling history for simulated mode.
///
/// A trend needs weeks and a simulated run has minutes, so an un-seeded
/// launch could only ever demonstrate the "collecting" state — the same
/// reason `seedSimulatedDecisions` exists for the decision timeline. And the
/// live simulated recorder cannot fill in: the mock has no fan→temperature
/// feedback, so its `R` *falls* at higher RPM where real hardware's rises,
/// and a screenshot built from live simulated records would teach the
/// opposite of THERMAL.md. The medians here are taken from that file's
/// measured table instead, so the pictures are physically right.
///
/// Deterministic (the `MockSMCSimulation` house rule): the same story always
/// produces the same records, jittered by the same ±2 % the real hardware
/// showed. Seeds are applied by `CoolingHistoryStore` **only when its file is
/// absent, and only in the simulated graph** — there is no code path by which
/// fabricated readings can reach a real user's file, and the fingerprint's
/// `isSimulated` flag makes one unloadable by a real run even by hand.
public enum SimulatedCoolingHistory {
    /// Which story the seeded history tells. Selected by the
    /// `ICECUBE_SIMULATED_HISTORY` environment variable; every verdict state
    /// is reachable, so every copy string can be seen and screenshot by hand.
    public enum Story: String, CaseIterable, Sendable {
        /// Slow degradation — the state the feature exists for. The default.
        case rising
        /// A healthy machine, unchanged for months.
        case stable
        /// Cooling fell off a cliff in the last day.
        case jump
        /// Better than the baseline — the post-cleaning confirmation.
        case improved
        /// A fresh install, ten days in.
        case baseline
        /// Readings that never overlap in one band: the honest refusal.
        case sparse
    }

    /// The simulated machine's identity: the Mac14,9 the mock models, marked
    /// simulated so this file and a real one can never mix.
    public static let machine = MachineFingerprint(
        modelIdentifier: "Mac14,9",
        fanCount: 2,
        fanMaxRPM: [6800, 6800],
        isSimulated: true,
        serialNumber: nil
    )

    /// The story picked by the environment, defaulting to the interesting one.
    public static func story(fromEnvironment value: String?) -> Story {
        value.flatMap(Story.init(rawValue:)) ?? .rising
    }

    /// ~16 weeks of records ending just before `now` (10 days for
    /// `.baseline`), compacted, ready to hand to the store as a seed.
    public static func seed(_ story: Story, endingAt now: Date) -> CoolingHistory {
        let days = story == .baseline ? 10 : 112
        var history = CoolingHistory(
            machine: machine,
            createdAt: now.addingTimeInterval(-Double(days) * 86400)
        )
        for offset in stride(from: -(days - 1), through: 0, by: 1) {
            for record in dayRecords(story, dayOffset: offset, days: days, now: now) {
                history.append(record, now: record.date)
            }
        }
        if story == .jump {
            // Six readings across the last three hours, ~21 % above the
            // band's normal — enough count and span for the jump verdict.
            for step in 0 ..< 6 {
                let at = now.addingTimeInterval(Double(step) * 1800 - 3 * 3600 - 1800)
                let record = idleRecord(at: at, r: 0.62 * jitter(offset: 900 + step))
                history.append(record, now: at)
            }
        }
        history.compact(now: now)
        return history
    }

    // MARK: - The day-by-day shapes

    private static func dayRecords(
        _ story: Story, dayOffset: Int, days: Int, now: Date
    ) -> [CoolingRecord] {
        // Progress through the story, 0 at the oldest day, 1 today.
        let progress = Double(dayOffset + days - 1) / Double(days - 1)
        let dayStart = now.addingTimeInterval(Double(dayOffset) * 86400)

        var records: [CoolingRecord] = []
        let idleBase: Double = switch story {
        case .rising: 0.51 + 0.09 * progress // +18 % across the window
        case .jump, .stable, .baseline, .sparse: 0.51
        case .improved: progress < 0.7 ? 0.60 : 0.51 // cleaned five weeks ago
        }

        // Two to three idle readings most days; the sparse story keeps the
        // idle band to the early weeks only, so no band spans both epochs.
        let idleDays = story != .sparse || progress < 0.3
        if idleDays {
            let count = 2 + Int(noise(dayOffset, 1) * 2)
            for k in 0 ..< count {
                let hour = 9.0 + Double(k) * 3 + noise(dayOffset, 10 + k) * 0.8
                guard let date = timeIfPast(dayStart, hour: hour, now: now) else { continue }
                records.append(idleRecord(at: date, r: idleBase * jitter(offset: dayOffset * 10 + k)))
            }
        }

        // A loaded stretch roughly every third day (late weeks only, for the
        // sparse story) — the second band, like THERMAL.md's table.
        let loadedDays = story == .sparse ? progress > 0.85 : noise(dayOffset, 2) < 0.35
        if loadedDays {
            let loadedBase: Double = switch story {
            case .rising: 0.90 + 0.16 * progress
            case .jump, .stable, .baseline, .sparse: 0.90
            case .improved: progress < 0.7 ? 1.02 : 0.90
            }
            let hour = 13.0 + noise(dayOffset, 3) * 4
            if let date = timeIfPast(dayStart, hour: hour, now: now) {
                records.append(loadedRecord(at: date, r: loadedBase * jitter(offset: dayOffset * 10 + 7)))
            }
        }
        return records.sorted { $0.date < $1.date }
    }

    // MARK: - Record shapes, from the measured table

    /// Resting: ~2317 RPM (0.34 of maximum, band 3), 19.6 W idle draw.
    private static func idleRecord(at date: Date, r: Double) -> CoolingRecord {
        record(at: date, r: r, watts: 19.6, ambient: 39.5, fraction: 0.34)
    }

    /// Under sustained load: ~6460 RPM (0.95 of maximum, band 9), ~48 W.
    private static func loadedRecord(at date: Date, r: Double) -> CoolingRecord {
        record(at: date, r: r, watts: 48, ambient: 47, fraction: 0.95)
    }

    private static func record(
        at date: Date, r: Double, watts: Double, ambient: Double, fraction: Double
    ) -> CoolingRecord {
        CoolingRecord(
            date: date,
            resistance: r,
            dieCelsius: ambient + r * watts, // consistent by construction
            ambientCelsius: ambient,
            watts: watts,
            band: .band(forFraction: fraction),
            fanFraction: fraction,
            fanRPM: fraction * 6800,
            sampleCount: 21,
            durationSeconds: 20
        )
    }

    // MARK: - Deterministic jitter

    /// ±2 % — the repeatability the real hardware measured.
    private static func jitter(offset: Int) -> Double {
        1 + 0.04 * (noise(offset, 0) - 0.5)
    }

    private static func noise(_ a: Int, _ b: Int) -> Double {
        MockSMCProvider.unitNoise(UInt64(bitPattern: Int64(a)), UInt64(b), 0xC001)
    }

    /// The instant `hour` into the day, unless it falls inside the last two
    /// hours — which covers anything in the future as well.
    ///
    /// The seeded story stops short of `now` rather than right up against it, so
    /// a fabricated reading never lands in the stretch the live recorder is
    /// about to write into. The `.jump` story writes its own records into
    /// `now − 4.5 h … now − 2 h`, which only fits because of that margin.
    private static func timeIfPast(_ dayStart: Date, hour: Double, now: Date) -> Date? {
        let date = dayStart.addingTimeInterval(hour * 3600)
        return date < now.addingTimeInterval(-7200) ? date : nil
    }
}
