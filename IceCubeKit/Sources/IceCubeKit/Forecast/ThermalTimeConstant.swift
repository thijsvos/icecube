// ThermalTimeConstant.swift — how fast this Mac's die approaches the temperature it is heading for.

import Foundation

/// The machine's thermal time constant τ, learned from the transients
/// ``CoolingEfficiency`` throws away.
///
/// **The gap this fills.** Ice Cube can say how hot the machine is and how
/// many degrees it pays per watt, but nothing it measures says *how fast*.
/// Without that, "you are at 79 °C" cannot become "you are heading for 91 °C
/// and will be there in two minutes" — the second sentence needs a rate, and
/// the app has never had one.
///
/// **Where the data comes from.** ``CoolingEfficiency/isSettled(_:)`` rejects
/// every sample where the die is still moving, and its own comment calls such
/// a reading *"a measurement of nothing"*. For `R` that is exactly right — a
/// quotient taken mid-ramp describes neither the old state nor the new one.
/// But the ramp is the only place τ exists. `docs/THERMAL.md` records one such
/// reading: **1.89 °C/W while the die fell from 57.9 °C to 53.1 °C**. As an `R`
/// that number is garbage. As an observation of how fast this machine moves, it
/// is data. So the settle rule keeps its veto over `R`, unchanged, and this
/// reads the same stream for the opposite reason.
///
/// **Why it does not need to know where the die is heading.** The obvious
/// method — `τ = (ΔT∞ − ΔT) / (dΔT/dt)` — requires the equilibrium, which
/// would make τ depend on ``CoolingLaw``, which depends on months of history.
/// A new machine would learn nothing, and a wrong equilibrium would bias every
/// estimate without ever announcing itself.
///
/// Three equally spaced samples avoid the problem entirely. For any
/// first-order approach `ΔT(t) = A + B·e^(−t/τ)`, the ratio of successive
/// differences depends only on the spacing and τ:
///
/// ```
/// (ΔT₂ − ΔT₁) / (ΔT₁ − ΔT₀) = e^(−h/τ)      ⇒      τ = −h / ln(ratio)
/// ```
///
/// `A` cancels. The asymptote never appears, so this measures the machine's
/// speed without first having to know its destination — and it is the same
/// arithmetic whether the die is rising or falling.
///
/// **What it is not.** A single pole fitted to a machine that has two. Silicon
/// responds in seconds and the chassis in minutes; this lands on whichever
/// dominates the stretch it sampled. `stepSettleSeconds` biases it toward the
/// slow pole, which is the one that governs where a sustained load ends up,
/// and the consequence is stated where it shows: a forecast built on this is
/// optimistic about the first few seconds of a load step.
public struct ThermalTimeConstant: Sendable, Equatable {
    // MARK: - Constants, and why each has its value

    /// Spacing between the three samples an estimate is built from, seconds.
    ///
    /// The measurement is a ratio of two differences, so the noise floor is
    /// what sets this. Over one second a die 40 °C from its equilibrium with
    /// τ = 75 s moves ~0.53 °C, and the *difference between two such steps* is
    /// under 0.01 °C — far below the ~0.25 °C the SMC reports in. Over ten
    /// seconds the same die moves ~5 °C per step with ~0.6 °C between them,
    /// which is measurable.
    ///
    /// Ten seconds also costs the same twenty seconds of steady machine that
    /// ``CoolingEfficiency/settleWindow`` already asks for, so a stretch that
    /// can produce an `R` can produce a τ.
    public static let spacingSeconds: TimeInterval = 10

    /// How far the real spacing may sit from ``spacingSeconds``, as a fraction.
    ///
    /// The poll interval is user-selectable (1, 2 or 5 s) and a busy machine
    /// drops ticks, so exact spacing cannot be required. Unequal spacing biases
    /// the ratio directly — the formula assumes `h` is the same on both sides —
    /// so this is tight.
    public static let spacingTolerance = 0.20

