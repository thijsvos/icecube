// CurveEditorSeedTests.swift — the editor opens on the curve the daemon is running, not on a default.

import IceCubeKit
import Testing

/// Same reason as `CurveApplyPolicyTests`: every input here comes from a live
/// daemon, so simulated mode reaches none of it and the rules would otherwise
/// only ever run on the owner's Mac — where a wrong answer looks like a curve
/// the app forgot rather than like a bug.
@Suite("CurveEditorSeed — what the editor opens on")
@MainActor
struct CurveEditorSeedTests {
    /// Deliberately not any of the built-ins: a seed that quietly fell back to
    /// `.balanced` would pass a test written against `.balanced`.
    private let drawn = FanCurve(points: [
        CurvePoint(celsius: 45, fraction: 0.1),
        CurvePoint(celsius: 65, fraction: 0.45),
        CurvePoint(celsius: 85, fraction: 0.9),
    ])

    private func status(mode: FanConfig.Mode, curve: FanCurve? = nil) -> HelperStatus {
        HelperStatus(mode: mode, activeCurve: curve)
    }

    // MARK: - The daemon's report wins

    /// The precedence `PresetHighlight.isActive` sets, applied here: a curve the
    /// daemon resumed at boot is on the fans right now, whatever this app
    /// remembers sending.
    @Test("The curve the daemon is running beats the one the app remembers sending")
    func daemonBeatsMemory() {
        let seed = CurveEditorSeed.seed(
            enforced: status(mode: .curve, curve: drawn),
            applied: FanConfig.curve(.quiet, persists: false)
        )
        #expect(seed?.curve == drawn)
    }

    @Test("Parameters come from the applied config when it describes that same curve")
    func parametersFollowTheirOwnCurve() {
        var applied = FanConfig.curve(drawn, persists: false)
        applied.hysteresisCelsius = 7
        applied.rampPerTick = 0.25
        let seed = CurveEditorSeed.seed(enforced: status(mode: .curve, curve: drawn), applied: applied)
        #expect(seed == CurveEditorSeed.Seed(curve: drawn, hysteresisCelsius: 7, rampPerTick: 0.25))
    }

    /// The quiet lie this guards against: a boot-resumed curve shown with the
    /// hysteresis of whatever this app last applied to something else.
    @Test("A curve the app never sent gets the defaults, not another curve's smoothing")
    func parametersAreNotBorrowed() {
        var applied = FanConfig.curve(.quiet, persists: false)
        applied.hysteresisCelsius = 7
        applied.rampPerTick = 0.25
        let seed = CurveEditorSeed.seed(enforced: status(mode: .curve, curve: drawn), applied: applied)
        #expect(seed == CurveEditorSeed.Seed(curve: drawn, hysteresisCelsius: 4, rampPerTick: 0.1))
    }

    // MARK: - Falling back to what we sent

    @Test("With no live status, the editor opens on the config the app last sent")
    func noStatusUsesApplied() {
        var applied = FanConfig.curve(drawn, persists: false)
        applied.hysteresisCelsius = 6
        let seed = CurveEditorSeed.seed(enforced: nil, applied: applied)
        #expect(seed == CurveEditorSeed.Seed(curve: drawn, hysteresisCelsius: 6, rampPerTick: 0.1))
    }

    /// `HelperStatus.activeCurve` is optional so a daemon that predates it
    /// decodes to nil instead of failing the handshake — which means "curve
    /// mode, no curve named" is a state this really has to handle.
    @Test("A daemon too old to name its curve falls back to the app's memory")
    func curveModeWithoutAnActiveCurve() {
        let seed = CurveEditorSeed.seed(
            enforced: status(mode: .curve),
            applied: FanConfig.curve(drawn, persists: false)
        )
        #expect(seed?.curve == drawn)
    }

    // MARK: - Nothing to open on

    /// Manual and auto name no curve, and neither does a fresh install. The
    /// editor's own Balanced default is the honest answer, so the seed declines
    /// rather than inventing one.
    @Test("Modes that name no curve leave the editor's default alone", arguments: [
        FanConfig.Mode.manual, .auto,
    ])
    func modesWithoutACurve(mode: FanConfig.Mode) {
        #expect(CurveEditorSeed.seed(enforced: status(mode: mode), applied: FanConfig(mode: mode)) == nil)
    }

    @Test("A machine that has applied nothing seeds nothing")
    func nothingKnown() {
        #expect(CurveEditorSeed.seed(enforced: nil, applied: nil) == nil)
    }

    /// A curve with too few points cannot be dragged or applied; opening the
    /// editor on one would produce a window whose Apply button is dead.
    @Test("An unusable curve is refused from either source")
    func unusableCurveIsRefused() {
        let stub = FanCurve(points: [CurvePoint(celsius: 50, fraction: 0.5)])
        #expect(CurveEditorSeed.seed(enforced: status(mode: .curve, curve: stub), applied: nil) == nil)
        #expect(CurveEditorSeed.seed(enforced: nil, applied: FanConfig.curve(stub, persists: false)) == nil)
    }
}
