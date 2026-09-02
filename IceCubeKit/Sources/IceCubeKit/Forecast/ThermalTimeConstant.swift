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
/// dominates the stretch it sampled. The 180 s span of a triple
/// (``spacingSeconds``) biases it toward the slow pole, which is the one that governs where a sustained load ends up,
/// and the consequence is stated where it shows: a forecast built on this is
/// optimistic about the first few seconds of a load step.
public struct ThermalTimeConstant: Sendable, Equatable {
    // MARK: - Constants, and why each has its value

    /// Spacing between the three samples an estimate is built from, seconds.
    ///
    /// **The spacing chooses which pole gets measured, and that is the most
    /// consequential decision in this type.**
    ///
    /// A laptop is not a first-order system. Silicon responds to the heat
    /// spreader in seconds; the spreader, heatsink and chassis respond in
    /// minutes. Fitting one pole to that lands wherever the sampling window
    /// looks — short windows see the fast pole, long ones see the slow one.
    ///
    /// The forecast built on this claims where a load *settles* and how long
    /// that takes, over minutes. That is governed by the slow pole, so the
    /// window has to be long enough to see past the fast one.
    ///
    /// Swept against `MockSMCSimulation`, whose poles are 6 s and 75 s
    /// (70/30), over an hour of its timeline — median recovered τ against
    /// spacing:
    ///
    /// | Spacing | Estimates | p25 | **p50** | p75 |
    /// | --- | --- | --- | --- | --- |
    /// | 10 s | 81 | 18.6 | **31.1** | 51.2 |
    /// | 20 s | 202 | 20.6 | **30.4** | 48.6 |
    /// | 30 s | 291 | 25.4 | **40.6** | 68.1 |
    /// | 60 s | 181 | 36.2 | **56.7** | 100.0 |
    /// | 90 s | 167 | 49.1 | **80.7** | 148.1 |
    ///
    /// Ninety seconds recovers 80.7 s against a true slow pole of 75 — the
    /// only spacing that lands near it. Ten seconds, the first value tried,
    /// reported 31 s: not wrong about anything, just measuring a different
    /// pole from the one the forecast needs.
    ///
    /// The cost is a triple spanning **180 s**, which the machine must hold
    /// steady throughout. That is common at idle and during a long build, and
    /// rare otherwise — the estimator reports how many it has rather than
    /// pretending the wait away.
    ///
    /// The spread stays wide at every spacing (p25 to p75 spans 3×), because
    /// a single pole fitted to two genuinely cannot be tighter. That is why
    /// ``tau`` is a median over many estimates and not one measurement.
    public static let spacingSeconds: TimeInterval = 90

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
    // three samples span `spacingSeconds * 2` = 180 s, and the power gate below
    // rejects any triple whose draw moved — so a fit can only ever run on a
    // window lying entirely after the step, by which point the die's own fast
    // pole is largely spent. The 180 s span *is* the bias toward the slow pole,
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
    /// range.
    ///
    /// The fans changing mid-fit changes the equilibrium the die is chasing,
    /// and the three-point method assumes one asymptote throughout. Unlike the
    /// airflow reference below, this bias does **not** cancel in the ratio.
    ///
    /// One ``FanBand/width``, because that is the resolution at which this app
    /// claims cooling differs at all: ``CoolingLaw`` fits a separate line per
    /// decile, so movement inside one decile is by construction the same
    /// cooling regime. Borrowing ``CoolingRecorder/fanSettleTolerance`` (0.05)
    /// instead was half a band and rejected ~65 % of windows on the simulated
    /// machine for a distinction the rest of the design does not make.
    public static let fanTolerance = FanBand.width

