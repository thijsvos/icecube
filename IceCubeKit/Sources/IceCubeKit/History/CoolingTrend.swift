// CoolingTrend.swift — turns months of cooling records into one honest verdict, or an honest refusal.

import Foundation

/// The degradation verdict: compares this machine's cooling efficiency with
/// its own past, within one fan-speed band, and refuses whenever the data
/// cannot support a claim.
///
/// Everything here runs on **day-band medians** (see `CoolingDayAggregate`),
/// never raw means — one all-day idle Saturday must not outvote six working
/// weeks, and the settle rule's rare failures all push `R` *up*, which is
/// exactly the direction of the claim this feature most fears getting wrong.
public enum CoolingTrend {
    // MARK: - Constants, and why each has its value

    /// The residual noise budget, ×4. Repeatability at ≥ 21 W is ±2 %
    /// (THERMAL.md's three 5950 RPM rows); within-band fan position
    /// contributes ≤ 1.4 % after the drift gate; in quadrature ≈ 2.4 %. Ten
    /// percent is ~4× that — and it is also the smallest change with a
    /// physical action attached: at the measured fan sensitivity, 10 % of
    /// `R` is roughly what ~800 RPM buys, which a user can hear and choose.
    public static let slowRiseThreshold = 0.10
    /// Symmetric with ``slowRiseThreshold``: the same noise bounds both
    /// directions, a feature that can only say "worse" reads as
    /// scaremongering, and a user who just cleaned their vents deserves the
    /// confirmation.
    public static let improvedThreshold = 0.10
    /// Louder claim, higher bar, less averaging behind it: 15 % is about as
    /// much as changing the fans by two-thirds of their range — without the
    /// fans having changed.
    public static let suddenJumpThreshold = 0.15

    /// Dust does not change in a day. Two weeks gathers ≥ 5 day-medians on
    /// a machine used five days a week while "recent" still means recent.
    public static let recentSpanDays = 14
    /// Same width as recent, so the two medians rest on the same amount of
    /// evidence and a difference cannot come from asymmetric averaging.
    public static let baselineSpanDays = 14
    /// Must exceed ``recentSpanDays`` so the epochs cannot share a day, with
    /// margin — and it is how a person thinks: "a month ago". With
    /// ``baselineSpanDays`` it puts the first possible verdict at day 44.
    public static let minimumSeparationDays = 30
    /// "Worse than in August" is a ~1-year claim. Beyond that the
    /// confounders — an OS fan-policy change, a new display on the power
    /// denominator, a different room — are no longer the same experiment.
    public static let maxBaselineAgeDays = 365
    /// A median of 5 tolerates 2 outliers — a weekend, a heatwave, a
    /// two-day render. A median of 3 tolerates 1.
    public static let minEpochDays = 5
    /// Guards the degenerate "five days with one reading each".
    public static let minEpochReadings = 10
    /// A band is 0.10 wide and admits ~4.6 % of `R` edge-to-edge; a baseline
    /// at the low edge against a recent at the high edge would fake a 4.6 %
    /// *improvement*. Requiring the epochs' median fan fraction to agree
    /// within 0.03 caps that contamination at ~1.4 %.
    public static let maxWithinBandFanDrift = 0.03

    /// "Right now", at the resolution a 5-minute recorder can offer.
    public static let jumpWindow: TimeInterval = 86400
    /// ≥ 20 minutes of settled machine.
    public static let minJumpReadings = 5
    /// Five records could all come from one 25-minute sitting; an hour means
    /// a single brief anomaly cannot fire the loudest verdict. Consequence,
    /// out loud: the jump verdict lags the event by at least an hour. That
    /// is the correct trade — the seconds-scale stopped-fan case belongs to
    /// `ThermalDiagnosis.Cooling.stalled`, not here.
    public static let minJumpSpan: TimeInterval = 3600
    /// The band's own recent normal.
    public static let jumpReferenceDays = 14
    /// Below a week of day-medians, "normal" is not established and a jump
    /// would be measured against noise.
    public static let minJumpReferenceDays = 7

    // MARK: - The verdict

    /// One comparison's evidence, carried whole so the copy layer can name
    /// its numbers. `stable` carries it too: with a 10 % threshold a real
    /// 9 % drift reports stable, and the copy decides between "unchanged"
    /// and "slightly higher, not enough to call".
    public struct Comparison: Sendable, Equatable {
        public let band: FanBand
        /// Positive means `R` **rose**, which means cooling got **worse**.
        /// The sign is pinned by tests in both directions.
        public let resistanceChangeFraction: Double
        public let recentMedian: Double
        public let baselineMedian: Double
        /// The baseline's median day — "since 12 June".
        public let since: Date
        public let recentReadings: Int
        public let baselineReadings: Int
    }

