// CurveEditorSeed.swift — which curve the editor opens on: the one the fans are actually running.

import IceCubeKit

/// What the curve editor should be showing when it opens.
///
/// It used to open on `FanCurve.balanced` unconditionally, which was tolerable
/// while the window stayed put after an Apply and merely odd on the next
/// launch. It stopped being tolerable when Apply began closing the window
/// (``CurveApplyPolicy``): SwiftUI tears a `Window` scene's content down on
/// close — the same fact `WindowOpener` records about the settings tab — so
/// apply-then-reopen showed Balanced while the fans ran the curve the user had
/// just drawn. The editor was asserting something false about the machine, and
/// the natural reading of that is "the app forgot my curve".
///
/// The precedence is copied from `PresetHighlight.isActive`, deliberately and
/// for its stated reason: **the daemon's report beats the app's memory**,
/// because the truth about what is enforced lives in the daemon and the app's
/// memory is a cache of it. `HelperStatus.activeCurve` exists for this exact
/// job — it was added so a curve the daemon resumed at boot, before the app
/// existed, could still light a preset button.
///
/// Pure, and in the app test bundle, for ``CurveApplyPolicy``'s reason: every
/// input here comes from a live daemon, so simulated mode reaches none of it
/// (no connection, no status, no applied config) and the whole type would
/// otherwise only ever run on the owner's Mac.
enum CurveEditorSeed {
    /// A curve plus the two parameters that shape how it is followed. Carried
    /// together because separating them is how the editor would come to show
    /// one curve's points beside another curve's smoothing.
    struct Seed: Equatable {
        var curve: FanCurve
        var hysteresisCelsius: Double
        var rampPerTick: Double
    }

    /// The curve to open on, or `nil` to keep the editor's own default.
    ///
    /// `nil` covers manual mode, auto, and a machine that has never applied
    /// anything — none of which name a curve, and all of which are honestly
    /// answered by the Balanced default the editor already starts from.
    ///
    /// - Parameters:
    ///   - enforced: the daemon's own report, or `nil` with no live connection.
    ///   - applied: the last config this app sent, as `HelperManager` keeps it
    ///     — already reconciled against the daemon by `reconcileHighlight`.
    static func seed(enforced: HelperStatus?, applied: FanConfig?) -> Seed? {
        // The daemon names the curve it is running, which settles it outright,
        // including for a curve this app never sent.
        if enforced?.mode == .curve, let active = enforced?.activeCurve, active.isUsable {
            // The parameters come from `applied` only when it describes THIS
            // curve. A boot-resumed profile the app never sent has no business
            // borrowing the hysteresis of whatever this app last applied; the
            // defaults are the honest answer, and they are the editor's
            // defaults and `FanConfig`'s alike.
            let follow = parameters(matching: active, in: applied)
            return Seed(curve: active, hysteresisCelsius: follow.hysteresis, rampPerTick: follow.ramp)
        }
        // No live status, or a daemon old enough to predate `activeCurve` —
        // the field is optional precisely so such a peer decodes to nil rather
        // than failing. Fall back to what this app last sent.
        guard let applied, applied.mode == .curve, let curve = applied.sharedCurve, curve.isUsable
        else { return nil }
        return Seed(
            curve: curve,
            hysteresisCelsius: applied.hysteresisCelsius,
            rampPerTick: applied.rampPerTick
        )
    }

    /// The follow parameters for `curve`, taken from `applied` only when that
    /// config is about the same curve — otherwise `FanConfig`'s own defaults.
    private static func parameters(
        matching curve: FanCurve, in applied: FanConfig?
    ) -> (hysteresis: Double, ramp: Double) {
        guard let applied, applied.sharedCurve == curve else {
            let defaults = FanConfig(mode: .curve)
            return (defaults.hysteresisCelsius, defaults.rampPerTick)
        }
        return (applied.hysteresisCelsius, applied.rampPerTick)
    }
}