    /// How far airflow may drift across the three samples, °C.
    ///
    /// Deliberately loose, for a reason that took a measurement to see. This
    /// started at 0.5 °C on the reasoning that a rising reference eats into the
    /// die's apparent approach — which sounds right and is mostly wrong.
    ///
    /// **A proportional airflow response cancels in the ratio.** Airflow rises
    /// with the die rather than independently (in `MockSMCSimulation` it takes
    /// a fixed share; on hardware the same coupling is why `docs/THERMAL.md`
    /// warns airflow "is not room temperature"). If `ambient ≈ a₀ + k · rise`,
    /// then `ΔT = die − ambient` is still the same exponential scaled by
    /// `(1 − k)` — and this method divides one difference by another, so every
    /// constant scale factor cancels. τ is unchanged.
    ///
    /// What does bias it is airflow moving on a *different* time constant from
    /// the die, which is a second-order effect, and an outright step — a sensor
    /// glitch, or a machine carried into another room. This catches those.
    ///
    /// Measured on the simulated machine over 20 s windows — at the 10 s spacing
    /// first tried, and not re-measured since ``spacingSeconds`` became 90 s (a
    /// 180 s span, over which this p90 is a lower bound): airflow drifted
    /// 1.22 °C at the median, 5.94 °C at p90. The original 0.5 °C therefore
    /// refused **more than half of all windows**, including every genuine ramp
    /// — `icecube-diag --forecast` accepted zero estimates in 150 s and named
    /// this gate 44 times. That is what the refusal tally is for.
    public static let ambientDriftCelsius: Double = 5

    /// The shortest τ this will believe.
    ///
    /// τ is a quotient whose denominator is a difference of differences, so it
    /// degrades exactly where the machine is most interesting: near
    /// equilibrium both terms vanish. The gates above catch that end. This
    /// bound catches the other — a die that appears to arrive in seconds,
    /// which on a laptop means the three samples straddled something that was
    /// not a thermal ramp.
    ///
    /// A plausibility guard, and — since 2026-09-01 — a measured one.
    ///
    /// These bounds shipped as pure reasoning: from `R ≈ 0.9 °C/W`
    /// (`docs/THERMAL.md`, Mac14,9) and a heatsink assembly of order
    /// 50–150 J/°C, `τ = R·C` lands near 45–135 s, with the die's own fast pole
    /// a few seconds below that. The comment here said so, and said that nobody
    /// had measured it, because the last constant set from first principles
    /// alone — ``ChargingWarmth/onsetCelsius`` — shipped a degree inside the
    /// noise it was meant to clear.
    ///
    /// It has now been measured. `icecube-diag --forecast 1800` over 28 minutes
    /// of ordinary use on a Mac14,9, 89 accepted estimates:
    ///
    /// | p10 | p25 | **p50** | p75 | p90 |
    /// | --- | --- | --- | --- | --- |
    /// | 38.6 s | 49.0 s | **73.7 s** | 130.4 s | 207.8 s |
    ///
    /// The reasoning was right: 73.7 s sits near the middle of the predicted
    /// 45–135 s. **The bounds are unchanged, and that is the finding** — they
    /// were set wide enough to be a guard rather than a filter, and the
    /// measurement confirms nothing real is being clipped. Seven of 1,689 ticks
    /// were rejected as implausible.
    ///
    /// Do not narrow these toward the measured distribution. They exist to
    /// catch a triple that straddled something which was not a thermal ramp —
    /// which produces seconds or many minutes — not to make the median tidier.
    /// A bound inside the real spread would bias the answer while looking
    /// stricter.
    public static let minimumPlausible: TimeInterval = 15

    /// The longest τ this will believe. See ``minimumPlausible``.
    public static let maximumPlausible: TimeInterval = 600

    /// Estimates required before ``tau`` answers.
    ///
    /// One ramp must not set the constant. Twenty spreads the answer across
    /// several separate stretches of work on any real machine.
    ///
    /// Confirmed by the 2026-09-01 measurement run rather than assumed: the
    /// reported median was **68–75 s across the 33 readings** taken from the
    /// 23rd accepted estimate onward, a 7 s spread over the following sixteen
    /// minutes. Twenty is where the answer stops moving, so waiting for more
    /// would buy nothing and cost the user an hour of silence.
    ///
    /// What it costs: ~5 % of ticks are accepted on a real machine in ordinary
    /// use (89 of 1,689), so the first answer arrives after roughly twelve
    /// minutes of the app running. That is a background estimator's timescale,
    /// not a user's, which is why nothing waits on it.
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

    /// A percentile of the accepted estimates, ignoring ``minimumEstimates``.
    ///
    /// For the measurement runs that set ``minimumPlausible`` and
    /// ``maximumPlausible``: a median alone cannot say whether the spread is
    /// tight enough for those bounds to be doing useful work. They were confirmed
    /// rather than moved by the 2026-09-01 run — see ``minimumPlausible``. `icecube-diag
    /// --forecast` prints the distribution; nothing user-facing reads this.
    public func percentile(_ p: Double) -> TimeInterval? {
        CoolingStatistics.percentile(estimates, p)
    }
}
