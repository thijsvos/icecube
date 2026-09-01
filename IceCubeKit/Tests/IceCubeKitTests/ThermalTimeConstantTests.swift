// ThermalTimeConstantTests.swift — a rate is easy to compute and easy to fake; these are the refusals around it.

import Foundation
@testable import IceCubeKit
import Testing

/// τ is one logarithm. The tests are not about the arithmetic — they are about
/// the nine ways three samples can look like a thermal ramp without being one.
///
/// The failure is silent and asymmetric. A bad τ does not look bad: it produces
/// a forecast with a plausible number of minutes on it, and the reader cannot
/// tell it from a good one by looking. Every gate that returns a refusal is
/// therefore worth more than the path that returns a number, and each is pinned
/// here — mutation-verified, because a gate with no failing test is a gate that
/// can be deleted.
@Suite("ThermalTimeConstant — when a ramp is a measurement, and when it is not")
struct ThermalTimeConstantTests {
    private static let epoch = Date(timeIntervalSince1970: 1_753_000_000)
    private static let spacing = ThermalTimeConstant.spacingSeconds

    /// Three samples on a perfect first-order approach to `asymptote` with the
    /// given τ, spaced `spacing` apart — the signal the estimator is meant to
    /// recover.
    private static func ramp(
        tau: TimeInterval,
        from start: Double = 40,
        asymptote: Double = 10,
        ambient: Double = 40,
        watts: Double = 30,
        fanFraction: Double = 0.5,
        spacing: TimeInterval = ThermalTimeConstant.spacingSeconds
    ) -> [ThermalTimeConstant.Observation] {
        (0 ..< 3).map { step in
            let t = Double(step) * spacing
            let rise = asymptote + (start - asymptote) * exp(-t / tau)
            return ThermalTimeConstant.Observation(
                date: epoch.addingTimeInterval(t),
                dieCelsius: ambient + rise,
                ambientCelsius: ambient,
                watts: watts,
                fanFraction: fanFraction
            )
        }
    }

    /// Observations at the given rises above a fixed airflow, spaced
    /// ``ThermalTimeConstant/spacingSeconds`` apart, with everything else held
    /// still — for shapes that are easier to state than to derive.
    private static func observations(rises: [Double]) -> [ThermalTimeConstant.Observation] {
        rises.enumerated().map { index, rise in
            ThermalTimeConstant.Observation(
                date: epoch.addingTimeInterval(Double(index) * spacing),
                dieCelsius: 40 + rise,
                ambientCelsius: 40,
                watts: 30,
                fanFraction: 0.5
            )
        }
    }

    private static func mutate(
        _ samples: [ThermalTimeConstant.Observation],
        index: Int,
        die: Double? = nil,
        ambient: Double? = nil,
        watts: Double? = nil,
        fanFraction: Double? = nil,
        date: Date? = nil
    ) -> [ThermalTimeConstant.Observation] {
        var copy = samples
        let old = copy[index]
        copy[index] = ThermalTimeConstant.Observation(
            date: date ?? old.date,
            dieCelsius: die ?? old.dieCelsius,
            ambientCelsius: ambient ?? old.ambientCelsius,
            watts: watts ?? old.watts,
            fanFraction: fanFraction ?? old.fanFraction
        )
        return copy
    }

    // MARK: - The arithmetic

    /// The whole method in one assertion: a clean exponential gives back the τ
    /// it was built from, without ever being told where it was heading.
    @Test("A clean ramp recovers its own time constant", arguments: [20.0, 45.0, 75.0, 150.0])
    func recoversTau(tau: TimeInterval) throws {
        let estimate = try Self.estimate(Self.ramp(tau: tau))
        #expect(abs(estimate - tau) / tau < 0.01, "built from τ=\(tau), recovered \(estimate)")
    }

