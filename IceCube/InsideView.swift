// InsideView.swift — the experimental live cooling schematic: one Canvas, no stored animation state.

import IceCubeKit
import os
import SwiftUI

/// Draws the cooling path as it is right now: silicon glowing at its own
/// temperature, air moving at fan speed, blowers turning.
///
/// Every *decision* — which blocks exist, what the state is, what the sentence
/// says, how fast a blade may be drawn — lives in `IceCubeKit`'s `Inside`
/// group and is unit-tested there. This file is the renderer, in the shape
/// `CurveCanvas` established: it takes the values it draws and owns none of
/// them.
///
/// **No stored animation state.** Every particle's position is a pure function
/// of the timeline's date, so a window that was closed and reopened resumes
/// mid-flow instead of restarting, and nothing has to be reset or invalidated.
///
/// **Over CLAUDE.md's ~300-line guidance, deliberately** — the same documented
/// exception `DaemonCore` takes. A `Canvas` is one sequence of draw calls in
/// paint order, and the file is already as thin as it can be: every decision it
/// could hold has been moved out to `IceCubeKit`'s `Inside` group or to
/// ``InsideStage``, leaving only `drawX` functions with no branching in them.
/// Splitting what remains would put the paint order across two files, and paint
/// order is the one thing a reader of drawing code needs to be able to follow.
/// If this grows again, the next thing to leave is the blower renderer, which is
/// self-contained.
/// Owns the running phase of everything that moves.
///
/// A reference type held in `@State` rather than value state, because the draw
/// closure is where the current instant is known and `@State` cannot be written
/// from inside one. ``PhaseIntegrator/advance(to:turnsPerSecond:)`` is
/// idempotent for a repeated instant, which is what makes that safe: SwiftUI
/// may run a body more than once per frame, and every one of those evaluations
/// gets the same answer instead of advancing the motion again.
@MainActor
final class InsideMotion {
    private var flow = PhaseIntegrator()
    private var blades: [Int: PhaseIntegrator] = [:]

    func flowPhase(at seconds: Double, turnsPerSecond: Double) -> Double {
        flow.advance(to: seconds, turnsPerSecond: turnsPerSecond)
    }

    func bladePhase(fan: Int, at seconds: Double, turnsPerSecond: Double) -> Double {
        var integrator = blades[fan] ?? PhaseIntegrator()
        let phase = integrator.advance(to: seconds, turnsPerSecond: turnsPerSecond)
        blades[fan] = integrator
        return phase
    }
}

/// The two things this drawing rebuilt every frame and did not have to.
///
/// Profiling the window found it at **26 % CPU** with 0.3 % as the baseline for
/// the app with it closed. `SwiftUICore` dominated the sample, `CoreText` was
/// second, and the reason for both is that a `Canvas` draw is a closure that
/// runs from scratch 30 times a second — so anything built inside it is built
/// 30 times a second, whether or not it changed.
///
/// Neither of these changes at frame rate. The geometry only changes when the
/// window is resized; the text only changes when a new reading arrives, once a
/// second. Caching them turns per-frame work into per-event work.
@MainActor
final class InsideCache {
    private var cachedStage: (size: CGSize, blowers: Int, stage: InsideStage)?
    private var resolved: [String: GraphicsContext.ResolvedText] = [:]
    private var shapes: [String: Path] = [:]
    private var resolvedForDark: Bool?

    /// Layout, rebuilt only when the canvas size or the fan count changes.
    func stage(canvas: CGSize, blowerCount: Int) -> InsideStage {
        if let cachedStage, cachedStage.size == canvas, cachedStage.blowers == blowerCount {
            return cachedStage.stage
        }
        let stage = InsideStage(canvas: canvas, blowerCount: blowerCount)
        cachedStage = (canvas, blowerCount, stage)
        shapes.removeAll(keepingCapacity: true)
        return stage
    }

    /// A `Path` whose geometry does not change between frames.
    ///
    /// Caching the ``InsideStage`` stopped the *rectangles* being recomputed,
    /// but every frame still turned them back into `Path` objects — and the fin
    /// stacks alone are sixty line segments each. The chassis, the vents, the
    /// fins, the board outlines and the trackpad notch are all fixed until the
    /// window is resized; only their colours change. Built once, kept until the
    /// stage is rebuilt.
    func shape(_ key: String, build: () -> Path) -> Path {
        if let hit = shapes[key] {
            return hit
        }
        let made = build()
        shapes[key] = made
        return made
    }

