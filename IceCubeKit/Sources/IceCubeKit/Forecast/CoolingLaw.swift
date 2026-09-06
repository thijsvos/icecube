// CoolingLaw.swift — what each fan speed buys on this Mac, fitted from its own recorded history.

import Foundation

/// How far the die rises above the airflow reference, as a function of the
/// work being done, fitted separately for each fan-speed band.
///
/// ```
/// ΔT = slope · watts + intercept
/// ```
///
/// This is the "noise-value curve" `docs/THERMAL.md` closes on — *"how much
/// cooling a given fan speed buys on your Mac"* — which that file notes is
/// now a matter of drawing rather than measuring, since every stored record
/// already carries the fan speed it was taken at.
///
/// ## Why a line and not a ratio
///
/// The obvious form is `ΔT = R · watts`, reusing the `R` the app already
/// records. It does not survive contact with the project's own measurements:
///
/// | Reading | Source | P (W) | ΔT (°C) | R |
/// | --- | --- | --- | --- | --- |
/// | Idle | `CoolingEfficiencyTests` | 19.6 | 10.0 | **0.51** |
/// | 3550 RPM | `THERMAL.md` fan table | 9.0 | 8.4 | **0.93** |
/// | 5950 RPM | `THERMAL.md` load table | 24.0 | 19.9 | **0.83** |
/// | Loaded | seeded from that table | 48.0 | 43.2 | **0.90** |
///
/// An **1.8× spread**, and fan speed does not explain it — the *lowest* `R`
/// sits at the *lowest* fan speed, which is backwards from the measured fan
/// dependence. THERMAL.md's load-invariance claim (±2 %) was established
/// across a 12 % power spread at one fan speed, far too narrow to see this.
///
/// The cause is named in that file already: the denominator is **system**
/// power, and some of it never crosses the heatsink — display, SSD, charging
/// losses. That share is largest at idle, which is exactly where `R` collapses.
/// A single ratio has nowhere to put it. A line does: ``Band/intercept``
/// absorbs the offset and ``Band/slope`` carries the cooling.
///
/// ## What it refuses
///
/// A slope and an intercept cannot be separated from readings that all sit at
/// one wattage — the fit would run, report a number, and be describing
/// nothing. So a band is only reported when its records span a real range of
/// load, and when the line it produces actually describes them. **On a fresh
/// install this answers nothing at all**, and that is the feature working.
public struct CoolingLaw: Sendable, Equatable {
    // MARK: - Constants, and why each has its value

    /// Records a band needs before it is fitted.
    ///
    /// Twelve is small for a regression, and deliberately so: this is a
    /// two-parameter fit on a quantity whose noise THERMAL.md measured at
    /// ±2 %, guarded by a residual test that catches a bad fit directly.
    /// Requiring more would mostly delay the answer on machines that only run
    /// hard occasionally, which are the ones a forecast helps most.
    public static let minimumRecordsPerBand = 12

    /// How widely the draw must range within a band, as a fraction of its mean.
    ///
    /// **The gate that makes the fit mean anything.** Least squares will
    /// happily fit a line to points stacked at one wattage; slope and
    /// intercept become perfectly anti-correlated and the answer is noise
    /// wearing a number. Thirty percent is a spread wide enough that the
    /// slope is set by the data rather than by the two extreme points, and
    /// narrow enough that an ordinary week of mixed use clears it.
    public static let minimumPowerSpreadFraction = 0.30

    /// Largest residual standard error a fit may have and still be reported, °C.
    ///
    /// The line has to describe the readings, not merely pass among them. Three
    /// degrees is about twice the ±1.5 °C wobble
    /// ``CoolingEfficiency/temperatureToleranceCelsius`` already tolerates
    /// inside a settled window, so a band whose points scatter further than
    /// that is not one line — it is two operating regimes filed together.
    public static let maximumResidualCelsius: Double = 3

    // MARK: - One band's law

