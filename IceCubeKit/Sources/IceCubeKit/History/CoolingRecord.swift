// CoolingRecord.swift — one settled cooling reading kept on disk, and the day-band aggregates it folds into.

import Foundation

/// One settled cooling-efficiency reading, kept.
///
/// Carries `R` **and** the die/ambient/watts means it was computed from, on
/// purpose. Storing only `R` would make history unrecomputable: if the
/// ambient reference ever changes (today it is the *coolest* airflow sensor,
/// a documented judgement call), every old `R` silently means something
/// different from every new one, with no way to tell. The raw means also
/// keep the two biggest confounders *visible* — an ambient that rose 8 °C
/// between epochs is a room, not a machine, and without `ambientCelsius` in
/// the record nobody could ever check.
///
/// There is deliberately no fan-mode field: `R` does not care who commanded
/// the RPM — `.forced`, `.system` and the guardian all produce real airflow.
public struct CoolingRecord: Sendable, Codable, Equatable {
    public let date: Date
    /// °C/W over the settled window's means.
    public let resistance: Double
    public let dieCelsius: Double
    public let ambientCelsius: Double
    public let watts: Double
    /// The fan-speed regime this reading belongs to. Comparisons never cross it.
    public let band: FanBand
    /// Mean `actualRPM / maxRPM` across usable fans at the time.
    public let fanFraction: Double
    /// Mean actual RPM — the unit THERMAL.md's tables and the user's ears
    /// speak in; not reconstructible from the fraction alone.
    public let fanRPM: Double
    /// Samples in the settled window. Evidence quality, not decoration.
    public let sampleCount: Int
    /// Wall-clock span of the settled window, seconds.
    public let durationSeconds: Double

    /// Rounds every field on the way in, so the file and memory agree.
    ///
    /// Sixteen significant digits of a quantity whose noise floor is 2 % is
    /// not precision, it is file size: `R` keeps 3 decimals, temperatures and
    /// watts 1, the fraction 3, RPM and dates whole numbers. One-second date
    /// resolution on a record producible at most once per five minutes is
    /// already absurd headroom.
    public init(
        date: Date,
        resistance: Double,
        dieCelsius: Double,
        ambientCelsius: Double,
        watts: Double,
        band: FanBand,
        fanFraction: Double,
        fanRPM: Double,
        sampleCount: Int,
        durationSeconds: Double
    ) {
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded())
        self.resistance = (resistance * 1000).rounded() / 1000
        self.dieCelsius = (dieCelsius * 10).rounded() / 10
        self.ambientCelsius = (ambientCelsius * 10).rounded() / 10
        self.watts = (watts * 10).rounded() / 10
        self.band = band
        self.fanFraction = (fanFraction * 1000).rounded() / 1000
        self.fanRPM = fanRPM.rounded()
        self.sampleCount = sampleCount
        self.durationSeconds = durationSeconds.rounded()
    }

    /// The UTC day bucket this record folds into.
    public var day: Int {
        CoolingStatistics.dayIndex(date)
    }
}

/// One day of one band, folded: the long-term unit the trend runs on.
///
/// The day is the statistical unit because raw readings would let usage
/// pattern outvote hardware: an all-day idle Saturday can produce 288
/// records while six working weeks produce fewer. Median within a day-band,
/// then median of day-medians across an epoch, bounds any one day's
/// influence to one vote.
///
/// `p25`/`p75` are stored because once the raw is pruned, the difference
/// between "five tight readings" and "five scattered 30 %" is unrecoverable
/// forever — and that is exactly the distinction a disputed verdict turns on.
public struct CoolingDayAggregate: Sendable, Codable, Equatable {
    /// UTC days since 1970 (`CoolingStatistics.dayIndex`).
    public let day: Int
    public let band: FanBand
    /// Median `R` of the day's records in this band.
    public let median: Double
    public let p25: Double
    public let p75: Double
    /// How many records folded in — an epoch's evidence count.
    public let count: Int
    public let medianFanFraction: Double
    public let medianWatts: Double

    public init(
        day: Int, band: FanBand, median: Double, p25: Double, p75: Double,
        count: Int, medianFanFraction: Double, medianWatts: Double
    ) {
        self.day = day
        self.band = band
        self.median = (median * 1000).rounded() / 1000
        self.p25 = (p25 * 1000).rounded() / 1000
        self.p75 = (p75 * 1000).rounded() / 1000
        self.count = count
        self.medianFanFraction = (medianFanFraction * 1000).rounded() / 1000
        self.medianWatts = (medianWatts * 10).rounded() / 10
    }

    /// Folds records into day-band aggregates, sorted by (day, band).
    ///
    /// Pure and idempotent: the same records always fold to the same
    /// aggregates, which is what lets the trend fold raw on the fly and get
    /// byte-identical answers to a stored fold.
    public static func fold(_ records: [CoolingRecord]) -> [CoolingDayAggregate] {
        let groups = Dictionary(grouping: records) { Key(day: $0.day, band: $0.band) }
        return groups.map { key, members in
            let rs = members.map(\.resistance)
            return CoolingDayAggregate(
                day: key.day,
                band: key.band,
                median: CoolingStatistics.median(rs) ?? 0,
                p25: CoolingStatistics.percentile(rs, 25) ?? 0,
                p75: CoolingStatistics.percentile(rs, 75) ?? 0,
                count: members.count,
                medianFanFraction: CoolingStatistics.median(members.map(\.fanFraction)) ?? 0,
                medianWatts: CoolingStatistics.median(members.map(\.watts)) ?? 0
            )
        }
        .sorted { ($0.day, $0.band.sortKey) < ($1.day, $1.band.sortKey) }
    }

    private struct Key: Hashable {
        let day: Int
        let band: FanBand
    }
}
