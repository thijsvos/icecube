// CurveEditorModelTests.swift — the curve editor's constraint machine: monotonic clamping, add/remove limits, preview
// state.

import IceCubeKit
import Testing

/// The first tests any **app-side** code has ever had.
///
/// `CurveEditorModel.swift` is compiled into this bundle rather than imported
/// from Ice Cube.app — see the note on the `IceCubeTests` target in project.yml
/// for why hosting a menu-bar app under XCTest does not work.
///
/// They exist because coverage pointed here: `CurveFollower.reset()` measured 0 %
/// in IceCubeKit, and it is not dead code — its only caller is
/// `CurveEditorModel.load(_:)`, which lives on the app side where nothing could
/// be tested. Two real bugs this session were caught by hand for the same
/// reason, and the RPM formatter had to be relocated into IceCubeKit before it
/// could carry a regression test at all.
@Suite("CurveEditorModel — the editor's constraint machine")
@MainActor
struct CurveEditorModelTests {
    /// Three points, widely spaced, so a test can move the middle one in any
    /// direction without immediately hitting a neighbour.
    private func model() -> CurveEditorModel {
        CurveEditorModel(curve: FanCurve(points: [
            CurvePoint(celsius: 40, fraction: 0.0),
            CurvePoint(celsius: 60, fraction: 0.5),
            CurvePoint(celsius: 90, fraction: 1.0),
        ]))
    }

    // MARK: - Loading a curve

    /// The reason this test target exists. `load()` swaps the points out from
    /// under the preview follower, so the follower's smoothing, deadband and
    /// ramp state all describe a curve that is no longer on screen. Without the
    /// reset the marker keeps ramping from wherever the *previous* curve left
    /// it, which reads as the editor lying about what the new curve does.
    @Test("Loading a curve resets the preview, so it can't inherit the old curve's ramp")
    func loadResetsPreview() {
        let editor = model()
        // Drive the preview up to a high fraction on a curve that demands it.
        for _ in 0 ..< 40 {
            editor.updatePreview(die: 95)
        }
        #expect(editor.previewFraction > 0.5, "setup: preview should have ramped up")

        // A curve that demands nothing at the same temperature.
        editor.load(FanCurve(points: [
            CurvePoint(celsius: 40, fraction: 0),
            CurvePoint(celsius: 110, fraction: 0),
        ]))
        editor.updatePreview(die: 95)

        // With the follower reset, the first tick starts AT demand rather than
        // ramping down from the old output — see CurveFollower.step's
        // "first tick: start at demand, no artificial ramp-up".
        #expect(editor.previewFraction == 0)
    }

    @Test("Loading a curve adopts its points and clears the selection")
    func loadReplacesPoints() {
        let editor = model()
        editor.selected = 1
        editor.load(.quiet)
        #expect(editor.points == FanCurve.quiet.points)
        #expect(editor.selected == nil)
    }

    /// Opening the editor on a running curve has to bring the parameters with
    /// it — points alone would show the right shape being followed with the
    /// wrong smoothing — and it must go through `load(_:)` so the preview
    /// follower is reset like any other curve change.
    @Test("Seeding takes the curve, the hysteresis and the ramp, and resets the preview")
    func loadSeedAdoptsParameters() {
        let editor = model()
        for _ in 0 ..< 40 {
            editor.updatePreview(die: 95)
        }
        #expect(editor.previewFraction > 0.5, "setup: preview should have ramped up")

        editor.load(CurveEditorSeed.Seed(
            curve: FanCurve(points: [
                CurvePoint(celsius: 40, fraction: 0),
                CurvePoint(celsius: 110, fraction: 0),
            ]),
            hysteresisCelsius: 7,
            rampPerTick: 0.25
        ))
        editor.updatePreview(die: 95)

        #expect(editor.hysteresis == 7)
        #expect(editor.ramp == 0.25)
        #expect(editor.previewFraction == 0, "the follower must be reset, as in load(_ curve:)")
        #expect(!editor.hasUserEdits, "the machine naming its curve is not the user editing one")
    }

    // MARK: - follow(): the editor tracks the running curve until it is touched

    private func seed(_ curve: FanCurve) -> CurveEditorSeed.Seed {
        CurveEditorSeed.Seed(curve: curve, hysteresisCelsius: 4, rampPerTick: 0.1)
    }

    /// The bug this replaced a one-shot with: on the owner's Mac, an editor
    /// opened after four presets had been applied still showed Balanced,
    /// because "on appear" had already fired — once, at launch, before the app
    /// knew anything — and never fired again.
    @Test("An untouched editor adopts the running curve, however late it arrives")
    func followAdoptsWhileUntouched() {
        let editor = model()
        #expect(editor.follow(seed(.max)))
        #expect(editor.points == FanCurve.max.points)
        // And again when the machine moves on to another curve.
        #expect(editor.follow(seed(.quiet)))
        #expect(editor.points == FanCurve.quiet.points)
    }

