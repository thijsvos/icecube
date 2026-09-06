// CurveDerivation.swift — the cooling law run backwards: the quietest curve that holds a temperature.

import Foundation

/// A fan curve derived from what this Mac has measured about itself.
///
/// ``ThermalForecast`` runs the machine's own ``CoolingLaw`` **forwards**:
/// given the curve the user drew, where does this load settle? Every
/// ingredient of the opposite question was already there and nobody had asked
/// it — given a temperature the user wants held, *what curve holds it?*
///
/// ```
/// forwards:  curve + load        →  settling temperature
/// backwards: settling temperature + load  →  the fan speed that holds it
/// ```
///
/// The second line is a curve point. A `FanCurve` maps die temperature to fan
/// speed, and a fitted band maps load to a die temperature at one fan speed,
/// so `(ambient + band.rise(atWatts:), band.medianFanFraction)` is a point the
/// machine has *demonstrated*: run the fans there under that load and it sits
/// there. Sweep the load range, take the slowest band that still holds the
/// target at each step, and the points are the quietest curve the evidence
/// supports.
///
/// ## What it refuses
///
/// The same three things ``CoolingLaw`` and ``ThermalForecast`` refuse, for
/// the same reasons:
///
/// - **One band is not a comparison.** A machine only ever recorded at one fan
///   speed cannot say what a different one buys, and inventing the answer is
///   the failure mode `CoolingLaw.Band.covers(watts:)` exists to prevent.
/// - **Holes in the load coverage are skipped**, not bridged. A step no band
///   was measured near contributes no point.
/// - **Past the evidence there is no fitted answer.** The curve does not
///   extrapolate; it ramps to full fans below the ceiling the daemon enforces
///   and says where the measurements stopped.
///
/// ## What it is not
///
/// A vote on the cooling. `docs/THERMAL.md` parks pre-emptive control on the
/// grounds that "a model that has never run on hardware does not get a vote",
/// and that still holds: this produces **points in an editor** that a person
/// drags, judges and applies. The daemon's clamps, ceiling and watchdog sit
/// underneath a derived curve exactly as they sit under a hand-drawn one.
public enum CurveDerivation {
    // MARK: - Constants, and why each has its value

    /// Measured bands needed before a derivation is attempted.
    ///
    /// Two, because the whole claim is comparative. With one band the answer
    /// to "what would a different fan speed buy" is *nothing this machine has
    /// ever shown*, and a curve built on it would be a preset with extra
    /// steps.
    public static let minimumBands = 2

    /// Load levels the sweep visits across the measured range.
    ///
    /// Resolution, not precision: the fitted lines are continuous, so more
    /// steps only find the band boundaries more exactly. Twenty-four puts the
    /// steps about 1.5 W apart on the reference machine's 19.6–52 W span,
    /// comfortably finer than the ±2 % noise the readings carry, and the
    /// result is thinned to eight points afterwards regardless.
    public static let sweepSteps = 24

    /// Points a derived curve may carry. `FanCurve`'s own cap.
    public static let maximumPoints = 8

    /// How far below the coolest measured settling point the curve reaches the
    /// fan floor, °C.
    ///
    /// Below the lightest load the evidence covers, the machine is doing less
    /// work than anything it ever recorded and needs less cooling than the
    /// slowest measured band was giving it. Without this anchor the curve
    /// would clamp flat at that band's fan speed all the way down, and a Mac
    /// whose records all come from real work would be told to run its fans
    /// while sitting idle.
    public static let quietAnchorCelsius: Double = 10

    /// The most fan speed a derived curve may gain per degree.
    ///
    /// **Without this the derivation produces a cliff.** "The quietest fan
    /// speed that holds the target" is a hard cap, and the mathematically
    /// optimal answer to a hard cap is bang-bang: on the reference plant the
    /// raw sweep jumped from 5 % to 85 % across **0.6 °C**, because the load
    /// at which the slowest band stops coping and the load at which it needs
    /// nearly everything are barely any distance apart in temperature. That is
    /// a correct answer and a useless controller — `CurveFollower` carries a
    /// 4 °C hysteresis deadband, so a curve whose entire range lives inside
    /// 0.6 °C is a step function that hunts.
    ///
    /// The escape is that the sweep produces a **lower bound**, not a
    /// prescription: any curve at or above it holds the target. So the
    /// steepness is capped and paid for by starting the ramp earlier — more
    /// fan at cooler temperatures, never less, which is the safe direction and
    /// keeps the promise intact.
    ///
    /// 0.05 per °C takes a curve from floor to full in 20 °C. For scale, the
    /// shipped presets ramp at 0.025 (Balanced), 0.033 (Quiet) and 0.0147
    /// (Cold's steepest segment), so this still allows a curve half again as
    /// steep as anything Ice Cube ships, and five deadbands wide.
    public static let maximumFractionPerCelsius = 0.05

