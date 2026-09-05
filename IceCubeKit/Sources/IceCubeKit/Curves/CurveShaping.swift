// CurveShaping.swift — turning a requirement into a curve a controller can actually follow.

import Foundation

/// The three passes between "what the measurements demand" and "what goes in
/// the editor".
///
/// Split from ``CurveDerivation`` because they answer a different question.
/// `derive` asks *what does this Mac need?* and produces a lower bound. These
/// ask *what shape of curve meets that bound and can still be followed, in
/// eight points or fewer?* — and every one of them exists because the honest
/// answer to the first question, handed straight to a `FanCurve`, was unusable:
///
/// - ``limitSteepness(_:)`` — the bound's optimum is bang-bang, and the daemon
///   follows curves through a 4 °C deadband.
/// - ``thin(_:to:)`` — `FanCurve.normalized` caps at eight points with
///   `prefix(8)`, which keeps the coolest eight and deletes the ramp to full
///   fans.
/// - ``repair(_:meeting:)`` — thinning replaces a corner with the chord under
///   it, which is the one way a derived curve could quietly under-promise.
///
/// All three only ever move fan speed **up**. That is what keeps the promise
/// through the shaping: a curve above the requirement still holds the target.
extension CurveDerivation {
    // MARK: - Followable

    /// Caps how fast the curve may climb, by raising the cooler points.
    ///
    /// Walks from the hot end down, because the hot end is where the
    /// requirement is real: the fan speed the heaviest measured load needs is
    /// not negotiable, so everything cooler moves up to meet it at a gradient
    /// a controller can follow. Never lowers a point — see
    /// ``maximumFractionPerCelsius`` for why that is what keeps the promise.
    static func limitSteepness(_ points: [CurvePoint]) -> [CurvePoint] {
        var shaped = points.sorted { $0.celsius < $1.celsius }
        for index in shaped.indices.dropLast().reversed() {
            let above = shaped[index + 1]
            let span = above.celsius - shaped[index].celsius
            guard span > 0 else { continue }
            let floor = above.fraction - maximumFractionPerCelsius * span
            if shaped[index].fraction < floor {
                shaped[index].fraction = floor.clamped(to: 0 ... 1)
            }
        }
        return shaped
    }

    /// Raises points until the curve clears every requirement again.
    ///
    /// Thinning drops a point by replacing it with the straight line through
    /// its neighbours, and where that line runs *under* the point it deleted,
    /// the curve now commands less fan than the measurement asked for. The
    /// deviation is small by construction — `thin` always drops the smallest
    /// one — but "small" is not "none", and this is the one place a derived
    /// curve could quietly under-promise.
    ///
    /// The repair raises the **cooler** end of the segment a violated
    /// requirement falls in. A `FanCurve` is non-decreasing, so a point at or
    /// below `T` carrying the required fraction guarantees the curve carries
    /// at least that much *at* `T`. This can locally exceed
    /// ``maximumFractionPerCelsius``; more fan sooner is the safe direction,
    /// and it only happens where thinning had already flattened a real corner.
    static func repair(_ points: [CurvePoint], meeting required: [CurvePoint]) -> [CurvePoint] {
        var kept = points
        for need in required {
            let curve = FanCurve(points: kept)
            guard curve.fraction(at: need.celsius) < need.fraction else { continue }
            guard let index = kept.lastIndex(where: { $0.celsius <= need.celsius }) else { continue }
            kept[index].fraction = need.fraction
        }
        return kept
    }

    // MARK: - Thinning

    /// Thins a point list to `limit`, keeping the ends and the corners.
    ///
    /// Repeatedly drops the interior point the curve misses least — the one
    /// whose fan speed is closest to the straight line through its neighbours.
    ///
    /// **`FanCurve.normalized` cannot do this job**, even though it also caps
    /// at eight: it caps with `prefix(8)`, which keeps the *coolest* eight
    /// points and throws the hot end away. Handing it a fourteen-point sweep
    /// would silently delete the ramp to full fans and leave a curve that tops
    /// out wherever the eighth point happened to sit.
    static func thin(_ points: [CurvePoint], to limit: Int) -> [CurvePoint] {
        var kept = points.sorted { $0.celsius < $1.celsius }
        while kept.count > limit, kept.count > 2 {
            var dropIndex = 1
            var smallest = Double.infinity
            for index in 1 ..< (kept.count - 1) {
                let before = kept[index - 1]
                let point = kept[index]
                let after = kept[index + 1]
                let span = after.celsius - before.celsius
                let interpolated = span > 0
                    ? before.fraction
                    + (point.celsius - before.celsius) / span * (after.fraction - before.fraction)
                    : point.fraction
                let error = abs(point.fraction - interpolated)
                if error < smallest {
                    smallest = error
                    dropIndex = index
                }
            }
            kept.remove(at: dropIndex)
        }
        return kept
    }
}
