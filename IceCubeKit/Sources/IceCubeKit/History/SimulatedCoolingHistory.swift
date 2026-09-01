// SimulatedCoolingHistory.swift — months of invented cooling records, so simulated mode can demo the trend.

import Foundation

/// Fabricates a plausible cooling history for simulated mode.
///
/// A trend needs weeks and a simulated run has minutes, so an un-seeded
/// launch could only ever demonstrate the "collecting" state — the same
/// reason `seedSimulatedDecisions` exists for the decision timeline. That
/// reason is unchanged and is why this file still exists.
///
/// CORRECTION (2026-09-01): the paragraph here used to give a *second*
/// reason — that the live simulated recorder could not fill in because "the
/// mock has no fan→temperature feedback". That is no longer true, and its
/// arithmetic was backwards even when it was. The old model had `R` **rise**
/// with fan speed (0.38 °C/W at rest, 0.89 at maximum, because temperature
/// and power both read the workload envelope and the fans only followed),
/// where real hardware's `R` **falls** — THERMAL.md measures 1.04–1.13 at
/// 3550 RPM against 0.89–0.93 at 5950. The sentence named the right defect
/// and swapped which side had which sign.
///
/// `MockSMCSimulation` now integrates a genuine closed loop, so its `R` falls
/// with fan speed like the hardware's. Only the clock stands between this
/// file and a recorder that fills its own history — see
/// ``MockSMCProvider/equilibriumRise(watts:fanFraction:)``.
///
/// The medians below are still taken from THERMAL.md's measured table rather
/// than from the model, so the pictures stay anchored to hardware.
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
                let record = idleRecord(
                    at: at, degradation: 1.21 * jitter(offset: 900 + step), offset: 900 + step
                )
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
        // How much worse than healthy this day's cooling is. One multiplier for
        // the whole machine, so every band degrades together — which is what
        // dust actually does, and what keeps the bands comparable while it
        // happens.
        let degradation: Double = switch story {
        case .rising: 1 + 0.18 * progress // +18 % across the window
        case .jump, .stable, .baseline, .sparse: 1
        case .improved: progress < 0.7 ? 1.18 : 1 // cleaned five weeks ago
        }

        // Four to six idle readings most days; the sparse story keeps the
        // idle band to the early weeks only, so no band spans both epochs.
        //
        // The count was two to three until 2026-09-01. That is plenty for the
        // trend, which runs on day medians, but `CoolingLaw` fits a line
        // through *raw* records and those are kept for only
        // `CoolingHistory.rawRetentionDays` — so a week held 17 idle readings
        // and 2 loaded ones, and the loaded band could never reach
        // `CoolingLaw.minimumRecordsPerBand`. A real machine records up to 288
        // a day; this was never meant to model that sparsity, it just was not
        // asked to be denser.
        let idleDays = story != .sparse || progress < 0.3
        if idleDays {
            let count = 4 + Int(noise(dayOffset, 1) * 3)
            for k in 0 ..< count {
                let hour = 8.0 + Double(k) * 2 + noise(dayOffset, 10 + k) * 0.8
                guard let date = timeIfPast(dayStart, hour: hour, now: now) else { continue }
                records.append(idleRecord(
                    at: date,
                    degradation: degradation * jitter(offset: dayOffset * 10 + k),
                    offset: dayOffset * 10 + k
                ))
            }
        }

        // The same middling workload under two different presets, roughly
        // every other day — the pair that makes a *comparison* possible.
        //
        // Without it the seeded history has an idle band measured at 14–25 W
        // and a loaded band at 34–62 W, which share no load at all. Asked what
        // the fans would buy at 48 W, neither band can answer honestly: the
        // idle line would have to be extrapolated 2.3x past its data, and doing
        // so said the *slower* fans were 18.9 °C cooler. `CoolingLaw.Band.covers`
        // now refuses that, correctly — and the counterfactual then had nothing
        // to say in simulated mode at all.
        //
        // A real machine produces these constantly: the same build run under
        // Quiet and under Cold is the same watts at two fan speeds, which is
        // exactly the measurement the noise-value curve is made of. The seed
        // was simply missing the shape.
        if story != .sparse, noise(dayOffset, 7) < 0.5 {
            for k in 0 ..< 5 {
                let hour = 18.0 + Double(k) * 0.4
                guard let date = timeIfPast(dayStart, hour: hour, now: now) else { continue }
                records.append(record(
                    at: date,
                    degradation: degradation * jitter(offset: dayOffset * 10 + 30 + k),
                    watts: watts(around: 35, offset: dayOffset * 10 + 30 + k),
                    ambient: 44,
                    fraction: 0.55
                ))
                records.append(record(
                    at: date.addingTimeInterval(120),
                    degradation: degradation * jitter(offset: dayOffset * 10 + 40 + k),
                    watts: watts(around: 35, offset: dayOffset * 10 + 40 + k),
                    ambient: 46,
                    fraction: 0.85
                ))
            }
        }

        // A loaded stretch roughly every third day (late weeks only, for the
        // sparse story) — the second band, like THERMAL.md's table.
        let loadedDays = story == .sparse ? progress > 0.85 : noise(dayOffset, 2) < 0.35
        if loadedDays {
            // A sustained work session, not a single instant: the recorder
            // writes one settled reading every five minutes for as long as the
            // machine holds still, so a loaded afternoon produces a cluster.
            // Six to ten — half an hour to fifty minutes of steady work — is
            // what it takes for the loaded band to clear
            // `CoolingLaw.minimumRecordsPerBand` inside the seven days of raw
            // records that survive `CoolingHistory.compact`.
            let count = 6 + Int(noise(dayOffset, 6) * 5)
            for k in 0 ..< count {
                let hour = 13.0 + Double(k) * 0.5 + noise(dayOffset, 20 + k) * 0.3
                guard let date = timeIfPast(dayStart, hour: hour, now: now) else { continue }
                records.append(loadedRecord(
                    at: date,
                    degradation: degradation * jitter(offset: dayOffset * 10 + 7 + k),
                    offset: dayOffset * 10 + 7 + k
                ))
            }
        }
        return records.sorted { $0.date < $1.date }
    }

    // MARK: - The law the records are generated from

    /// Die rise above airflow at rest, °C — the gap that exists before any
    /// marginal watt is spent. From the mock's own sensor bases (47 °C die,
    /// 39.5 °C airflow).
    private static let restingRise = 7.5

    /// System watts that never reach the die. Matches
    /// ``MockSMCProvider/freeWatts``.
    private static let freeWatts = 18.0

    /// Die rise per marginal watt at a given fan fraction.
    ///
    /// **Why the seed generates records from one law instead of stamping each
    /// band with a fixed `R`.** It used to do the latter: band 3 carried 0.51
    /// °C/W and band 9 carried 0.90, both real numbers straight out of
    /// `docs/THERMAL.md`. That is fine for the trend, which only ever compares
    /// a band with its own past.
    ///
    /// It is not fine for `CoolingLaw`, which compares bands *with each other
    /// at one load*. Those two figures were measured in different physical
    /// situations — 0.51 at idle, 0.90 under sustained load — and `R` genuinely
    /// varies with load, which is the finding that made `CoolingLaw` fit a line
    /// in the first place. Fitting origin-through lines to them and asking which
    /// band is cooler at 20 W said **band 3**, the near-stopped fans. Backwards,
    /// and it would have been a screenshot.
    ///
    /// Coefficients solved so the law reproduces both anchors exactly: 0.51
    /// °C/W at 19.6 W in band 3, and 0.90 °C/W at 48 W in band 9. Everything
    /// between is interpolation along one surface, so more fan is cooler at
    /// every load — which is the thing a picture of this must not get wrong.
    private static func slope(atFraction fraction: Double) -> Double {
        1.766 - 0.607 * fraction
    }

    /// Die rise above airflow for a given draw and fan fraction, °C.
    private static func rise(watts: Double, fraction: Double, degradation: Double) -> Double {
        (restingRise + slope(atFraction: fraction) * max(0, watts - freeWatts)) * degradation
    }

    // MARK: - Record shapes, from the measured table

    /// How widely the draw varies within one band, as a fraction of its mean.
    ///
    /// A real machine does not sit at one wattage whenever its fans are in a
    /// given decile — it wanders, and the wandering is what makes the band's
    /// `(watts, rise)` pairs describe a *line* rather than a point. Seeded
    /// records used to be a single wattage per band (19.6 and 48 exactly),
    /// which is enough for a median but not for anything that has to separate
    /// a slope from an offset.
    ///
    /// ±30 % of the mean, so a band spans a 60 % range — comfortably identifying
    /// for a two-parameter fit, and still a narrower spread than the
    /// 12 %-to-6× range THERMAL.md's own readings cover.
    private static let wattsSpread = 0.30

    /// Deterministic draw for one record: the band's mean, spread by
    /// ``wattsSpread``. Varies **watts only** — the fan fraction stays put, so
    /// the record cannot drift into a neighbouring band and cannot move the
    /// epoch fan medians `CoolingTrend.maxWithinBandFanDrift` polices.
    private static func watts(around mean: Double, offset: Int) -> Double {
        mean * (1 + wattsSpread * 2 * (noise(offset, 5) - 0.5))
    }

    /// Resting: ~2317 RPM (0.34 of maximum, band 3), around the 19.6 W idle draw.
    private static func idleRecord(at date: Date, degradation: Double, offset: Int) -> CoolingRecord {
        record(
            at: date, degradation: degradation,
            watts: watts(around: 19.6, offset: offset), ambient: 39.5, fraction: 0.34
        )
    }

    /// Under sustained load: ~6460 RPM (0.95 of maximum, band 9), around 48 W.
    private static func loadedRecord(at date: Date, degradation: Double, offset: Int) -> CoolingRecord {
        record(
            at: date, degradation: degradation,
            watts: watts(around: 48, offset: offset), ambient: 47, fraction: 0.95
        )
    }

    /// One record on the law, with `degradation` carrying whatever the story is
    /// telling (1.0 = healthy; 1.18 = eighteen percent worse at heat transfer).
    ///
    /// `resistance` is *derived* from the rise rather than chosen, so the file
    /// stays self-consistent: `R = ΔT / W` by definition, and a reader who
    /// recomputes it from the die and airflow columns gets the stored value
    /// back.
    private static func record(
        at date: Date, degradation: Double, watts: Double, ambient: Double, fraction: Double
    ) -> CoolingRecord {
        let delta = rise(watts: watts, fraction: fraction, degradation: degradation)
        return CoolingRecord(
            date: date,
            resistance: delta / watts,
            dieCelsius: ambient + delta,
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
