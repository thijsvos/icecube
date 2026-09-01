// ThermalForecast.swift — where the die is heading, when it arrives, and what the fans would change.

import Foundation

/// The projection: where this load settles, how long that takes, and what a
/// different fan speed would settle at instead.
///
/// Every Mac fan tool is reactive — it shows the temperature now and fires a
/// rule after a threshold is crossed. This is the same three measurements those
/// tools already have, run forward:
///
/// ```
/// ΔT(t) = ΔT∞ + (ΔT₀ − ΔT∞) · e^(−t/τ)
/// ```
///
/// ``CoolingLaw`` supplies `ΔT∞` for a given draw and fan band;
/// ``ThermalTimeConstant`` supplies `τ`; the snapshot supplies `ΔT₀`. Nothing
/// here measures anything, and nothing here is new physics — the work is in
/// deciding when the three inputs support an answer.
///
/// ## The curve is the interesting part
///
/// The naive projection — evaluate the law at the *current* fan band — is
/// wrong whenever a curve is running, because the fans will not stay where
/// they are. As the die climbs the curve raises them, the band changes, the
/// law changes, and the machine settles cooler than the naive answer.
///
/// Ice Cube knows the curve; the user drew it. So the honest settling point is
/// a **fixed point**:
///
/// ```
/// T* = T_airflow + law(band(curve(T*))).rise(atWatts: P)
/// ```
///
/// solved by iteration from where the die is now. That is what lets the window
/// say *"your Balanced curve will take the fans to 5,150 RPM as it climbs"* —
/// a sentence built from the user's own curve and their own machine's measured
/// cooling, which is the whole claim of this feature.
///
/// ## What it will not do
///
/// Touch the fans. This reads, projects and returns text for someone else to
/// render. Letting a learned model *command* cooling — pre-emptive spin-up on
/// a forecast — is the obvious next thing and is deliberately not here: a model
/// that has never run on hardware does not get a vote on the cooling.
public enum ThermalForecast {
    // MARK: - Constants

    /// How close to the asymptote counts as arrived, °C.
    ///
    /// A first-order approach never actually gets there, so "when does it
    /// settle" is only answerable to within a band. Two degrees is a little
    /// above the SMC's own reporting granularity and well inside the width of
    /// any band a reader would act on.
    public static let settlingBandCelsius: Double = 2

    // There is deliberately no iteration limit or convergence tolerance.
    //
    // Both existed while the fixed point was solved by walking from the
    // current temperature, and both became dead the moment `solve` changed to
    // searching the measured bands instead. That search is bounded by how many
    // bands this machine has records in — at most ten — so there is nothing to
    // give up on and no tolerance to hit.

    /// The furthest ahead this will claim, seconds.
    ///
    /// Half an hour. Past that the inputs have almost certainly changed — the
    /// user closed the lid, the build finished, the room warmed — and a number
    /// with hours on it reads as precision the model does not have.
    public static let maximumHorizon: TimeInterval = 1800

    // MARK: - The verdict

    public enum Verdict: Sendable, Equatable {
        /// No answer, and which input is missing.
        case unavailable(Gap)
        /// The load settles below the ceiling.
        case settling(Projection)
        /// The projection crosses the ceiling the daemon enforces, and when.
        case reachesCeiling(Projection, inSeconds: TimeInterval)
    }

    /// Why there is no forecast — named, so the window can say what is missing
    /// rather than shrug. Same shape as ``CoolingTrend/Gap``.
    ///
    /// Conforms to `Error` only so the fixed-point solver can return it as a
    /// `Result` failure; nothing here is thrown, and a gap is an ordinary
    /// outcome. Most of the time this type has one.
    public enum Gap: Sendable, Equatable, Error {
        /// Not enough transients seen yet.
        case noTimeConstantYet(estimates: Int, need: Int)
        /// This machine has never been measured at this fan speed.
        case bandNotMeasured(FanBand)
        /// The draw is moving, so there is no equilibrium to head toward.
        case loadNotSteady
        /// The fans cannot be read well enough to say which band they are in.
        case fansUnreadable
        /// Further out than ``maximumHorizon``.
        case beyondHorizon
    }

    public struct Projection: Sendable, Equatable {
        /// Where the die ends up, °C.
        public let settlesAtCelsius: Double
        /// How long until it is within ``settlingBandCelsius`` of that.
        public let secondsToSettle: TimeInterval
        /// The band it settles in — the current one under manual control, or
        /// wherever the curve takes it.
        public let settlingBand: FanBand
        /// Fan speed at the settling point, or `nil` when no curve is running
        /// and the fans are wherever they were put.
        public let fanRPMAtSettle: Double?
        /// What a different fan speed would settle at, when this machine has
        /// been measured at one that is cooler.
        public let counterfactual: Counterfactual?
    }