    /// Text laid out once and reused until its content changes.
    ///
    /// `key` must capture everything that affects the glyphs — the string and
    /// the style — because two different labels sharing a key would draw as
    /// each other. Dropped wholesale when the appearance flips, since the
    /// resolved run carries its colour.
    func text(
        _ key: String, dark: Bool, in context: GraphicsContext, build: () -> Text
    ) -> GraphicsContext.ResolvedText {
        if resolvedForDark != dark {
            resolved.removeAll(keepingCapacity: true)
            resolvedForDark = dark
        }
        if let hit = resolved[key] {
            return hit
        }
        // Every distinct temperature is its own entry, so the map would creep
        // upward over a long session. It is small and cheap to rebuild.
        if resolved.count > 240 {
            resolved.removeAll(keepingCapacity: true)
        }
        let made = context.resolve(build())
        resolved[key] = made
        return made
    }
}

/// Reports the window's state using the two signals that turned out to be
/// trustworthy: is it on screen at all, and is this app the one being used.
///
/// **`occlusionState` was tried first and does not work for this.** The
/// observer attached, the notification fired, and macOS reported the window
/// `visible=true` for the whole time it sat under a full-screen window of
/// another app — 25.9 % CPU either way. See ``InsideActivity`` for the
/// measurement. `isVisible` (which does catch minimising and closing) and the
/// app's own active state are both dependable, so those are what this watches.
struct WindowActivity: NSViewRepresentable {
    @Binding var activity: InsideActivity

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.observe(view) { activity = $0 }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// SwiftUI's teardown hook. `deinit` cannot be used — the tokens are
    /// non-Sendable Objective-C objects and a nonisolated `deinit` may not
    /// touch them under strict concurrency.
    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        MainActor.assumeIsolated { coordinator.stop() }
    }

    @MainActor
    final class Coordinator {
        private var tokens: [any NSObjectProtocol] = []

        func observe(_ view: NSView, report: @escaping @Sendable @MainActor (InsideActivity) -> Void) {
            let log = Logger(subsystem: HelperConstants.logSubsystem, category: "ui")
            // The view is not in a window yet when `makeNSView` runs.
            DispatchQueue.main.async { [weak view] in
                guard let window = view?.window else {
                    log.error("inside: no host window — the window will always draw at full rate")
                    return
                }
                let publish: @Sendable @MainActor () -> Void = { [weak window] in
                    guard let window else { return }
                    report(.current(
                        onScreen: window.isVisible && !window.isMiniaturized,
                        appActive: NSApp.isActive
                    ))
                }
                publish()
                for name in [
                    NSWindow.didMiniaturizeNotification,
                    NSWindow.didDeminiaturizeNotification,
                ] {
                    self.tokens.append(NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { _ in MainActor.assumeIsolated { publish() } })
                }
                for name in [
                    NSApplication.didBecomeActiveNotification,
                    NSApplication.didResignActiveNotification,
                ] {
                    self.tokens.append(NotificationCenter.default.addObserver(
                        forName: name, object: nil, queue: .main
                    ) { _ in MainActor.assumeIsolated { publish() } })
                }
            }
        }

        func stop() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
        }
    }
}

struct InsideView: View {
    @Bindable var state: AppState
    @State private var motion = InsideMotion()
    @State private var cache = InsideCache()
    /// How hard to work right now. See ``InsideActivity``.
    @State private var activity: InsideActivity = .foreground
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Resolved once per frame and passed down, rather than each colour
    /// carrying its own appearance closure. See `Theme.temperatureColor(_:dark:)`.
    private var isDark: Bool {
        colorScheme == .dark
    }