    /// Why a comparison could not be made, for copy that names what is
    /// missing rather than shrugging.
    public enum Gap: Sendable, Equatable {
        /// No single fan-speed band has both a recent and a baseline epoch.
        /// Cross-band comparison is what the physics forbids, so this is a
        /// refusal, not a fallback.
        case noBandHasBothEpochs
        /// Fewer settled days in the recent window than a comparison needs;
        /// carries both counts so the copy can say how far off it is.
        case tooFewRecentDays(have: Int, need: Int)
        /// Fewer settled days in the baseline window than a comparison needs;
        /// same shape as the recent case.
        case tooFewBaselineDays(have: Int, need: Int)
        /// The two epochs' median fan fractions differ by more than
        /// ``maxWithinBandFanDrift``, so a band-edge artefact could fake a ~4.6 %
        /// improvement. Carries both medians.
        case fanSpeedDrifted(recent: Double, baseline: Double)
    }

    /// What months of settled readings say about this Mac's cooling.
    ///
    /// Ordered from "cannot say" to "say it loudly", and the first three cases are
    /// all refusals: this type would rather name what is missing than produce a
    /// verdict from evidence that does not support one.
    ///
    /// Every non-refusal carries its ``Comparison`` whole, `stable` included — with
    /// a 10 % threshold a real 9 % drift reports stable, and the copy layer needs
    /// the numbers to choose between "unchanged" and "slightly higher, not enough
    /// to call".
    public enum Verdict: Sendable, Equatable {
        /// Nothing has ever been recorded. Distinct from collecting: this
        /// Mac may have no power key or no airflow sensor, and the copy
        /// layer says which from the live snapshot.
        case noHistory
        /// Not enough *elapsed time* for a baseline to exist. Purely
        /// temporal — no amount of data can shorten it.
        case collectingBaseline(since: Date, readyAfter: Date)
        /// Time has passed; the readings do not support a comparison.
        case insufficientComparableReadings(reason: Gap, band: FanBand?)
        case stable(Comparison)
        /// A gradual rise: dust in the vents is the usual cause, dried
        /// paste the next.
        case slowRise(Comparison)
        /// A gradual fall — the post-cleaning case.
        case improved(Comparison)
        /// The last day sits far above this band's own recent history at
        /// the same fan speed.
        case suddenJump(band: FanBand, change: Double, referenceDays: Int, readings: Int)
    }

    // MARK: - Evaluation

    /// One comparable day-median series per band — the exact data the
    /// verdict judges, public so the history chart draws what was judged and
    /// the two can never disagree. Stored aggregates serve the days before
    /// the oldest surviving raw record; raw is folded on the fly at and
    /// after it. Never both for one day.
    public static func seriesByBand(
        _ history: CoolingHistory, now: Date
    ) -> [FanBand: [CoolingDayAggregate]] {
        let today = CoolingStatistics.dayIndex(now)
        let records = history.records
            .filter { $0.date <= now + CoolingHistory.maximumFutureSkew }
            .sorted { $0.date < $1.date }

        let rawCutoffDay = records.first?.day ?? Int.max
        var series: [FanBand: [CoolingDayAggregate]] = [:]
        for aggregate in history.days where aggregate.day < rawCutoffDay && aggregate.day <= today {
            series[aggregate.band, default: []].append(aggregate)
        }
        for aggregate in CoolingDayAggregate.fold(records) where aggregate.day <= today {
            series[aggregate.band, default: []].append(aggregate)
        }
        for band in series.keys {
            series[band]?.sort { $0.day < $1.day }
        }
        return series
    }