    // There is deliberately no separate "settle after a load step" window.
    //
    // One was written, and mutation testing showed it could be deleted with
    // every test still green. It was redundant by construction: an estimate's
    // three samples span `spacingSeconds * 2` = 20 s, and the power gate below
    // rejects any triple whose draw moved — so a fit can only ever run on a
    // window lying entirely after the step, by which point the die's own fast
    // pole is largely spent. The 20 s span *is* the bias toward the slow pole,
    // and a second constant asserting the same thing over a shorter horizon
    // only looked like a safeguard.

    /// Smallest first difference worth dividing, °C.
    ///
    /// The denominator. As the die settles, both differences approach zero and
    /// their ratio approaches whatever the sensor's last rounding step was —
    /// during the *calmest* stretch, which is when a reader is most likely to
    /// believe the number. Roughly four times the SMC's reporting granularity.
    public static let minimumDifferenceCelsius: Double = 1.0

    /// How much power may drift across the three samples, as a fraction of the
    /// mean. Borrowed from ``CoolingEfficiency/powerTolerance`` so a stretch
    /// steady enough for `R` is steady enough for τ.
    public static let powerTolerance = CoolingEfficiency.powerTolerance

    /// How much the fans may drift across the three samples, as a fraction of
    /// range. Borrowed from ``CoolingRecorder/fanSettleTolerance``: the fans
    /// changing mid-fit changes the equilibrium the die is chasing, and the
    /// three-point method assumes one asymptote throughout.
    public static let fanTolerance = CoolingRecorder.fanSettleTolerance

    /// How far airflow may drift across the three samples, °C.
    ///
    /// `ΔT` is measured against airflow, and airflow climbs as the chassis
    /// soaks. A rising reference eats into the die's apparent approach and
    /// biases τ long. Half a degree over thirty seconds is slower than any
    /// soak this machine has been measured doing.
    public static let ambientDriftCelsius: Double = 0.5

    /// The shortest τ this will believe.
    ///
    /// τ is a quotient whose denominator is a difference of differences, so it
    /// degrades exactly where the machine is most interesting: near
    /// equilibrium both terms vanish. The gates above catch that end. This
    /// bound catches the other — a die that appears to arrive in seconds,
    /// which on a laptop means the three samples straddled something that was
    /// not a thermal ramp.
    ///
    /// **This is a plausibility guard, not a measurement.** Reasoning from
    /// `R ≈ 0.9 °C/W` (`docs/THERMAL.md`, Mac14,9) and a heatsink assembly of
    /// order 50–150 J/°C puts `τ = R·C` near 45–135 s, and the die's own fast
    /// pole is a few seconds. Nobody has measured it on this hardware.
    ///
    /// The last constant here set from first principles alone was
    /// ``ChargingWarmth/onsetCelsius``, chosen at 32 °C from skin physiology
    /// and corrected to 34 °C the same day when the cells turned out to idle at
    /// 31.9–32.1 °C — it had been sitting *on* the baseline it was meant to
    /// clear. Physiology set the shape of that rule and hardware set its
    /// number. Same split here: the method below is sound, these bounds are
    /// placeholders, and `docs/THERMAL.md` gets the measured distribution
    /// before any of it reaches a user.
    public static let minimumPlausible: TimeInterval = 15

    /// The longest τ this will believe. See ``minimumPlausible``.
    public static let maximumPlausible: TimeInterval = 600

    /// Estimates required before ``tau`` answers.
    ///
    /// One ramp must not set the constant. Twenty spreads the answer across
    /// several separate stretches of work on any real machine.
    public static let minimumEstimates = 20

    /// Most recent estimates kept.
    ///
    /// Bounded because this runs for the life of the app. Most *recent* rather
    /// than all, because τ is a property of the hardware and hardware changes
    /// — a machine that fills with dust genuinely slows down, and an unbounded
    /// median would defend last year's value against this month's evidence.
    public static let maximumEstimates = 200

    // MARK: - Inputs

    /// One tick's worth of what an estimate needs.
    ///
    /// ``CoolingEfficiency/Sample`` plus the fan fraction — the one quantity
    /// that changes the equilibrium without changing power, and therefore the
    /// one this has to watch that `R` does not.
    public struct Observation: Sendable, Equatable {
        public let date: Date
        public let dieCelsius: Double
        public let ambientCelsius: Double
        public let watts: Double
        /// Mean `actualRPM / maxRPM` across usable fans, 0…1.
        public let fanFraction: Double

