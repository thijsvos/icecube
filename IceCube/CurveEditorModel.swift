// CurveEditorModel.swift — editing state for one fan curve: points with live monotonic constraints.

import IceCubeKit
import Observation

/// Editing state for one curve: points with live constraints.
@Observable
final class CurveEditorModel {
    var points: [CurvePoint]
    var selected: Int?
    var hysteresis: Double = 4
    var ramp: Double = 0.1

    /// Preview follower so the "applied" marker shows hysteresis + ramp even
    /// in simulated mode (Phase 4 acceptance is demonstrable without root).
    @ObservationIgnored private var preview = CurveFollower()
    private(set) var previewFraction: Double = 0

    init(curve: FanCurve = .balanced) {
        points = curve.points
    }

    var curve: FanCurve {
        FanCurve(points: points)
    }

    func load(_ curve: FanCurve) {
        points = curve.points
        selected = nil
        preview.reset()
    }

    /// Moves point `index` respecting monotonic-x and non-decreasing-y —
    /// live clamping beats "snap back on release".
    func move(_ index: Int, to raw: CurvePoint) {
        guard points.indices.contains(index) else { return }
        let lowerX = index > 0 ? points[index - 1].celsius + 1 : 30
        let upperX = index < points.count - 1 ? points[index + 1].celsius - 1 : 110
        let lowerY = index > 0 ? points[index - 1].fraction : 0
        let upperY = index < points.count - 1 ? points[index + 1].fraction : 1
        points[index] = CurvePoint(
            celsius: raw.celsius.clamped(to: lowerX ... max(lowerX, upperX)),
            // max() on the upper bound: a ClosedRange traps on inverted
            // bounds where the old min(max()) silently returned upperY.
            fraction: raw.fraction.clamped(to: lowerY ... max(lowerY, upperY))
        )
    }

    /// Adds a point at the location (max 8), returns its index.
    @discardableResult
    func addPoint(at point: CurvePoint) -> Int? {
        guard points.count < 8 else { return nil }
        let index = points.firstIndex { $0.celsius > point.celsius } ?? points.count
        points.insert(point, at: index)
        move(index, to: point) // apply constraints
        selected = index
        return index
    }

    /// Removes the selected point (minimum 3 remain).
    func removeSelected() {
        guard let selected, points.count > 3, points.indices.contains(selected) else { return }
        points.remove(at: selected)
        self.selected = nil
    }

    func nudgeSelected(dCelsius: Double, dFraction: Double) {
        guard let selected, points.indices.contains(selected) else { return }
        let p = points[selected]
        move(selected, to: CurvePoint(celsius: p.celsius + dCelsius, fraction: p.fraction + dFraction))
    }

    /// Advances the preview marker with a fresh temperature reading.
    func updatePreview(die: Double) {
        var follower = preview
        follower.hysteresisCelsius = hysteresis
        follower.rampUpPerTick = ramp
        follower.rampDownPerTick = ramp * 0.5
        previewFraction = follower.step(dieCelsius: die, curve: curve)
        preview = follower
    }
}