    /// The comparison the whole feature exists for: what the noise would buy,
    /// in degrees, before it is paid for.
    public struct Counterfactual: Sendable, Equatable {
        public let band: FanBand
        public let settlesAtCelsius: Double
        /// Always positive — this is only built when the alternative is cooler.
        public let degreesSaved: Double
    }

    // MARK: - The projection

    /// Projects the current state forward.
    ///
    /// - Parameters:
    ///   - isLoadSteady: whether the draw has been holding still. Passed in
    ///     rather than inferred, because a snapshot cannot know: the caller
    ///     holds the window. A forecast from a moving load projects toward an
    ///     equilibrium that is itself moving, which is the one way this can be
    ///     confidently wrong.
    ///   - curve: the running curve, or `nil` under manual control. With a
    ///     curve the settling point is a fixed point; without one the fans stay
    ///     where they are and it is a single evaluation.
    ///   - tau: from ``ThermalTimeConstant/tau``. `nil` while still collecting.
    public static func project(
        dieCelsius: Double,
        ambientCelsius: Double,
        watts: Double,
        fans: [Fan],
        curve: FanCurve?,
        law: CoolingLaw,
        tau: TimeInterval?,
        estimateCount: Int = 0,
        isLoadSteady: Bool
    ) -> Verdict {
        guard isLoadSteady else { return .unavailable(.loadNotSteady) }
        guard let tau, tau > 0 else {
            return .unavailable(.noTimeConstantYet(
                estimates: estimateCount,
                need: ThermalTimeConstant.minimumEstimates
            ))
        }
        guard dieCelsius.isFinite, ambientCelsius.isFinite, watts.isFinite else {
            return .unavailable(.loadNotSteady)
        }
        guard let context = FanContext.measure(fans) else {
            return .unavailable(.fansUnreadable)
        }

        // Where it settles. With a curve the fans move as the die does, so the
        // answer is a fixed point rather than one evaluation.
        let settled: (celsius: Double, band: FanBand)
        if let curve, curve.isUsable {
            switch solve(
                from: dieCelsius, ambient: ambientCelsius, watts: watts, curve: curve, law: law
            ) {
            case let .success(result): settled = result
            case let .failure(gap): return .unavailable(gap)
            }
        } else {
            guard let band = law.band(context.band), band.covers(watts: watts) else {
                return .unavailable(.bandNotMeasured(context.band))
            }
            settled = (ambientCelsius + band.rise(atWatts: watts), context.band)
        }

        let currentRise = dieCelsius - ambientCelsius
        let settledRise = settled.celsius - ambientCelsius

        // Time to arrive, to within the settling band. Already inside it means
        // zero, not a negative logarithm.
        let gap = abs(settledRise - currentRise)
        let secondsToSettle = gap <= settlingBandCelsius
            ? 0
            : tau * log(gap / settlingBandCelsius)
        guard secondsToSettle.isFinite, secondsToSettle <= maximumHorizon else {
            return .unavailable(.beyondHorizon)
        }

        let projection = Projection(
            settlesAtCelsius: settled.celsius,
            secondsToSettle: secondsToSettle,
            settlingBand: settled.band,
            fanRPMAtSettle: curve.flatMap { curve in
                fanRPM(atFraction: curve.fraction(at: settled.celsius), fans: fans)
            },
            counterfactual: counterfactual(
                against: settled, ambient: ambientCelsius, watts: watts, law: law
            )
        )

        // Does it cross the line the daemon enforces on the way?
        let ceiling = SafetyMonitor.Limits().dieCeiling
        guard settled.celsius > ceiling, dieCelsius < ceiling else {
            return .settling(projection)
        }
        let ceilingRise = ceiling - ambientCelsius
        let numerator = settledRise - currentRise
        let denominator = settledRise - ceilingRise
        guard numerator > 0, denominator > 0 else { return .settling(projection) }
        let seconds = tau * log(numerator / denominator)
        guard seconds.isFinite, seconds >= 0, seconds <= maximumHorizon else {
            return .settling(projection)
        }
        return .reachesCeiling(projection, inSeconds: seconds)
    }

    // MARK: - The fixed point