    /// The measurement's real limit, pinned rather than papered over.
    ///
    /// The slower the machine and the smaller its swing, the less it moves
    /// between samples, and at some point the two differences are smaller than
    /// the sensor's own steps. A 400 s machine swinging only 4 °C moves under
    /// a degree across the window — below
    /// ``ThermalTimeConstant/minimumDifferenceCelsius``, so it is refused.
    ///
    /// This is the correct answer, not a gap: the alternative is dividing two
    /// numbers that are mostly rounding error and reporting whatever comes
    /// out. Such a machine becomes measurable when it swings harder, which is
    /// exactly when a forecast about it would matter.
    @Test("A very slow machine with a small swing is refused, not guessed at")
    func slowMachineWithSmallSwingIsRefused() throws {
        guard case .tooStill = ThermalTimeConstant.estimate(
            Self.ramp(tau: 400, from: 14, asymptote: 10)
        ).refusal else {
            Issue.record("under a degree per step is beneath the noise floor and must not be divided")
            return
        }
        // The same machine, swinging hard enough to measure.
        let big = try Self.estimate(Self.ramp(tau: 400, from: 120, asymptote: 10))
        #expect(abs(big - 400) / 400 < 0.01, "recovered \(big) from a 400 s machine")
    }

    /// The property that makes this independent of ``CoolingLaw``: the
    /// asymptote cancels, so the same ramp shifted to a different destination
    /// must give the same answer.
    @Test("The answer does not depend on where the die is heading")
    func asymptoteCancels() throws {
        let low = try Self.estimate(Self.ramp(tau: 75, from: 40, asymptote: 5))
        let high = try Self.estimate(Self.ramp(tau: 75, from: 60, asymptote: 25))
        #expect(abs(low - high) < 0.01, "\(low) vs \(high) — the asymptote must cancel")
    }

    /// Cooling is the same measurement as heating. `docs/THERMAL.md`'s one
    /// recorded transient is a *falling* die (57.9 → 53.1 °C), so the method
    /// must work in that direction or it cannot use the only such reading the
    /// project has.
    @Test("A cooling die measures the same as a heating one")
    func worksWhileCooling() throws {
        let rising = try Self.estimate(Self.ramp(tau: 75, from: 10, asymptote: 50))
        let falling = try Self.estimate(Self.ramp(tau: 75, from: 50, asymptote: 10))
        #expect(abs(rising - falling) < 0.01)
    }

    // MARK: - The refusals