    /// How far below the die ceiling a derived curve reaches full fans, °C.
    ///
    /// The one point in a derived curve that is not a measurement. Past the
    /// measured load range there is no fitted answer and this deliberately
    /// does not invent one — it hands over to full cooling with room to spare
    /// before ``SafetyMonitor`` would take the fans itself. Ten degrees is the
    /// same margin the daemon's own release delta works in twice over.
    public static let ceilingMarginCelsius: Double = 10

    /// The temperature by which a derived curve is always at full fans.
    public static var fullFanCelsius: Double {
        SafetyMonitor.Limits().dieCeiling - ceilingMarginCelsius
    }

    /// The range of targets worth offering, °C.
    ///
    /// The floor is not a promise that 70 °C is reachable — most Macs under
    /// real load cannot, and ``Derivation/shortfall`` is how that is said.
    /// It is the range in which asking is meaningful: below 70 °C every
    /// machine is at full fans, and above 95 °C the die ceiling is doing the
    /// work rather than the curve.
    public static let targetRange: ClosedRange<Double> = 70 ... 95

    // MARK: - The verdict

    /// Why there is no derivation — named, so the editor can say what is
    /// missing rather than draw an empty plot. Same shape as
    /// ``ThermalForecast/Gap`` and ``CoolingTrend/Gap``.
    public enum Gap: Sendable, Equatable {
        /// Fewer than ``minimumBands`` fan speeds have been measured.
        case tooFewBands(measured: Int, need: Int)
        /// Bands exist but cover no usable span of load.
        case noLoadCovered
    }

    /// The loads the target could not be held at, and the best the machine
    /// managed there.
    ///
    /// Present whenever the evidence says the request is not available on this
    /// hardware — which is a finding, not a failure. A derived curve is still
    /// returned: it holds what it can.
    public struct Shortfall: Sendable, Equatable {
        public let watts: Double
        public let settlesAtCelsius: Double
        public let fanFraction: Double
    }

    /// A curve and the evidence behind it.
    public struct Derivation: Sendable, Equatable {
        public let curve: FanCurve
        /// What was asked for, °C.
        public let targetCelsius: Double
        /// The warmest settling point inside the measured evidence, °C — what
        /// this curve actually promises, which is `targetCelsius` unless there
        /// is a ``shortfall``.
        public let holdsAtCelsius: Double
        /// The load range the evidence covers, watts.
        public let wattsRange: ClosedRange<Double>
        /// Fan speeds the derivation drew on.
        public let bandsUsed: Int
        /// Readings behind those bands.
        public let records: Int
        /// `nil` when the target was met everywhere it was asked.
        public let shortfall: Shortfall?
    }

    public enum Verdict: Sendable, Equatable {
        case unavailable(Gap)
        case derived(Derivation)
    }

    // MARK: - Deriving