        public init(
            date: Date, dieCelsius: Double, ambientCelsius: Double,
            watts: Double, fanFraction: Double
        ) {
            self.date = date
            self.dieCelsius = dieCelsius
            self.ambientCelsius = ambientCelsius
            self.watts = watts
            self.fanFraction = fanFraction
        }

        /// The die above the airflow reference — the quantity that decays.
        var rise: Double {
            dieCelsius - ambientCelsius
        }
    }

    /// Why three samples produced no estimate.
    ///
    /// Named rather than collapsed to `nil`, for the same reason
    /// ``CoolingRecorder/Refusal`` is: a diagnosis window that says "no
    /// forecast" is much less useful than one that says which condition the
    /// machine has not met.
    ///
    /// Conforms to `Error` only so it can be `Result`'s failure type — nothing
    /// here is thrown, and a refusal is an ordinary outcome rather than a
    /// fault. Most ticks refuse.
    public enum Refusal: Sendable, Equatable, Error {
        /// A reading was not finite.
        case notFinite
        /// The three samples are not evenly enough spaced in time.
        case unevenSpacing(seconds: [TimeInterval])
        /// Power moved, so the die was chasing a moving target.
        case powerMoved(fraction: Double)
        /// The fans moved, which moves the equilibrium.
        case fansMoved(drift: Double)
        /// The airflow reference drifted, so `rise` is measured against a
        /// moving baseline.
        case ambientDrifted(celsius: Double)
        /// The die is too close to still to divide by.
        case tooStill(difference: Double)
        /// The gap grew instead of shrinking: not a first-order approach, but
        /// a second load step, or the fans easing off.
        case notConverging(ratio: Double)
        /// The die overshot its asymptote between samples — noise, at this
        /// amplitude.
        case overshot(ratio: Double)
        /// Outside ``minimumPlausible``…``maximumPlausible``.
        case implausible(tau: TimeInterval)
    }

    // MARK: - State

    private var recent: [Observation] = []
    private var estimates: [TimeInterval] = []

    /// Why the last attempt produced nothing, or `nil` if it produced an
    /// estimate. Display only — never a gate.
    public private(set) var lastRefusal: Refusal?

    public init() {}

    // MARK: - The measurement

    /// τ from three equally spaced samples, or the reason there is none.
    ///
    /// `samples` must be in ascending time order, oldest first. Pure: the
    /// caller owns the buffer, so every branch is exercisable against scripted
    /// values.
    public static func estimate(_ samples: [Observation]) -> Result<TimeInterval, Refusal> {
        guard samples.count == 3 else {
            return .failure(.unevenSpacing(seconds: []))
        }
        let (first, middle, last) = (samples[0], samples[1], samples[2])

        guard [first, middle, last].allSatisfy({
            $0.dieCelsius.isFinite && $0.ambientCelsius.isFinite
                && $0.watts.isFinite && $0.fanFraction.isFinite
        }) else {
            return .failure(.notFinite)
        }

        // Even spacing. The formula assumes one `h` on both sides; unequal
        // gaps bias the ratio directly.
        let gaps = [
            middle.date.timeIntervalSince(first.date),
            last.date.timeIntervalSince(middle.date),
        ]
        guard let shortest = gaps.min(), let longest = gaps.max(), shortest > 0,
              (longest - shortest) / longest <= spacingTolerance
        else {
            return .failure(.unevenSpacing(seconds: gaps))
        }
        let spacing = (gaps[0] + gaps[1]) / 2

        // The three things that must hold still, so the die is approaching one
        // asymptote for the whole measurement.
        let watts = [first.watts, middle.watts, last.watts]
        let meanWatts = watts.reduce(0, +) / 3
        guard meanWatts > 0 else { return .failure(.powerMoved(fraction: .infinity)) }
        let powerDrift = (watts.map { abs($0 - meanWatts) }.max() ?? 0) / meanWatts
        guard powerDrift <= powerTolerance else {
            return .failure(.powerMoved(fraction: powerDrift))
        }

        let fans = [first.fanFraction, middle.fanFraction, last.fanFraction]
        let fanDrift = (fans.max() ?? 0) - (fans.min() ?? 0)
        guard fanDrift <= fanTolerance else {
            return .failure(.fansMoved(drift: fanDrift))
        }

        let ambients = [first.ambientCelsius, middle.ambientCelsius, last.ambientCelsius]
        let ambientDrift = (ambients.max() ?? 0) - (ambients.min() ?? 0)
        guard ambientDrift <= ambientDriftCelsius else {
            return .failure(.ambientDrifted(celsius: ambientDrift))
        }

        // The ratio of successive differences. `A` cancels, so the asymptote
        // never enters.
        let firstDifference = middle.rise - first.rise
        let secondDifference = last.rise - middle.rise
        guard abs(firstDifference) >= minimumDifferenceCelsius else {
            return .failure(.tooStill(difference: firstDifference))
        }

        let ratio = secondDifference / firstDifference
        guard ratio > 0 else {
            // Sign flip: the die crossed what it was approaching, which a
            // first-order system cannot do. At this amplitude it is noise.
            return .failure(.overshot(ratio: ratio))
        }
        guard ratio < 1 else {
            // The gap is growing. Something started, or the fans eased off.
            return .failure(.notConverging(ratio: ratio))
        }

        let tau = -spacing / log(ratio)
        guard tau.isFinite, tau >= minimumPlausible, tau <= maximumPlausible else {
            return .failure(.implausible(tau: tau))
        }
        return .success(tau)
    }