    /// The user's explicit choice if they made one, otherwise the system's —
    /// and always frozen while another app is in front, where a once-a-second
    /// redraw cannot carry motion anyway.
    private var reduceMotion: Bool {
        if !activity.animatesMotion {
            return true
        }
        if let choice = state.insideAnimation {
            return !choice
        }
        return systemReducesMotion
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(
                .animation(
                    minimumInterval: 1 / (activity.framesPerSecond ?? FanRotation.frameRate),
                    paused: reduceMotion || activity.framesPerSecond == nil
                )
            ) { timeline in
                Canvas { context, size in
                    draw(context, size: size, seconds: timeline.date.timeIntervalSinceReferenceDate)
                }
                .accessibilityLabel(accessibilityText)
            }
            .frame(minHeight: 300)
            .background(WindowActivity(activity: $activity).allowsHitTesting(false))
            footer
        }
        .frame(minWidth: 560, minHeight: 440)
        .background(.background)
    }

    // MARK: - Values

    private var snapshot: SMCSnapshot? {
        state.snapshot
    }

    private var blocks: [InsideLayout.Block] {
        InsideLayout.blocks(for: snapshot?.temperatures ?? [])
    }

    private var heatState: HeatFlow.State {
        snapshot.map(HeatFlow.state(for:)) ?? .warmingUp
    }

    private var gradient: Double? {
        snapshot.map { HeatFlow.gradient(for: $0.temperatures) } ?? nil
    }

    private var flow: Double? {
        snapshot.map { HeatFlow.flowFraction($0.fans) } ?? nil
    }

    /// The unit the user picked, as the rest of the app renders it.
    private var style: TemperatureStyle {
        state.temperatureUnit.style
    }

    private var accessibilityText: String {
        let detail = InsideCopy.detail(heatState, gradient: gradient, flow: flow, style: style)
        return "\(InsideCopy.headline(heatState)). \(detail)"
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(pipColor)
                    .frame(width: 8, height: 8)
                    .offset(y: -1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(InsideCopy.headline(heatState)).font(.callout.weight(.semibold))
                    Text(InsideCopy.detail(heatState, gradient: gradient, flow: flow, style: style))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
            }
            Text(InsideCopy.footnote)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Metrics.popoverPadding)
    }

    private var pipColor: Color {
        switch heatState {
        case .warmingUp, .coolAndQuiet: Theme.accent
        case .working: Theme.accent
        case .hotAndUncooled: Theme.warning
        }
    }

    // MARK: - Drawing

    private func draw(_ context: GraphicsContext, size: CGSize, seconds: Double) {
        let fans = snapshot?.fans ?? []
        let stage = cache.stage(canvas: size, blowerCount: fans.count)
        guard stage.chassis.width > 240, stage.chassis.height > 170 else { return }

        let shell = cache.shape("shell") { Path(roundedRect: stage.chassis, cornerRadius: 18) }
        context.fill(shell, with: .color(.primary.opacity(0.03)))
        context.stroke(shell, with: .color(.primary.opacity(0.11)), lineWidth: 1)

        // Everything stays inside the shell. Without this the airflow trails
        // ran off the edge of the window and read as scattered dust.
        var board = context
        board.clip(to: shell)

        drawAir(board, stage: stage, fraction: flow ?? 0, seconds: seconds)
        drawVents(board, stage: stage)
        drawHeatPipe(board, stage: stage)
        drawFins(board, stage: stage)
        for (index, frame) in stage.blowers.enumerated() where index < fans.count {
            drawBlower(
                board, at: frame, fan: fans[index],
                phase: motion.bladePhase(
                    fan: fans[index].id, at: seconds,
                    turnsPerSecond: FanRotation.turnsPerSecond(rpm: fans[index].actualRPM, maxRPM: fans[index].maxRPM)
                )
            )
        }
        drawLogicBoard(board, stage: stage)
        drawComponentBay(board, stage: stage)
        drawFrontNotch(board, stage: stage)
        drawEdgeLabels(context, stage: stage)
    }

    /// Air drawn where it actually travels: in at the side vents, back and up
    /// the outer channels, through the blowers, out the fins at the hinge.
    ///
    /// Kept to the periphery on purpose. The middle of the drawing is where the
    /// temperatures are, and particles wandering across them was most of what
    /// made the first version look like noise.
    private func drawAir(
        _ context: GraphicsContext, stage: InsideStage, fraction: Double, seconds: Double
    ) {
        guard !stage.blowers.isEmpty else { return }
        let intakeC = blocks.first { $0.role == .intake }?.celsius ?? 30
        // The die's rise above the incoming air is what the air is carrying
        // away, and it is what makes the particles change colour at all — the
        // two airflow sensors are 0.2 °C apart and cannot supply a ramp.
        let dieRise = gradient
        // A rate, integrated — never `seconds * speed`. The flow rate follows
        // `actualRPM`, which changes on every poll, and multiplying an absolute
        // clock by a changing rate teleports every particle each time.
        let turnsPerSecond = 0.035 + fraction * 0.22
        let travelled = motion.flowPhase(at: seconds, turnsPerSecond: turnsPerSecond)
        let perBlower = 14
        // Six steps across the whole warming range: at a typical 15 °C rise
        // that is 2.5 °C per step, which the eye cannot separate.
        let bucketCount = 6
        let warmSpan = HeatFlow.airTemperature(progress: 1, intake: intakeC, dieRise: dieRise) - intakeC
        var buckets = [Path](repeating: Path(), count: bucketCount)

        for (index, blower) in stage.blowers.enumerated() {
            // Each blower draws from the side it sits on.
            let fromLeft = blower.midX < stage.chassis.midX
            let channelX = fromLeft ? stage.chassis.minX + 16 : stage.chassis.maxX - 16
            for step in 0 ..< perBlower {
                let offset = Double(step) / Double(perBlower) + Double(index) * 0.037
                let phase = reduceMotion
                    ? offset.truncatingRemainder(dividingBy: 1)
                    : (travelled + offset).truncatingRemainder(dividingBy: 1)
                let lane = CGFloat(step % 3) - 1

                let point: CGPoint
                let temperature: Double
                if phase < 0.62 {
                    // Up the outer channel towards the blower.
                    let u = CGFloat(phase / 0.62)
                    let startY = stage.chassis.maxY - 30
                    point = CGPoint(
                        x: channelX + lane * 4 + (blower.midX - channelX) * u * u,
                        y: startY + (blower.midY - startY) * u
                    )
                    temperature = HeatFlow.airTemperature(
                        progress: phase, intake: intakeC, dieRise: dieRise
                    )
                } else {
                    // Out through the fins at the back edge.
                    let u = CGFloat((phase - 0.62) / 0.38)
                    point = CGPoint(
                        x: blower.midX + lane * blower.width * 0.55,
                        y: blower.midY - (blower.midY - (stage.chassis.minY + 4)) * u
                    )
                    temperature = HeatFlow.airTemperature(
                        progress: phase, intake: intakeC, dieRise: dieRise
                    )
                }
                // Bucketed rather than filled one at a time. Twenty-eight
                // separate `Path` allocations and twenty-eight fills per frame
                // was the largest remaining chunk of drawing work; the air
                // warms continuously along its path, so a handful of colour
                // steps is visually identical and costs one fill each.
                let bucket = Int(((temperature - intakeC) / max(warmSpan, 0.001) * Double(bucketCount - 1))
                    .rounded()).clamped(to: 0 ... bucketCount - 1)
                buckets[bucket].addEllipse(
                    in: CGRect(x: point.x - 1.7, y: point.y - 1.7, width: 3.4, height: 3.4)
                )
            }
        }

        let alpha = fraction < 0.02 ? 0.12 : 0.24 + fraction * 0.32
        for (index, path) in buckets.enumerated() where !path.isEmpty {
            let temperature = intakeC + warmSpan * Double(index) / Double(bucketCount - 1)
            context.fill(
                path,
                with: .color(Theme.temperatureColor(temperature, dark: isDark).opacity(alpha))
            )
        }
    }

    private func drawVents(_ context: GraphicsContext, stage: InsideStage) {
        let slots = cache.shape("vents") {
            var path = Path()
            for vent in stage.sideVents {
                let rows = max(4, Int(vent.height / 9))
                for row in 0 ..< rows {
                    let y = vent.minY + vent.height * (CGFloat(row) + 0.5) / CGFloat(rows)
                    path.move(to: CGPoint(x: vent.minX, y: y))
                    path.addLine(to: CGPoint(x: vent.maxX, y: y))
                }
            }
            return path
        }
        context.stroke(
            slots, with: .color(.primary.opacity(0.20)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )
    }

    /// The vapour chamber: straight runs from the board out to each fin stack.
    ///
    /// Straight, and drawn *behind* the board rather than slung below it. The
    /// curve that used to connect the two blowers was the smile.
    private func drawHeatPipe(_ context: GraphicsContext, stage: InsideStage) {
        let sources = blocks.filter { $0.role == .source }
        guard let hottest = sources.map(\.celsius).max(), !stage.blowers.isEmpty else { return }
        let colour = Theme.temperatureColor(hottest, dark: isDark).opacity(0.30)
        for (slot, blower) in stage.blowers.enumerated() {
            let pipe = cache.shape("pipe.\(slot)") {
                var path = Path()
                let y = stage.logicBoard.minY + stage.logicBoard.height * 0.28
                let fromX = blower.midX < stage.chassis.midX ? stage.logicBoard.minX : stage.logicBoard.maxX
                path.move(to: CGPoint(x: fromX, y: y))
                path.addLine(to: CGPoint(x: blower.midX, y: y))
                path.addLine(to: CGPoint(x: blower.midX, y: blower.midY))
                return path
            }
            context.stroke(pipe, with: .color(colour), style: StrokeStyle(lineWidth: 6, lineJoin: .round))
        }
    }

    /// The fin stack the blower vents into: a real stack seen edge-on, with
    /// the fins running along the airflow rather than a block of hatching.
    private func drawFins(_ context: GraphicsContext, stage: InsideStage) {
        let exhaust = blocks.first { $0.role == .outflow }?.celsius
            ?? blocks.first { $0.role == .intake }?.celsius ?? 40
        let colour = Theme.temperatureColor(exhaust, dark: isDark)
        // Geometry is fixed until the window is resized; only the colour tracks
        // the exhaust. A fin stack is sixty line segments, rebuilt every frame
        // before this.
        for (slot, fin) in stage.fins.enumerated() {
            context.fill(
                cache.shape("fin.body.\(slot)") { Path(roundedRect: fin, cornerRadius: 2) },
                with: .linearGradient(
                    Gradient(colors: [colour.opacity(0.22), colour.opacity(0.06)]),
                    startPoint: CGPoint(x: fin.midX, y: fin.minY),
                    endPoint: CGPoint(x: fin.midX, y: fin.maxY)
                )
            )
            let blades = cache.shape("fin.blades.\(slot)") {
                var path = Path()
                let count = max(8, Int(fin.width / 5))
                for step in 0 ... count {
                    let x = fin.minX + fin.width * CGFloat(step) / CGFloat(count)
                    path.move(to: CGPoint(x: x, y: fin.minY + 1))
                    path.addLine(to: CGPoint(x: x, y: fin.maxY - 1))
                }
                return path
            }
            context.stroke(blades, with: .color(colour.opacity(0.55)), lineWidth: 0.8)
            // The base the fins stand on, so the stack has a bottom edge to sit
            // against instead of floating.
            let base = cache.shape("fin.base.\(slot)") {
                var path = Path()
                path.move(to: CGPoint(x: fin.minX, y: fin.maxY))
                path.addLine(to: CGPoint(x: fin.maxX, y: fin.maxY))
                return path
            }
            context.stroke(base, with: .color(colour.opacity(0.8)), lineWidth: 1.5)
        }
    }

    private func drawLogicBoard(_ context: GraphicsContext, stage: InsideStage) {
        let outline = cache.shape("board") { Path(roundedRect: stage.logicBoard, cornerRadius: 8) }
        context.fill(outline, with: .color(.primary.opacity(0.05)))
        context.stroke(outline, with: .color(.primary.opacity(0.16)), lineWidth: 1)
        let sources = blocks.filter { $0.role == .source }
        drawRow(
            context,
            sources,
            slots: stage.slots(in: stage.siliconRow, count: sources.count, maxWidth: 104, maxHeight: 82),
            prominent: true
        )
    }

    /// The front bay: the battery and whatever else is warm but not in the
    /// heat path.
    private func drawComponentBay(_ context: GraphicsContext, stage: InsideStage) {
        let components = blocks.filter { $0.role == .component }
        guard !components.isEmpty else { return }
        let outline = cache.shape("bay") { Path(roundedRect: stage.componentBay, cornerRadius: 8) }
        context.stroke(outline, with: .color(.primary.opacity(0.10)), lineWidth: 1)
        drawRow(
            context,
            components,
            slots: stage.slots(in: stage.componentRow, count: components.count, maxWidth: 92, maxHeight: 66),
            prominent: false
        )
    }

    /// The trackpad cutout. Purely orientation: it tells you at a glance which
    /// edge is the one nearest you.
    private func drawFrontNotch(_ context: GraphicsContext, stage: InsideStage) {
        context.stroke(
            cache.shape("notch") { Path(roundedRect: stage.frontNotch, cornerRadius: 4) },
            with: .color(.primary.opacity(0.10)), lineWidth: 1
        )
    }

    /// Which edge is which, and the air temperature at each.
    private func drawEdgeLabels(_ context: GraphicsContext, stage: InsideStage) {
        let intakeC = blocks.first { $0.role == .intake }
        let outflowC = blocks.first { $0.role == .outflow }
        let exhaustText = outflowC.map { "exhaust  \(style.reading($0.celsius))" } ?? "exhaust"
        context.draw(
            cache.text("edge:\(exhaustText)", dark: isDark, in: context) {
                Text(exhaustText).font(.caption2).foregroundStyle(.secondary)
            },
            at: CGPoint(x: stage.chassis.midX, y: stage.chassis.minY - 5), anchor: .bottom
        )
        let intakeText = intakeC.map { "air in  \(style.reading($0.celsius))" } ?? "air in"
        context.draw(
            cache.text("edge:\(intakeText)", dark: isDark, in: context) {
                Text(intakeText).font(.caption2).foregroundStyle(.secondary)
            },
            at: CGPoint(x: stage.chassis.midX, y: stage.chassis.maxY + 5), anchor: .top
        )
    }

    /// A centrifugal blower, drawn as one: scroll housing, central inlet,
    /// backswept impeller, and an outlet aimed at the fin stack.
    ///
    /// The shape is a fact rather than a borrowed drawing. Every Mac laptop
    /// uses a centrifugal blower — air in through the middle, flung outwards by
    /// the impeller, gathered by a volute whose radius grows around the turn,
    /// and pushed out of one outlet into the fins. That is true of every model
    /// this app runs on, which a traced diagram of one machine would not be.
    private func drawBlower(_ context: GraphicsContext, at frame: CGRect, fan: Fan, phase: Double) {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let radius = frame.width / 2
        // The outlet faces the fin stack, which sits towards the back edge.
        let outlet = -Double.pi / 2

        // Volute: radius grows from 78 % to 108 % across one turn, ending at
        // the outlet — the asymmetry is what makes it read as a blower housing
        // and not as a wheel.
        var housing = Path()
        let steps = 72
        for step in 0 ... steps {
            let t = Double(step) / Double(steps)
            let angle = outlet + 0.25 + t * 2 * .pi
            let r = radius * (0.78 + 0.30 * t)
            let point = CGPoint(x: centre.x + cos(angle) * r, y: centre.y + sin(angle) * r)
            if step == 0 {
                housing.move(to: point)
            } else {
                housing.addLine(to: point)
            }
        }
        context.stroke(
            housing, with: .color(.primary.opacity(0.28)),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
        )

        // Outlet duct, from the widest point of the volute towards the fins.
        var duct = Path()
        let mouthR = radius * 1.08
        duct.move(to: CGPoint(x: centre.x - radius * 0.78, y: centre.y - radius * 0.2))
        duct.addLine(to: CGPoint(x: centre.x - radius * 0.78, y: centre.y - mouthR - radius * 0.35))
        duct.move(to: CGPoint(x: centre.x + radius * 0.30, y: centre.y - mouthR + radius * 0.05))
        duct.addLine(to: CGPoint(x: centre.x + radius * 0.30, y: centre.y - mouthR - radius * 0.35))
        context.stroke(duct, with: .color(.primary.opacity(0.22)), lineWidth: 1.2)

        let turns = reduceMotion ? 0 : phase
        let blur = FanRotation.blur(rpm: fan.actualRPM, maxRPM: fan.maxRPM)

        var impeller = context
        impeller.translateBy(x: centre.x, y: centre.y)
        impeller.rotate(by: .radians(turns * 2 * .pi))
        let inner = radius * 0.34
        let outer = radius * 0.74
        for index in 0 ..< FanRotation.bladeCount {
            let angle = Double(index) / Double(FanRotation.bladeCount) * 2 * .pi
            // Backswept: the tip trails the root, which is the shape that makes
            // a blower quiet and the shape people recognise.
            let sweep = 0.55
            var blade = Path()
            let root = CGPoint(x: cos(angle) * inner, y: sin(angle) * inner)
            let tip = CGPoint(x: cos(angle - sweep) * outer, y: sin(angle - sweep) * outer)
            let control = CGPoint(
                x: cos(angle - sweep * 0.35) * outer * 0.92,
                y: sin(angle - sweep * 0.35) * outer * 0.92
            )
            blade.move(to: root)
            blade.addQuadCurve(to: tip, control: control)
            impeller.stroke(
                blade,
                with: .color(.primary.opacity(0.34 * (1 - blur * 0.75))),
                style: StrokeStyle(lineWidth: max(1.2, radius * 0.07), lineCap: .round)
            )
        }
        // Above the alias ceiling the blades stop being countable and the disc
        // takes over — which is what a fast blower actually looks like, and
        // cannot alias because there is no longer a blade to sample.
        if blur > 0.02 {
            impeller.fill(
                Path(ellipseIn: CGRect(x: -outer, y: -outer, width: outer * 2, height: outer * 2)),
                with: .color(.primary.opacity(0.10 * blur))
            )
        }
        // Inlet hub.
        context.fill(
            Path(ellipseIn: CGRect(
                x: centre.x - inner * 0.62, y: centre.y - inner * 0.62,
                width: inner * 1.24, height: inner * 1.24
            )),
            with: .color(.primary.opacity(0.26))
        )
        // The fan's own name, so "the left fan" on screen is the one on your
        // left in the machine.
        let fanText = "\(fan.name)  \(RPM.text(fan.actualRPM))"
        context.draw(
            cache.text("fan:\(fanText)", dark: isDark, in: context) {
                Text(fanText).font(.caption2).foregroundStyle(.secondary)
            },
            at: CGPoint(x: centre.x, y: frame.maxY + 5), anchor: .top
        )
    }

    /// One tile: symbol, value, label — the vertical stack Apple uses for a
    /// compact metric (Weather's hourly cells, Fitness' stat tiles).
    ///
    /// Three details do most of the work of looking native, and none of them
    /// are noticeable individually. **SF Rounded** for the numerals, which is
    /// what Apple reaches for when a number is the content rather than part of
    /// a sentence. **Monospaced digits**, because these update once a second and
    /// proportional digits make a reading twitch sideways as it changes.
    /// **Continuous** corner radius — the squircle — rather than the circular
    /// arc `Path(roundedRect:cornerRadius:)` gives by default.
    ///
    /// The fill is tinted by temperature and the stroke is a hairline at low
    /// opacity. A full-strength border around every tile was most of why the
    /// first version read as a grid of boxes rather than a set of readings.
    private func drawRow(
        _ context: GraphicsContext, _ row: [InsideLayout.Block], slots: [CGRect], prominent: Bool
    ) {
        for (block, frame) in zip(row, slots) {
            let colour = Theme.temperatureColor(block.celsius, dark: isDark)
            let heat = min(1, max(0, (block.celsius - 45) / 50))
            let heatKey = Int(block.celsius.rounded())
            let shape = Path(
                roundedRect: frame,
                cornerSize: CGSize(width: 12, height: 12),
                style: .continuous
            )
            context.fill(
                shape,
                with: .linearGradient(
                    Gradient(colors: [
                        colour.opacity(prominent ? 0.22 + heat * 0.30 : 0.16),
                        colour.opacity(prominent ? 0.09 + heat * 0.16 : 0.07),
                    ]),
                    startPoint: CGPoint(x: frame.midX, y: frame.minY),
                    endPoint: CGPoint(x: frame.midX, y: frame.maxY)
                )
            )
            context.stroke(shape, with: .color(colour.opacity(prominent ? 0.45 : 0.28)), lineWidth: 0.75)

            let valueSize: CGFloat = prominent ? 25 : 19
            let iconSize: CGFloat = prominent ? 15 : 12
            let labelSize: CGFloat = prominent ? 11 : 10

            // The colour is part of the key: a resolved run carries its own
            // colour, so two tiles at different temperatures must not share one.
            context.draw(
                cache.text("icon:\(block.symbolName):\(iconSize):\(heatKey)", dark: isDark, in: context) {
                    Text(Image(systemName: block.symbolName))
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(colour)
                },
                at: CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.22), anchor: .center
            )
            let valueText = "\(Int(style.absolute(block.celsius).rounded()))°"
            context.draw(
                cache.text("value:\(valueText):\(valueSize)", dark: isDark, in: context) {
                    Text(valueText)
                        .font(.system(size: valueSize, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                },
                at: CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.53), anchor: .center
            )
            context.draw(
                cache.text("label:\(block.label):\(labelSize)", dark: isDark, in: context) {
                    Text(block.label)
                        .font(.system(size: labelSize, weight: .medium))
                        .foregroundStyle(.secondary)
                },
                at: CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.81), anchor: .center
            )
        }
    }
}