    @Test("Following the curve already on screen changes nothing", arguments: [true, false])
    func followIsIdempotent(sameParameters: Bool) {
        let editor = model()
        editor.follow(seed(.max))
        let shown = editor.points
        var again = seed(.max)
        if !sameParameters {
            again.hysteresisCelsius = 6
        }
        // A no-op returns false so the caller can say so; a changed parameter
        // is a real difference and must be adopted.
        #expect(editor.follow(again) == !sameParameters)
        #expect(editor.points == shown)
        #expect(editor.hysteresis == (sameParameters ? 4 : 6))
    }

    /// The whole safety of making this a subscription: a status refresh every
    /// few seconds must never overwrite a curve someone is drawing.
    @Test("Anything the user does stops the editor following", arguments: [
        "drag", "add", "remove", "nudge", "hysteresis", "ramp", "preset",
    ])
    func userEditsStopFollowing(action: String) {
        let editor = model()
        editor.follow(seed(.max))
        #expect(!editor.hasUserEdits, "setup: following must not count as an edit")

        switch action {
        case "drag": editor.move(0, to: CurvePoint(celsius: 50, fraction: 0.2))
        case "add": editor.addPoint(at: CurvePoint(celsius: 55, fraction: 0.4))
        case "remove":
            editor.addPoint(at: CurvePoint(celsius: 55, fraction: 0.4))
            editor.addPoint(at: CurvePoint(celsius: 75, fraction: 0.8))
            editor.selected = 1
            editor.removeSelected()
        case "nudge":
            editor.selected = 0
            editor.nudgeSelected(dCelsius: 1, dFraction: 0)
        case "hysteresis": editor.hysteresis = 6
        case "ramp": editor.ramp = 0.2
        default: editor.load(.cold)
        }
        #expect(editor.hasUserEdits)

        let drawn = editor.points
        #expect(editor.follow(seed(.quiet)) == false)
        #expect(editor.points == drawn, "a status refresh must not overwrite the user's curve")
    }

    // MARK: - move(): the monotonic invariant

    @Test("A point dragged past its neighbours is clamped between them")
    func moveClampsBetweenNeighbours() {
        let editor = model()
        // Drag the middle point far below the first and far left of it.
        editor.move(1, to: CurvePoint(celsius: 10, fraction: -5))
        #expect(editor.points[1].celsius == 41, "must stay 1 °C right of its left neighbour")
        #expect(editor.points[1].fraction == 0.0, "must not fall below its left neighbour")

        // And the other way.
        editor.move(1, to: CurvePoint(celsius: 200, fraction: 5))
        #expect(editor.points[1].celsius == 89, "must stay 1 °C left of its right neighbour")
        #expect(editor.points[1].fraction == 1.0, "must not exceed its right neighbour")
    }

    @Test("The outermost points are bounded by the axis, not by neighbours")
    func moveClampsEndpointsToAxis() {
        let editor = model()
        editor.move(0, to: CurvePoint(celsius: -100, fraction: -1))
        #expect(editor.points[0].celsius == 30)
        #expect(editor.points[0].fraction == 0)

        editor.move(2, to: CurvePoint(celsius: 999, fraction: 9))
        #expect(editor.points[2].celsius == 110)
        #expect(editor.points[2].fraction == 1)
    }

    /// Pins the fix documented in `CurveEditorModel.move`: neighbours can sit
    /// closer than the 1 °C gap the clamp wants, which inverts the bounds. A
    /// `ClosedRange` **traps** on inverted bounds — the `max()` is what keeps a
    /// drag from crashing the app rather than merely misplacing a point.
    @Test("Neighbours closer than the minimum gap clamp instead of trapping")
    func moveSurvivesInvertedBounds() {
        let editor = CurveEditorModel(curve: FanCurve(points: [
            CurvePoint(celsius: 50, fraction: 0.4),
            CurvePoint(celsius: 51, fraction: 0.5),
            CurvePoint(celsius: 52, fraction: 0.6),
        ]))
        // lowerX = 51, upperX = 51 - 1 = 50 → inverted.
        editor.move(1, to: CurvePoint(celsius: 51, fraction: 0.5))
        #expect(editor.points[1].celsius == 51, "clamped to the lower bound, not trapped")

        // Identical fractions invert the y bounds the same way.
        let flat = CurveEditorModel(curve: FanCurve(points: [
            CurvePoint(celsius: 40, fraction: 0.5),
            CurvePoint(celsius: 60, fraction: 0.5),
            CurvePoint(celsius: 90, fraction: 0.5),
        ]))
        flat.move(1, to: CurvePoint(celsius: 60, fraction: 0.9))
        #expect(flat.points[1].fraction == 0.5)
    }