    /// Solves `T* = ambient + law(band(curve(T*))).rise(atWatts:)`.
    ///
    /// **A search over the bands actually measured, not an iteration through
    /// arbitrary ones.** Iterating was the first attempt and it was the wrong
    /// shape: a real machine has records in a handful of deciles, so the walk
    /// passes through bands that have never been measured and dies there, even
    /// when the answer it was heading for is one the machine knows perfectly
    /// well. The fixed point can only ever *land* in a measured band, so the
    /// measured bands are the whole search space.
    ///
    /// A band is the answer when it is **self-consistent**: the temperature its
    /// law predicts is one at which the user's curve asks for that same band.
    ///
    /// Three outcomes, all deliberate:
    ///
    /// - **One self-consistent band** — the fixed point.
    /// - **Several** — take the warmest. Conservative is the right direction
    ///   for a number someone might act on.
    /// - **None, but two bands point at each other** — a genuine oscillation
    ///   across a boundary: one settles hot enough to want more fan, the other
    ///   settles cool enough to want less, and the true fixed point sits on the
    ///   edge between them. Resolved to the warmer, for the same reason.
    /// - **None at all** — the fixed point lies in a band this machine has
    ///   never run in. Refuse, and name it, rather than borrow a neighbour's.
    private static func solve(
        from _: Double,
        ambient: Double,
        watts: Double,
        curve: FanCurve,
        law: CoolingLaw
    ) -> Result<(celsius: Double, band: FanBand), Gap> {
        // What each measured band settles at, and which band the curve would
        // then ask for.
        //
        // Only bands measured near *this* draw. A line evaluated far outside
        // the readings that produced it is extrapolation, and on the seeded
        // history it produced exactly backwards answers — see
        // `CoolingLaw.Band.covers(watts:)`.
        typealias Candidate = (band: FanBand, celsius: Double, wants: FanBand)
        let candidates: [Candidate] = law.measuredBands.compactMap { band in
            guard let fitted = law.band(band), fitted.covers(watts: watts) else { return nil }
            let celsius = ambient + fitted.rise(atWatts: watts)
            return (
                band: band,
                celsius: celsius,
                wants: FanBand.band(forFraction: curve.fraction(at: celsius))
            )
        }
        guard !candidates.isEmpty else {
            return .failure(.bandNotMeasured(.decile(0)))
        }

        let consistent = candidates.filter { $0.band == $0.wants }
        if let warmest = consistent.max(by: { $0.celsius < $1.celsius }) {
            return .success((warmest.celsius, warmest.band))
        }

        // No band agrees with itself. A pair that agrees with each other is an
        // oscillation across a boundary, which has a real answer between them.
        for first in candidates {
            guard let second = candidates.first(where: { $0.band == first.wants }),
                  second.wants == first.band
            else { continue }
            let warmer = first.celsius >= second.celsius ? first : second
            return .success((warmer.celsius, warmer.band))
        }

        // The fixed point is somewhere this machine has never been measured.
        // Name the band the curve keeps asking for from the warmest candidate.
        let warmest = candidates.max { $0.celsius < $1.celsius }
        return .failure(.bandNotMeasured(warmest?.wants ?? .decile(0)))
    }

    /// The coolest band this machine has actually been measured in, if it is
    /// cooler than where it is heading.
    ///
    /// Absent rather than zero when there is nothing better to offer, and
    /// absent entirely for bands this machine has never run in — the app does
    /// not extrapolate onto fan speeds it has never seen.
    private static func counterfactual(
        against settled: (celsius: Double, band: FanBand),
        ambient: Double,
        watts: Double,
        law: CoolingLaw
    ) -> Counterfactual? {
        // No `best.band != settled.band` check: it was there, and mutation
        // testing showed it deletable with every test green. The same band
        // computes the same rise, so `saved` is exactly zero and the floor
        // below rejects it anyway.
        guard let best = law.coolestBand(atWatts: watts) else { return nil }
        let celsius = ambient + best.law.rise(atWatts: watts)
        let saved = settled.celsius - celsius
        guard saved > settlingBandCelsius else { return nil }
        return Counterfactual(band: best.band, settlesAtCelsius: celsius, degreesSaved: saved)
    }

    /// Converts a fan fraction into RPM using the fans' own reported range.
    private static func fanRPM(atFraction fraction: Double, fans: [Fan]) -> Double? {
        let usable = fans.filter(\.hasUsableRange)
        guard !usable.isEmpty else { return nil }
        let total = usable.reduce(0.0) { sum, fan in
            sum + fan.minRPM + fraction.clamped(to: 0 ... 1) * (fan.maxRPM - fan.minRPM)
        }
        return total / Double(usable.count)
    }
}