    /// The verdict for a history at an instant. Pure: same inputs, same
    /// verdict — deliberately independent of when `compact` last ran, which
    /// is what keeps a quit-and-relaunch from changing the answer.
    public static func evaluate(_ history: CoolingHistory, now: Date) -> Verdict {
        let today = CoolingStatistics.dayIndex(now)
        let records = history.records
            .filter { $0.date <= now + CoolingHistory.maximumFutureSkew }
            .sorted { $0.date < $1.date }

        let series = seriesByBand(history, now: now)
        guard !series.isEmpty else { return .noHistory }

        // Bands by evidence, most first; sortKey breaks ties deterministically.
        let orderedBands = series.keys.sorted {
            (series[$0]?.count ?? 0, $1.sortKey) > (series[$1]?.count ?? 0, $0.sortKey)
        }

        // 1. Sudden jump, checked FIRST — deliberately ahead of
        // collectingBaseline: "R rose 18 % yesterday" is actionable on day
        // 15, and withholding it because the seasonal baseline is not ready
        // would suppress the urgent finding for the sake of the slow one.
        for band in orderedBands {
            let recent = records.filter { $0.band == band && $0.date > now - jumpWindow }
            guard recent.count >= minJumpReadings,
                  let first = recent.first, let last = recent.last,
                  last.date.timeIntervalSince(first.date) >= minJumpSpan,
                  let recentMedian = CoolingStatistics.median(recent.map(\.resistance))
            else { continue }
            let reference = (series[band] ?? [])
                .filter { $0.day >= today - jumpReferenceDays && $0.day <= today - 1 }
            guard reference.count >= minJumpReferenceDays,
                  let referenceMedian = CoolingStatistics.median(reference.map(\.median))
            else { continue }
            let change = recentMedian / referenceMedian - 1
            if change >= suddenJumpThreshold {
                return .suddenJump(
                    band: band, change: change,
                    referenceDays: reference.count, readings: recent.count
                )
            }
        }

        // 2. Not enough elapsed time yet.
        let earliestDay = series.values.compactMap { $0.first?.day }.min() ?? today
        let readyDay = earliestDay + minimumSeparationDays + baselineSpanDays
        if today < readyDay {
            return .collectingBaseline(
                since: CoolingStatistics.dayDate(earliestDay),
                readyAfter: CoolingStatistics.dayDate(readyDay)
            )
        }

        // 3. Epoch comparison, band by band, most-populated first.
        let latestMarkDay = history.serviceMarks.filter { $0 <= now }.max()
            .map { CoolingStatistics.dayIndex($0) }
        var firstGap: Gap?
        for band in orderedBands {
            guard let bandSeries = series[band] else { continue }

            let recent = bandSeries.filter { $0.day > today - recentSpanDays }
            let recentReadings = recent.map(\.count).reduce(0, +)
            guard recent.count >= minEpochDays, recentReadings >= minEpochReadings else {
                firstGap = firstGap ?? .tooFewRecentDays(have: recent.count, need: minEpochDays)
                continue
            }

            // The baseline is the EARLIEST qualifying window: the longest
            // honest lever arm, and the one that can say "since June".
            // Scanned oldest-first so the rule is a single pre-specified
            // choice, not a search for a result. It never spans a service
            // mark and never reaches past `maxBaselineAgeDays`.
            let oldestStart = max(
                bandSeries.first?.day ?? today,
                today - maxBaselineAgeDays,
                latestMarkDay.map { $0 + 1 } ?? Int.min
            )
            let latestStart = today - minimumSeparationDays - baselineSpanDays
            var baseline: [CoolingDayAggregate]?
            var bestDaysFound = 0
            if oldestStart <= latestStart {
                for start in oldestStart ... latestStart {
                    let window = bandSeries.filter {
                        $0.day >= start && $0.day < start + baselineSpanDays
                    }
                    bestDaysFound = max(bestDaysFound, window.count)
                    if window.count >= minEpochDays,
                       window.map(\.count).reduce(0, +) >= minEpochReadings
                    {
                        baseline = window
                        break
                    }
                }
            }
            guard let baseline else {
                firstGap = firstGap
                    ?? .tooFewBaselineDays(have: bestDaysFound, need: minEpochDays)
                continue
            }

            // Same band is not the same fan speed; guard the residual.
            if band != .fanless,
               let recentFraction = CoolingStatistics.median(recent.map(\.medianFanFraction)),
               let baselineFraction = CoolingStatistics.median(baseline.map(\.medianFanFraction)),
               abs(recentFraction - baselineFraction) > maxWithinBandFanDrift
            {
                firstGap = firstGap
                    ?? .fanSpeedDrifted(recent: recentFraction, baseline: baselineFraction)
                continue
            }

            guard let recentMedian = CoolingStatistics.median(recent.map(\.median)),
                  let baselineMedian = CoolingStatistics.median(baseline.map(\.median)),
                  baselineMedian > 0
            else { continue }
            let change = recentMedian / baselineMedian - 1
            let sinceDay = CoolingStatistics.median(baseline.map { Double($0.day) })
                .map { Int($0.rounded()) } ?? earliestDay
            let comparison = Comparison(
                band: band,
                resistanceChangeFraction: change,
                recentMedian: recentMedian,
                baselineMedian: baselineMedian,
                since: CoolingStatistics.dayDate(sinceDay),
                recentReadings: recentReadings,
                baselineReadings: baseline.map(\.count).reduce(0, +)
            )
            if change >= slowRiseThreshold {
                return .slowRise(comparison)
            }
            if change <= -improvedThreshold {
                return .improved(comparison)
            }
            return .stable(comparison)
        }

        // 4. Time passed; the readings do not support a comparison.
        return .insufficientComparableReadings(
            reason: firstGap ?? .noBandHasBothEpochs,
            band: orderedBands.first
        )
    }
}