    @Test("A failed sensor read never becomes a time constant", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteIsRefused(bad: Double) {
        let samples = Self.mutate(Self.ramp(tau: 75), index: 1, die: bad)
        #expect(ThermalTimeConstant.estimate(samples).refusal == .notFinite)
    }

    /// The formula assumes one spacing on both sides. Unequal gaps bias the
    /// ratio directly, and the poll interval is user-selectable, so this cannot
    /// be assumed.
    @Test("Unevenly spaced samples are refused rather than fitted")
    func unevenSpacingIsRefused() {
        let samples = Self.ramp(tau: 75)
        let shifted = Self.mutate(
            samples, index: 1,
            date: samples[0].date.addingTimeInterval(Self.spacing * 0.5)
        )
        guard case .unevenSpacing = ThermalTimeConstant.estimate(shifted).refusal else {
            Issue
                .record(
                    "expected unevenSpacing, got \(String(describing: ThermalTimeConstant.estimate(shifted).refusal))"
                )
            return
        }
    }

    /// Power moving means the die is chasing a target that is itself moving,
    /// so the decay is not toward a fixed asymptote and the ratio means
    /// nothing.
    @Test("Power moving mid-measurement is refused")
    func powerMovedIsRefused() {
        let samples = Self.mutate(Self.ramp(tau: 75), index: 2, watts: 45)
        guard case .powerMoved = ThermalTimeConstant.estimate(samples).refusal else {
            Issue.record("a 50 % jump in draw must not produce a time constant")
            return
        }
    }

    /// The gate `CoolingEfficiency` does not need and this does: the fans
    /// change the equilibrium without changing the power, so a spin-up
    /// mid-measurement moves the asymptote invisibly.
    @Test("The fans moving is refused, even at perfectly steady power")
    func fansMovedIsRefused() {
        let samples = Self.mutate(Self.ramp(tau: 75), index: 2, fanFraction: 0.9)
        guard case .fansMoved = ThermalTimeConstant.estimate(samples).refusal else {
            Issue.record("the fans moved 0.4 of range at constant watts and it was not caught")
            return
        }
    }

    /// The gate catches a *step* in the airflow reference — a sensor glitch, or
    /// a machine moved to a different room — not the ordinary correlated rise,
    /// which cancels in the ratio. See ``ThermalTimeConstant/ambientDriftCelsius``.
    @Test("A step in the airflow reference is refused")
    func ambientStepIsRefused() {
        let samples = Self.ramp(tau: 75)
        let stepped = Self.mutate(
            samples, index: 2,
            die: samples[2].dieCelsius + 8,
            ambient: samples[2].ambientCelsius + 8
        )
        guard case .ambientDrifted = ThermalTimeConstant.estimate(stepped).refusal else {
            Issue.record("an 8 °C airflow step must not pass")
            return
        }
    }

    /// The property that let the gate be loosened from 0.5 °C to 5 °C, and the
    /// reason it was wrong to be tight.
    ///
    /// Airflow does not drift independently — it rises *with* the die, taking a
    /// share of the same heat. That makes `ΔT` the same exponential scaled by a
    /// constant, and this method divides one difference by another, so the
    /// scale cancels exactly. A tight gate bought nothing and refused every
    /// genuine ramp: `icecube-diag --forecast` accepted zero estimates in 150 s
    /// with the old value.
    @Test("An airflow that rises with the die does not change the answer")
    func proportionalAmbientCancels() throws {
        let fixed = try Self.estimate(Self.ramp(tau: 75, from: 20, asymptote: 5))

        // The same die, with airflow taking a fifth of its rise.
        let coupled = Self.ramp(tau: 75, from: 20, asymptote: 5).map { sample in
            ThermalTimeConstant.Observation(
                date: sample.date,
                dieCelsius: sample.dieCelsius,
                ambientCelsius: sample.ambientCelsius + 0.2 * sample.rise,
                watts: sample.watts,
                fanFraction: sample.fanFraction
            )
        }
        let scaled = try Self.estimate(coupled)
        #expect(abs(scaled - fixed) < 0.01, "\(fixed) vs \(scaled) — a constant scale must cancel")
    }

    /// The denominator. Near equilibrium both differences vanish and the ratio
    /// becomes the sensor's rounding step — during the calmest stretch, which
    /// is when a reader is most likely to believe it.
    @Test("A die that has nearly arrived yields nothing, however clean the power")
    func tooStillIsRefused() {
        // 0.2 °C from a 75 s asymptote: real, tiny, and unmeasurable.
        let samples = Self.ramp(tau: 75, from: 10.2, asymptote: 10)
        guard case .tooStill = ThermalTimeConstant.estimate(samples).refusal else {
            Issue.record("a still die must not be divided by")
            return
        }
    }

    /// A gap that grows is not a first-order approach. Something started, or
    /// the fans eased off — either way the model does not apply.
    @Test("A die pulling away from its equilibrium is refused, not fitted")
    func divergingIsRefused() {
        let base = Self.ramp(tau: 75, from: 10, asymptote: 50)
        // Accelerating away instead of decelerating toward.
        let diverging = Self.mutate(base, index: 2, die: base[2].dieCelsius + 20)
        guard case .notConverging = ThermalTimeConstant.estimate(diverging).refusal else {
            Issue.record("a growing gap must not produce a time constant")
            return
        }
    }

    /// A first-order system cannot cross its own asymptote. At this amplitude a
    /// sign flip is noise, and dividing by it produces a negative logarithm and
    /// a nonsense τ.
    @Test("A die that overshoots what it was approaching is refused")
    func overshootIsRefused() {
        // Falling, then back up: a first-order system cannot turn around.
        let base = Self.ramp(tau: 75, from: 50, asymptote: 10)
        let overshot = Self.mutate(base, index: 2, die: base[1].dieCelsius + 3)
        guard case .overshot = ThermalTimeConstant.estimate(overshot).refusal else {
            Issue.record("crossing the asymptote must be refused")
            return
        }
    }

    /// The low end: a die that appears to arrive in three seconds means the
    /// three samples straddled something that was not a thermal ramp.
    @Test("A time constant below the plausible band is refused")
    func implausiblyFastIsRefused() {
        guard case .implausible = ThermalTimeConstant.estimate(Self.ramp(tau: 3)).refusal else {
            Issue.record("τ=3 s is not a laptop and must not be reported")
            return
        }
    }

    /// The high end, reached the way it is reached in practice.
    ///
    /// A *clean* ramp slow enough to exceed the bound would have to swing
    /// hundreds of degrees, so it trips ``ThermalTimeConstant/minimumDifferenceCelsius``
    /// first — the noise gate shadows the upper bound for real exponentials.
    /// What actually produces an implausible τ is noise nudging two honest
    /// differences to within a percent of each other, which is why the bound
    /// exists and why this test builds that case directly rather than through
    /// a ramp.
    @Test("Two differences a hair apart give an implausibly slow machine, and are refused")
    func implausiblySlowIsRefused() {
        // −5.00 then −4.95: a ratio of 0.99, which is τ ≈ 995 s.
        let samples = Self.observations(rises: [60, 55, 50.05])
        guard case let .implausible(tau) = ThermalTimeConstant.estimate(samples).refusal else {
            Issue.record("a near-unity ratio must not become a forecast")
            return
        }
        #expect(tau > ThermalTimeConstant.maximumPlausible)
    }

    @Test("The plausible band is ordered")
    func boundsAreOrdered() {
        #expect(ThermalTimeConstant.minimumPlausible < ThermalTimeConstant.maximumPlausible)
    }

    // MARK: - Accumulating

    /// Below the evidence bar there is no answer, however clean the estimates.
    /// One ramp must not set a constant the whole forecast rests on.
    @Test("One good ramp is not enough")
    func belowTheEvidenceBarThereIsNoAnswer() {
        var subject = ThermalTimeConstant()
        Self.feed(&subject, tau: 75, ticks: 175)
        #expect(subject.estimateCount > 0, "the feed must actually produce estimates")
        #expect(subject.estimateCount < ThermalTimeConstant.minimumEstimates)
        #expect(subject.tau == nil)
    }

    @Test("Enough clean estimates produce the time constant they were built from")
    func enoughEstimatesAnswer() throws {
        var subject = ThermalTimeConstant()
        Self.feed(&subject, tau: 75, ticks: 300)
        let tau = try #require(subject.tau, "\(subject.estimateCount) estimates should have been enough")
        #expect(abs(tau - 75) / 75 < 0.05, "recovered \(tau) from a 75 s machine")
    }

    /// The median earning its keep.
    ///
    /// The ways this can be fooled are not symmetric — an interrupted ramp
    /// reads *long*, never short — so a mean would drift toward exactly the
    /// failures the gates cannot all catch.
    ///
    /// The first version of this test was vacuous and **survived swapping the
    /// median for a mean**: it fed the outliers from `epoch`, which is before
    /// the clean run, so the backward-clock guard cleared the buffer and the
    /// twelve poisoned ticks produced no estimates at all. Nothing was ever
    /// poisoned. It now continues the same timeline and feeds enough slow
    /// ticks to move an average.
    @Test("A run of wild estimates cannot move the answer, though it would move a mean")
    func medianResistsOutliers() throws {
        var subject = ThermalTimeConstant()
        Self.feed(&subject, tau: 75, ticks: 380)
        let clean = try #require(subject.tau)
        #expect(abs(clean - 75) / 75 < 0.05)

        // A four-times-slower machine, on the same timeline, inside the
        // plausible band so no gate rejects it. 300 s rather than 500: at a
        // 45 °C swing a 500 s machine moves 0.89 °C per step and trips the
        // noise floor, so it would have produced no estimates at all — the
        // limitation `slowMachineWithSmallSwingIsRefused` pins, met here by
        // accident on the first attempt.
        Self.feed(&subject, tau: 300, ticks: 225, from: Self.epoch.addingTimeInterval(500))
        let poisoned = try #require(subject.tau)
        #expect(abs(poisoned - clean) < 5, "median moved \(clean) → \(poisoned)")
    }

    /// Bounded, because this runs for the life of the app.
    @Test("The estimate buffer stays bounded however long the app runs")
    func estimatesStayBounded() {
        var subject = ThermalTimeConstant()
        Self.feed(&subject, tau: 75, ticks: 3000)
        #expect(subject.estimateCount <= ThermalTimeConstant.maximumEstimates)
    }

    /// Why there is no separate post-load-step settle window.
    ///
    /// One was written and mutation testing proved it deletable. An estimate's
    /// three samples span 20 s, so any triple overlapping a load step contains
    /// samples from both sides of it and the power gate rejects the lot. The
    /// only triples that survive lie entirely after the step — which is the
    /// bias toward the slow pole the extra constant was supposed to provide.
    ///
    /// This pins that, so the redundant gate is not reintroduced by someone
    /// reasoning about the fast pole from first principles.
    @Test("A measurement spanning a load step is refused by the power gate alone")
    func loadStepIsCaughtWithoutASettleWindow() {
        var subject = ThermalTimeConstant()
        // 60 s of steady load, enough to be producing estimates.
        Self.feed(&subject, tau: 75, ticks: 300)
        let before = subject.estimateCount
        #expect(before > 0, "the feed must be producing estimates before the step")

        // The draw halves. Every triple now straddles the step.
        let stepStart = Self.epoch.addingTimeInterval(300)
        for tick in 0 ..< 60 {
            subject.ingest(ThermalTimeConstant.Observation(
                date: stepStart.addingTimeInterval(Double(tick)),
                dieCelsius: 70 - Double(tick) * 0.4,
                ambientCelsius: 40,
                watts: 18,
                fanFraction: 0.5
            ))
        }
        #expect(subject.estimateCount == before, "a triple across a load step must produce nothing")
        guard case .powerMoved = subject.lastRefusal else {
            Issue.record("expected powerMoved, got \(String(describing: subject.lastRefusal))")
            return
        }
    }

    /// Same failure `CoolingEfficiency.Tracker` documents: a sample dated after
    /// the newest sits where an age-only trim can never reach it, and the
    /// buffer wedges for the life of the process.
    @Test("A backward clock step cannot wedge the estimator permanently")
    func backwardClockRecovers() {
        var subject = ThermalTimeConstant()
        Self.feed(&subject, tau: 75, ticks: 300)
        #expect(subject.tau != nil)

        var rewound = subject
        rewound.ingest(ThermalTimeConstant.Observation(
            date: Self.epoch.addingTimeInterval(-86400),
            dieCelsius: 70, ambientCelsius: 40, watts: 30, fanFraction: 0.5
        ))
        // The buffer resets, but the estimates already earned survive, and the
        // stream recovers rather than jamming.
        Self.feed(&rewound, tau: 75, ticks: 300, from: Self.epoch.addingTimeInterval(-86400))
        #expect(rewound.tau != nil, "the estimator must recover after a clock step")
    }

    // MARK: - Helpers

    /// Drives the estimator with a machine whose work comes in stretches,
    /// one tick per second.
    ///
    /// Alternates between an idle and a busy draw every `stretch` seconds, and
    /// lets the die chase each new equilibrium. That shape matters: a single
    /// endless ramp would decay under the noise gate and stop producing
    /// estimates, and a machine that never changes load is a machine with no
    /// transients to learn from.
    private static func feed(
        _ subject: inout ThermalTimeConstant,
        tau: TimeInterval,
        ticks: Int,
        stretch: Int = 400, // must outlast a triple's 180 s span
        from start: Date = epoch
    ) {
        let ambient = 40.0
        var rise = 5.0 // starts cold, so the first stretch is a full ramp
        for tick in 0 ..< ticks {
            let busy = (tick / stretch) % 2 == 0 // start under load: an idle machine has no transient
            let target = busy ? 50.0 : 5.0
            rise = target + (rise - target) * exp(-1 / tau)
            subject.ingest(ThermalTimeConstant.Observation(
                date: start.addingTimeInterval(Double(tick)),
                dieCelsius: ambient + rise,
                ambientCelsius: ambient,
                watts: busy ? 45 : 12,
                fanFraction: 0.5
            ))
        }
    }

    private static func estimate(_ samples: [ThermalTimeConstant.Observation]) throws -> TimeInterval {
        switch ThermalTimeConstant.estimate(samples) {
        case let .success(tau): tau
        case let .failure(refusal): throw RefusedUnexpectedly(refusal: refusal)
        }
    }

    private struct RefusedUnexpectedly: Error {
        let refusal: ThermalTimeConstant.Refusal
    }
}

private extension ThermalTimeConstant.Observation {
    static let startOfTime = Date(timeIntervalSince1970: 1_753_000_000)
}

private extension Result where Success == TimeInterval, Failure == ThermalTimeConstant.Refusal {
    var refusal: ThermalTimeConstant.Refusal? {
        if case let .failure(refusal) = self {
            refusal
        } else {
            nil
        }
    }
}
