// CurveEditorModel.swift — editing state for one fan curve: points with live monotonic constraints.

import IceCubeKit
import Observation

/// Editing state for one curve: points with live constraints.
@Observable
final class CurveEditorModel {
    var points: [CurvePoint]
    var selected: Int?
    /// Both sliders count as taking the wheel — see ``hasUserEdits``.
    var hysteresis: Double = 4 {
        didSet { hasUserEdits = true }
    }

    var ramp: Double = 0.1 {
        didSet { hasUserEdits = true }
    }

    /// Whether the user has changed anything in this editor.
    ///
    /// The editor follows the running curve until this flips, and never after
    /// (see ``follow(_:)``). Anything the user does to the curve counts —
    /// dragging, adding, removing, nudging, moving a slider, or loading a
    /// preset by name. Seeding does not: adopting the running curve is the
    /// editor agreeing with the machine, not the user disagreeing with it.
    private(set) var hasUserEdits = false

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

    /// Loads a curve the user asked for by name — a preset from the Load row.
    /// That is a deliberate choice, so it stops the editor following.
    func load(_ curve: FanCurve) {
        points = curve.points
        selected = nil
        preview.reset()
        hasUserEdits = true
    }

    /// Opens the editor on a curve that is already running, parameters and all.
    ///
    /// Delegates the points to ``load(_:)`` rather than assigning them here:
    /// that method's `preview.reset()` is the whole reason this file has tests,
    /// and a second copy of the load path is a second place to forget it. The
    /// edit flags both of them raise are cleared afterwards — the machine
    /// telling the editor what it is running is not the user editing anything.
    func load(_ seed: CurveEditorSeed.Seed) {
        load(seed.curve)
        hysteresis = seed.hysteresisCelsius
        ramp = seed.rampPerTick
        hasUserEdits = false
    }

    /// Adopts the running curve **if the editor is still following it**.
    ///
    /// The trigger this replaces was "seed once, when the window appears", and
    /// it did not survive contact with the real app: measured on the owner's
    /// Mac, a window opened after four presets had been applied still showed
    /// Balanced. Appearance is the wrong event — a `Window` scene's content can
    /// outlive the window being shut (nothing tears it down when the window is
    /// merely raised, and `WindowOpener.closableFromMenuBar` deliberately never
    /// closes this one), so "on appear" can mean "once, at launch, before the
    /// app knew anything", and then never again.
    ///
    /// So the editor follows instead: whenever the daemon's report changes, it
    /// adopts what is running — until the user touches something, after which
    /// it is their workbench and nothing overwrites it.
    ///
    /// - Returns: whether anything changed, so the caller can log the decision
    ///   rather than guess at it.
    @discardableResult
    func follow(_ seed: CurveEditorSeed.Seed) -> Bool {
        guard !hasUserEdits else { return false }
        // Already showing it: reloading would reset the preview follower on
        // every status refresh, which the user sees as the marker jumping.
        guard curve != seed.curve
            || hysteresis != seed.hysteresisCelsius
            || ramp != seed.rampPerTick
        else { return false }
        load(seed)
        return true
    }

    /// Moves point `index` respecting monotonic-x and non-decreasing-y —
    /// live clamping beats "snap back on release".
    func move(_ index: Int, to raw: CurvePoint) {
        guard points.indices.contains(index) else { return }
        hasUserEdits = true
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
        hasUserEdits = true
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