    /// The fitted line for a single fan-speed band.
    public struct Band: Sendable, Equatable {
        /// °C of die rise per marginal watt. Always positive — a fit that came
        /// out flat or negative is refused rather than stored.
        public let slope: Double
        /// °C of rise at zero watts. Ordinarily **negative**: it absorbs the
        /// system power that never reaches the die, so the line crosses zero
        /// rise at a real, positive draw.
        public let intercept: Double
        /// Residual standard error, °C. Kept rather than discarded — a caller
        /// showing a forecast should be able to say how well the line fits.
        public let residual: Double
        /// How many records the fit rests on.
        public let records: Int
        /// The range of draw the fit was built from, watts. Outside it the line
        /// is extrapolation.
        public let wattsRange: ClosedRange<Double>
        /// The fan speed this band's readings were actually taken at, as a
        /// fraction of maximum — the median of their `fanFraction`.
        ///
        /// A band is a decile, so its midpoint is free and is what a caller
        /// reaches for otherwise. It is a guess. Records do not spread evenly
        /// inside a decile: a Mac that idles at its 2317 RPM floor spends the
        /// whole of band 0 pinned against the bottom edge, and the midpoint
        /// names a fan speed it never runs at. The median names one it did.
        ///
        /// The line fit does not need this. ``CurveDerivation`` does: it turns
        /// a band back into a curve point, and a curve point is a fan speed.
        public let medianFanFraction: Double

        /// Predicted die rise above airflow at a given draw, never negative.
        ///
        /// Clamped at zero because the line is only fitted where readings
        /// exist: below the intercept's crossing it would predict a die
        /// *colder* than the air moving past it, which is not a thing.
        ///
        /// **Says nothing about whether the draw is one this band was measured
        /// at.** Ask ``covers(watts:)`` first — see the note on that method for
        /// what happens when nobody does.
        public func rise(atWatts watts: Double) -> Double {
            max(0, slope * watts + intercept)
        }

        /// Whether this band was measured at anything like this draw.
        ///
        /// **The bug this exists for.** `wattsRange` was recorded from the
        /// start, described as the range "outside which the line is
        /// extrapolation, and callers are expected to care" — and then no
        /// caller cared. Both `CoolingLaw.coolestBand(atWatts:)` and the
        /// forecast's fixed-point search evaluated every band's line at the
        /// current draw regardless of what that band had ever seen.
        ///
        /// Caught in simulated mode, where the seeded history holds an idle
        /// band recorded at 14–25 W and a loaded band at 34–62 W. Asked what
        /// the fans would buy at 48 W, the idle band's line — extrapolated
        /// 2.3× past its data — came out 18.9 °C *cooler* than the loaded one,
        /// and the app was one merge away from telling someone to **slow their
        /// fans down to cool the machine**.
        ///
        /// The margin is deliberate but small. A line is still roughly itself
        /// just outside the readings that produced it; 20 % beyond either end
        /// is a working tolerance, and 130 % beyond is a different regime.
        public func covers(watts: Double) -> Bool {
            let margin = (wattsRange.upperBound - wattsRange.lowerBound) * Self.extrapolationMargin
            return watts >= wattsRange.lowerBound - margin
                && watts <= wattsRange.upperBound + margin
        }

        /// How far past a band's measured range its line may still be trusted,
        /// as a fraction of that range.
        public static let extrapolationMargin = 0.20
    }

    /// The fitted bands, keyed by fan-speed band. Absent means not measurable.
    public private(set) var bands: [FanBand: Band]

    /// Bands that produced a fit, in fan-speed order — slowest fans first.
    ///
    /// Sorted by ``FanBand/sortKey``, not by temperature: this is a stable
    /// iteration order for the fixed-point search, not a ranking. For "which
    /// band runs coolest", ask ``coolestBand(atWatts:)``, which needs a draw.
    public var measuredBands: [FanBand] {
        bands.keys.sorted { $0.sortKey < $1.sortKey }
    }

    public init(bands: [FanBand: Band] = [:]) {
        self.bands = bands
    }

    /// The law for one band, or `nil` if this machine has never been measured
    /// there well enough to say.
    ///
    /// **Deliberately no interpolation and no extrapolation between bands.**
    /// Fitting a line through two deciles and quoting it at a third would
    /// manufacture exactly the confident-and-wrong number this design exists
    /// to avoid, and it is the rule ``CoolingTrend`` already enforces for the
    /// same reason: within-band comparison only, ever.
    public func band(_ band: FanBand) -> Band? {
        bands[band]
    }

    /// The measured band that would run coolest at this draw.
    ///
    /// Takes a wattage rather than answering in the abstract, because it
    /// genuinely depends on one: bands differ in both slope and intercept, so
    /// which is coolest can change with load. Answering without being told the
    /// load would be picking one silently.
    ///
    /// Only bands that were actually measured near this draw are considered —
    /// see ``Band/covers(watts:)`` for the backwards advice that came out when
    /// they were not.
    public func coolestBand(atWatts watts: Double) -> (band: FanBand, law: Band)? {
        bands
            .filter { $0.value.covers(watts: watts) }
            .min { $0.value.rise(atWatts: watts) < $1.value.rise(atWatts: watts) }
            .map { ($0.key, $0.value) }
    }