    // MARK: - Accumulating

    /// Offers one tick to the estimator.
    ///
    /// Keeps a bounded buffer, picks the three samples nearest
    /// ``spacingSeconds`` apart ending at this one, and records an estimate if
    /// every gate passes.
    public mutating func ingest(_ observation: Observation) {
        guard observation.dieCelsius.isFinite, observation.watts.isFinite else {
            lastRefusal = .notFinite
            return
        }

        // A clock that stepped backwards breaks ordering, and an age-only trim
        // can never reach a sample dated after the newest. Same failure
        // `CoolingEfficiency.Tracker` documents; same remedy.
        if let newest = recent.last, observation.date <= newest.date {
            recent.removeAll()
        }
        recent.append(observation)

        let span = Self.spacingSeconds * 2 * (1 + Self.spacingTolerance)
        recent.removeAll { observation.date.timeIntervalSince($0.date) > span + Self.spacingSeconds }

        guard let triple = triple(endingAt: observation) else {
            lastRefusal = .unevenSpacing(seconds: [])
            return
        }
        switch Self.estimate(triple) {
        case let .success(tau):
            estimates.append(tau)
            if estimates.count > Self.maximumEstimates {
                estimates.removeFirst(estimates.count - Self.maximumEstimates)
            }
            lastRefusal = nil
        case let .failure(refusal):
            lastRefusal = refusal
        }
    }

    /// The three samples nearest `spacingSeconds` apart ending at `last`, or
    /// `nil` when the buffer does not hold them.
    private func triple(endingAt last: Observation) -> [Observation]? {
        func nearest(secondsBefore target: TimeInterval) -> Observation? {
            recent
                .filter { $0.date < last.date }
                .min {
                    abs(last.date.timeIntervalSince($0.date) - target)
                        < abs(last.date.timeIntervalSince($1.date) - target)
                }
        }
        guard let middle = nearest(secondsBefore: Self.spacingSeconds),
              let first = nearest(secondsBefore: Self.spacingSeconds * 2),
              first.date < middle.date
        else { return nil }
        return [first, middle, last]
    }

    // MARK: - The answer

    /// The median of accepted estimates, or `nil` below ``minimumEstimates``.
    ///
    /// Median rather than mean, for the reason `CoolingTrend` already
    /// documents: the ways this can be fooled are not symmetric. A ramp
    /// interrupted by a second load step reads as a *longer* τ, and a mean
    /// would be dragged by exactly the failures the gates cannot all catch.
    public var tau: TimeInterval? {
        guard estimates.count >= Self.minimumEstimates else { return nil }
        return CoolingStatistics.median(estimates)
    }

    /// How many estimates have been accepted — the "collecting" number the
    /// copy layer shows against ``minimumEstimates``.
    public var estimateCount: Int {
        estimates.count
    }
}
