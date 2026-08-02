// CurveFollowerSafetyTests.swift — what the follower does with hostile input, on the path that sets fan RPM.

import Foundation
@testable import IceCubeKit
import Testing

/// The two `CurveFollower` behaviours nothing pinned.
///
/// `CurveTests` covers the three stages of `step()` well — deadband, ramp,
/// smoothing — but every one of its cases feeds sane numbers through a
/// well-formed follower. These are the paths a *broken* input takes, and they
/// are on the code that decides how fast the fans spin.
///
/// Coverage pointed here, then lied about the size of it: five of nine
/// functions measured unexecuted, but four are synthesized `==` and
/// default-argument thunks. The real gaps are below.
@Suite("CurveFollower — hostile input")
struct CurveFollowerSafetyTests {
    private let curve = FanCurve.balanced

    /// **This one documents an asymmetry rather than asserting a fix.**
    ///
    /// `FanCurve.fraction(at:)` deliberately fails *hot* on a non-finite
    /// reading — a blind sensor should not be a quiet one. `CurveFollower` is
    /// the single place on that path which fails *cold*: on the very first
    /// tick `smoothedTemp` and `output` are both nil, so `output ?? 0` commands
    /// 0.0, the coldest fraction there is.
    ///
    /// `CurveTests.nonFiniteInput` cannot see this — it feeds a good 80 °C tick
    /// first, which populates `smoothedTemp` so the guard never fires with an
    /// empty follower. Pinned as-is: changing it is a behaviour decision for
    /// the owner, and an unpinned asymmetry is how it stays invisible.
    @Test("A NaN on the very first tick commands zero, not maximum")
    func firstTickNaNFailsCold() {
        var follower = CurveFollower(hysteresisCelsius: 2, rampUpPerTick: 0.1)
        let output = follower.step(dieCelsius: Double.nan, curve: curve)
        #expect(
            output == 0,
            "documented asymmetry: FanCurve fails hot on non-finite input, the follower's first tick fails cold"
        )
    }

    /// A follower that has seen one good reading holds it rather than falling
    /// to zero — the difference between the case above and every later tick.
    @Test("A NaN after a good reading holds the last output instead of dropping to zero")
    func laterNaNHolds() {
        var follower = CurveFollower(hysteresisCelsius: 2, rampUpPerTick: 1)
        let warm = follower.step(dieCelsius: 80, curve: curve)
        #expect(warm > 0)
        #expect(
            follower.step(dieCelsius: Double.nan, curve: curve) == warm,
            "a glitched reading must not change the fans"
        )
    }

    /// The safety-relevant one, and it has to start **cold**.
    ///
    /// `step` takes the curve's demand directly on the first tick — "start at
    /// demand, no artificial ramp-up" — so a follower that opens at 90 °C is
    /// already at its target and the ramp governs nothing. The clamp is only
    /// observable while the output has somewhere to climb to. The first version
    /// of this test started hot and passed against a follower with the clamp
    /// deleted, which is precisely why mutation testing is in the verification
    /// list rather than assumed.
    ///
    /// `rampUpPerTick` is floored at 0.01 in `init`. A zero arriving from a
    /// hand-edited or mis-decoded `FanConfig` would mean the output can never
    /// rise — the fans holding idle while the die climbs.
    @Test("A zero ramp is floored, so a sustained hot die still moves the fans")
    func zeroRampCannotFreezeTheFans() {
        var follower = CurveFollower(
            hysteresisCelsius: 0, rampUpPerTick: 0, rampDownPerTick: 0, smoothingAlpha: 1
        )
        let cold = follower.step(dieCelsius: 30, curve: curve)

        var last = cold
        for _ in 0 ..< 500 {
            let next = follower.step(dieCelsius: 95, curve: curve)
            #expect(next >= last, "output must never fall while the die stays hot")
            last = next
        }
        #expect(last > cold, "a zero ramp must not pin the fans at idle on a 95 °C die")
    }

    /// The same property for `smoothingAlpha`, floored the same way.
    ///
    /// The EMA is `smoothed += alpha * (reading - smoothed)`. At alpha 0 the
    /// smoothed temperature never leaves its first value, so the follower goes
    /// permanently deaf: the die could climb from 30 °C to 100 °C and the fans
    /// would never hear about it.
    @Test("A zero smoothing alpha is floored, so the follower cannot go permanently deaf")
    func zeroAlphaCannotFreezeTheInput() {
        var follower = CurveFollower(
            hysteresisCelsius: 0, rampUpPerTick: 1, rampDownPerTick: 1, smoothingAlpha: 0
        )
        let cold = follower.step(dieCelsius: 30, curve: curve)
        var last = cold
        for _ in 0 ..< 500 {
            last = follower.step(dieCelsius: 95, curve: curve)
        }
        #expect(last > cold, "a zero alpha must not freeze the smoothed temperature at its first reading")
    }

    /// Negative and absurd tuning is clamped rather than trusted, and the
    /// assertion is the same convergence property: whatever nonsense the config
    /// carries, a die held at 95 °C must still end up moving the fans.
    ///
    /// **Mutation testing showed the clamp is load-bearing for more than
    /// responsiveness.** Delete `.clamped(to: 0.01 ... 1)` from `rampUpPerTick`
    /// and this case does not merely fail — the process dies with
    /// `Fatal error: Range requires lowerBound <= upperBound`, because a
    /// negative ramp makes `-limit ... limit` an invalid `ClosedRange` inside
    /// `step`. That clamp is the only thing standing between a malformed
    /// `FanConfig` arriving over XPC and a daemon crash, which CLAUDE.md
    /// forbids outright ("never `fatalError` in daemon code paths").
    ///
    /// Worth knowing that this catch shows up as a crashed suite rather than a
    /// tidy failure line: exit code 1, no completion line, no `✘`.
    @Test(
        "Out-of-range tuning is clamped, not honoured",
        arguments: [
            (-5.0, -1.0, 5.0),
            (0.0, 0.0, 0.0),
            // A huge hysteresis is deliberately NOT in this list — see
            // `wideDeadbandMakesTheFollowerInert` below, which is why.
            (3.0, 99.0, 99.0),
        ]
    )
    func hostileTuningIsClamped(hysteresis: Double, ramp: Double, alpha: Double) {
        var follower = CurveFollower(
            hysteresisCelsius: hysteresis,
            rampUpPerTick: ramp,
            rampDownPerTick: ramp,
            smoothingAlpha: alpha
        )
        let cold = follower.step(dieCelsius: 30, curve: curve)
        var last = cold
        for _ in 0 ..< 500 {
            last = follower.step(dieCelsius: 95, curve: curve)
            #expect(last.isFinite, "clamping must not produce NaN or infinity")
            #expect(last >= 0 && last <= 1, "output must stay a valid fraction")
        }
        #expect(last > cold, "however hostile the tuning, a sustained hot die must still move the fans")
    }

    /// **A gap this suite found, recorded rather than fixed.**
    ///
    /// `init` clamps `hysteresisCelsius` with `max(0, …)` — a lower bound only.
    /// There is no upper bound, so a deadband wider than the temperature range
    /// the machine actually moves through makes the follower permanently inert:
    /// `effectiveTemp` never updates, and the output stays wherever the first
    /// tick put it while the die climbs.
    ///
    /// Not a thermal hazard — `SafetyMonitor`'s ceiling and `FanGuardian` both
    /// sit downstream of this and are unaffected — but it is the one tuning
    /// value that can silently disable a curve. Deliberately pinned as-is:
    /// adding an upper clamp changes fan-control behaviour, which is the
    /// owner's call and not a side effect of writing tests.
    @Test("A deadband wider than the die's whole range leaves the fans where they started")
    func wideDeadbandMakesTheFollowerInert() {
        var follower = CurveFollower(
            hysteresisCelsius: 100, rampUpPerTick: 1, rampDownPerTick: 1, smoothingAlpha: 1
        )
        let cold = follower.step(dieCelsius: 30, curve: curve)
        var last = cold
        for _ in 0 ..< 500 {
            last = follower.step(dieCelsius: 95, curve: curve)
        }
        #expect(
            last == cold,
            "documenting today's behaviour: hysteresis has no upper clamp, so a 100 °C deadband is inert"
        )
    }

    /// `reset()` is never called by the daemon — it clears its follower
    /// dictionary instead — so it is exercised only through the app's curve
    /// preview. Pinned here so the Kit owns its own contract.
    @Test("Reset returns the follower to its first-tick state")
    func resetClearsHistory() {
        var follower = CurveFollower(hysteresisCelsius: 2, rampUpPerTick: 0.1)
        _ = follower.step(dieCelsius: 90, curve: curve)
        follower.reset()
        #expect(follower.step(dieCelsius: Double.nan, curve: curve) == 0, "after reset there is no last output to hold")
    }
}