    // MARK: - Fitting

    /// Fits every band that has enough evidence.
    ///
    /// Runs on **raw records**, not the day aggregates ``CoolingTrend`` uses.
    /// The two answer different questions. The trend compares epochs, so it
    /// needs a statistical unit that stops one idle Saturday outvoting six
    /// working weeks. This describes the machine *as it is now*, so more points
    /// across a wider range of load is simply better — and a raw record carries
    /// the exact die and airflow readings, where an aggregate carries a median
    /// `R` times a median wattage, which is not the median of their product.
    ///
    /// The consequence is worth stating: raw records are kept for
    /// ``CoolingHistory/rawRetentionDays`` days, so this describes the last
    /// week. For a forecast that is the right window — a fit from three months
    /// ago would be describing a machine with less dust in it.
    public static func fit(_ history: CoolingHistory) -> CoolingLaw {
        fit(records: history.records)
    }

    /// Fits from records directly — the seam the tests drive.
    public static func fit(records: [CoolingRecord]) -> CoolingLaw {
        var fitted: [FanBand: Band] = [:]
        for (band, members) in Dictionary(grouping: records, by: \.band) {
            if let law = fitBand(members) {
                fitted[band] = law
            }
        }
        return CoolingLaw(bands: fitted)
    }

    /// One band's line, or `nil` when the records cannot support one.
    ///
    /// Ordinary least squares. The interesting part is the four ways it
    /// declines to answer.
    private static func fitBand(_ records: [CoolingRecord]) -> Band? {
        // The count is checked *after* filtering, not before. An earlier
        // version guarded both, and mutation testing showed the first was
        // deletable with every test still green — `points` is a subset of
        // `records`, so the later check subsumes it. A band of twenty records
        // of which fifteen have an unreadable draw is a band of five.
        let points = records
            .map { (watts: $0.watts, rise: $0.dieCelsius - $0.ambientCelsius, fraction: $0.fanFraction) }
            .filter { $0.watts.isFinite && $0.rise.isFinite && $0.watts > 0 }
        guard points.count >= minimumRecordsPerBand else { return nil }

        // The fan speed the readings were taken at, held to the same bar as
        // the line itself and **refused rather than defaulted**. The fraction
        // is not filtered in `points` above because the line does not use it,
        // and losing a record with a good draw would weaken a fit that was
        // fine. But a band that cannot say what its fans were doing has to be
        // dropped, not guessed at the decile midpoint: guessing *low* makes a
        // derived curve command less fan than the readings were taken with,
        // and the machine then settles hotter than the number it promised.
        let fractions = points.map(\.fraction).filter { $0.isFinite && (0 ... 1).contains($0) }
        guard fractions.count >= minimumRecordsPerBand,
              let medianFraction = CoolingStatistics.median(fractions)
        else { return nil }

        let n = Double(points.count)
        let meanWatts = points.reduce(0) { $0 + $1.watts } / n
        let meanRise = points.reduce(0) { $0 + $1.rise } / n
        guard meanWatts > 0 else { return nil }

        // The gate that makes the rest meaningful: without a real spread of
        // load, slope and intercept are not separately identifiable.
        let lowest = points.map(\.watts).min() ?? 0
        let highest = points.map(\.watts).max() ?? 0
        guard (highest - lowest) / meanWatts >= minimumPowerSpreadFraction else { return nil }

        let variance = points.reduce(0) { $0 + ($1.watts - meanWatts) * ($1.watts - meanWatts) }
        guard variance > 0 else { return nil }
        let covariance = points.reduce(0) { $0 + ($1.watts - meanWatts) * ($1.rise - meanRise) }

        let slope = covariance / variance
        let intercept = meanRise - slope * meanWatts
        guard slope.isFinite, intercept.isFinite, slope > 0 else { return nil }

        // Residual standard error, on n − 2 degrees of freedom because the fit
        // spent two on the slope and the intercept.
        let sumSquares = points.reduce(0.0) { total, point in
            let predicted = slope * point.watts + intercept
            let error = point.rise - predicted
            return total + error * error
        }
        let residual = (sumSquares / (n - 2)).squareRoot()
        guard residual.isFinite, residual <= maximumResidualCelsius else { return nil }

        return Band(
            slope: slope,
            intercept: intercept,
            residual: residual,
            records: points.count,
            wattsRange: lowest ... highest,
            medianFanFraction: medianFraction
        )
    }
}