    /// The quietest curve this Mac's own measurements say will hold
    /// `targetCelsius` under sustained load.
    ///
    /// - Parameters:
    ///   - targetCelsius: the die temperature to hold.
    ///   - law: fitted from the machine's cooling history.
    ///   - ambientCelsius: the airflow reference the law's rises are measured
    ///     above. Treated as fixed, the same simplification — and the same
    ///     limitation — as ``ThermalForecast``. Use ``ambient(from:)``.
    public static func derive(
        holdingAt targetCelsius: Double,
        law: CoolingLaw,
        ambientCelsius: Double
    ) -> Verdict {
        let measured = law.measuredBands.compactMap { band in
            law.band(band).map { (band: band, law: $0) }
        }
        guard measured.count >= minimumBands else {
            return .unavailable(.tooFewBands(measured: measured.count, need: minimumBands))
        }

        // Slowest fans first: the sweep wants the *quietest* band that holds
        // the target, so it walks the ladder in that order and stops at the
        // first one that does.
        let ladder = measured.sorted { $0.law.medianFanFraction < $1.law.medianFanFraction }
        guard let lowestWatts = ladder.map(\.law.wattsRange.lowerBound).min(),
              let highestWatts = ladder.map(\.law.wattsRange.upperBound).max(),
              highestWatts > lowestWatts
        else { return .unavailable(.noLoadCovered) }

        var emitted: [CurvePoint] = []
        var usedBands: Set<FanBand> = []
        var records = 0
        var shortfall: Shortfall?

        for step in 0 ... sweepSteps {
            let watts = lowestWatts
                + (highestWatts - lowestWatts) * Double(step) / Double(sweepSteps)
            // Only bands measured near *this* draw. A hole in the coverage
            // contributes nothing rather than borrowing a neighbour's line.
            let usable = ladder.filter { $0.law.covers(watts: watts) }
            guard !usable.isEmpty else { continue }

            let holding = usable.first { ambientCelsius + $0.law.rise(atWatts: watts) <= targetCelsius }
            // Nothing measured holds it here, so the fastest band this machine
            // has actually run at is the best it has ever shown it can do.
            // Recorded and reported; never rounded up into a faster band it
            // has never been in.
            guard let chosen = holding ?? usable.last else { continue }

            let settles = ambientCelsius + chosen.law.rise(atWatts: watts)
            emitted.append(CurvePoint(celsius: settles, fraction: chosen.law.medianFanFraction))
            if usedBands.insert(chosen.band).inserted {
                records += chosen.law.records
            }
            if holding == nil, settles > (shortfall?.settlesAtCelsius ?? -.infinity) {
                shortfall = Shortfall(
                    watts: watts,
                    settlesAtCelsius: settles,
                    fanFraction: chosen.law.medianFanFraction
                )
            }
        }

        guard let coolest = emitted.min(by: { $0.celsius < $1.celsius }),
              let hottest = emitted.max(by: { $0.celsius < $1.celsius })
        else { return .unavailable(.noLoadCovered) }

        // Both anchors sit clear of every emitted point by more than the
        // 0.5 °C `FanCurve.normalized` collapses within, so neither can be
        // deduped away by a measurement that happened to land beside it.
        let required = (emitted
            + [CurvePoint(celsius: coolest.celsius - quietAnchorCelsius, fraction: 0)]
            + [CurvePoint(celsius: max(hottest.celsius + 1, fullFanCelsius), fraction: 1)])
            .sorted { $0.celsius < $1.celsius }

        // Followable, then small, then still above the requirement. The order
        // matters: thinning a smoothed ramp drops points that were nearly
        // collinear anyway, where thinning the raw cliff would have had to
        // choose which half of it to lose.
        let shaped = repair(thin(limitSteepness(required), to: maximumPoints), meeting: required)

        return .derived(Derivation(
            curve: FanCurve(points: shaped),
            targetCelsius: targetCelsius,
            holdsAtCelsius: hottest.celsius,
            wattsRange: lowestWatts ... highestWatts,
            bandsUsed: usedBands.count,
            records: records,
            shortfall: shortfall
        ))
    }

    /// The airflow reference to derive against: the median of the readings the
    /// law was fitted from.
    ///
    /// The median of the *history* rather than the live snapshot, because a
    /// derivation describes the machine over the week the law covers, and a
    /// curve that redrew itself every time the airflow sensor moved 0.2 °C
    /// would be describing the last two seconds instead.
    public static func ambient(from records: [CoolingRecord]) -> Double? {
        CoolingStatistics.median(records.map(\.ambientCelsius).filter(\.isFinite))
    }

    // MARK: - The evidence, drawn

    /// One measured fan speed and the temperatures it settles at.
    ///
    /// A fan curve's plot is temperature across and fan speed up, which is
    /// exactly the space a fitted band lives in — so a band is a **horizontal
    /// span** on that plot: at this fan speed, across the loads this machine
    /// was actually measured under, it sits between these two temperatures.
    /// Drawing them is what turns an empty grid into a picture of where this
    /// Mac lives, and of how much of the plot it has never been in.
    public struct MeasuredSpan: Sendable, Equatable, Identifiable {
        public let band: FanBand
        public let fanFraction: Double
        public let celsius: ClosedRange<Double>
        public let records: Int
        public var id: Int {
            band.sortKey
        }
    }

    /// Every measured band as a span, coolest-running first.
    public static func measuredSpans(law: CoolingLaw, ambientCelsius: Double) -> [MeasuredSpan] {
        law.measuredBands.compactMap { band -> MeasuredSpan? in
            guard let fitted = law.band(band) else { return nil }
            let cool = ambientCelsius + fitted.rise(atWatts: fitted.wattsRange.lowerBound)
            let warm = ambientCelsius + fitted.rise(atWatts: fitted.wattsRange.upperBound)
            // Not decoration: `ClosedRange` **traps** on inverted bounds. The
            // shipped fit refuses a non-positive slope so this cannot happen
            // from `CoolingLaw.fit`, but `Band` is a public value anyone can
            // construct, and a trap inside a `Canvas` body takes the app with
            // it. Skipping the band is the cheap, correct answer.
            guard warm >= cool else { return nil }
            return MeasuredSpan(
                band: band,
                fanFraction: fitted.medianFanFraction,
                celsius: cool ... warm,
                records: fitted.records
            )
        }
        .sorted { $0.celsius.lowerBound < $1.celsius.lowerBound }
    }
}