    @Test("Moving an index that doesn't exist changes nothing")
    func moveIgnoresOutOfRangeIndex() {
        let editor = model()
        let before = editor.points
        editor.move(99, to: CurvePoint(celsius: 70, fraction: 0.7))
        editor.move(-1, to: CurvePoint(celsius: 70, fraction: 0.7))
        #expect(editor.points == before)
    }

    // MARK: - addPoint()

    @Test("A new point lands in temperature order and becomes the selection")
    func addPointInsertsInOrder() throws {
        let editor = model()
        let index = try #require(editor.addPoint(at: CurvePoint(celsius: 70, fraction: 0.7)))
        #expect(index == 2, "70 °C belongs between 60 and 90")
        #expect(editor.selected == index)
        #expect(editor.points.map(\.celsius) == [40, 60, 70, 90])
        // Still sorted — the property the whole editor depends on.
        #expect(editor.points.map(\.celsius) == editor.points.map(\.celsius).sorted())
    }

    @Test("The editor refuses a ninth point")
    func addPointStopsAtEight() {
        let editor = model()
        for celsius in stride(from: 45.0, through: 65.0, by: 4.0) {
            _ = editor.addPoint(at: CurvePoint(celsius: celsius, fraction: 0.3))
        }
        #expect(editor.points.count == 8)
        #expect(editor.addPoint(at: CurvePoint(celsius: 70, fraction: 0.8)) == nil)
        #expect(editor.points.count == 8, "the refused point must not be inserted")
    }

    // MARK: - removeSelected()

    @Test("Removing takes out the selected point and clears the selection")
    func removeSelectedRemovesIt() {
        let editor = model()
        _ = editor.addPoint(at: CurvePoint(celsius: 70, fraction: 0.7))
        editor.selected = 0
        editor.removeSelected()
        #expect(editor.points.count == 3)
        #expect(editor.points.first?.celsius == 60)
        #expect(editor.selected == nil)
    }

    /// A curve needs enough points to still be a curve; three is the floor.
    @Test("The last three points cannot be removed")
    func removeSelectedKeepsThree() {
        let editor = model()
        editor.selected = 1
        editor.removeSelected()
        #expect(editor.points.count == 3, "already at the floor — nothing removed")
        #expect(editor.selected == 1, "and the selection survives, since nothing happened")
    }

    @Test("Removing with no selection, or a stale one, is a no-op")
    func removeSelectedGuards() {
        let editor = model()
        _ = editor.addPoint(at: CurvePoint(celsius: 70, fraction: 0.7))
        let before = editor.points

        editor.selected = nil
        editor.removeSelected()
        #expect(editor.points == before)

        // Stale index — e.g. a selection left over from a larger curve.
        editor.selected = 99
        editor.removeSelected()
        #expect(editor.points == before)
    }

    // MARK: - nudgeSelected()

    @Test("Keyboard nudging obeys the same clamping as dragging")
    func nudgeRespectsConstraints() {
        let editor = model()
        editor.selected = 1
        // Far past the right neighbour in one nudge.
        editor.nudgeSelected(dCelsius: 500, dFraction: 500)
        #expect(editor.points[1].celsius == 89)
        #expect(editor.points[1].fraction == 1.0)
    }

    @Test("Nudging with nothing selected changes nothing")
    func nudgeWithoutSelection() {
        let editor = model()
        let before = editor.points
        editor.nudgeSelected(dCelsius: 5, dFraction: 0.1)
        #expect(editor.points == before)
    }

    // MARK: - Preview and curve bridge

    /// The preview follower is a **struct**, so `updatePreview` works on a copy
    /// and writes it back. Drop that write-back and every tick starts from
    /// scratch: the marker jumps straight to demand and silently stops
    /// demonstrating the hysteresis and ramp it exists to show.
    @Test("The preview accumulates across ticks instead of restarting each time")
    func previewCarriesStateBetweenTicks() {
        let editor = model()
        editor.ramp = 0.1
        editor.updatePreview(die: 40) // settles at 0
        #expect(editor.previewFraction == 0)

        editor.updatePreview(die: 95)
        let first = editor.previewFraction
        editor.updatePreview(die: 95)
        let second = editor.previewFraction

        #expect(first < 1.0, "ramp-limited, not a jump to demand")
        #expect(second > first, "the second tick continues from the first")
    }

    @Test("`curve` reflects the edited points")
    func curveRoundTrips() {
        let editor = model()
        editor.move(1, to: CurvePoint(celsius: 70, fraction: 0.6))
        #expect(editor.curve.points == editor.points)
    }
}
