// InsideView.swift — the experimental live cooling schematic: one Canvas, no stored animation state.

import IceCubeKit
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
struct InsideView: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion

    /// The user's explicit choice if they made one, otherwise the system's.
    private var reduceMotion: Bool {
        if let choice = state.insideAnimation {
            return !choice
        }
        return systemReducesMotion
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: 1 / FanRotation.frameRate, paused: reduceMotion)) { timeline in
                Canvas { context, size in
                    draw(context, size: size, seconds: timeline.date.timeIntervalSinceReferenceDate)
                }
                .accessibilityLabel(accessibilityText)
            }
            .frame(minHeight: 300)
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

    private var accessibilityText: String {
        "\(InsideCopy.headline(heatState)). \(InsideCopy.detail(heatState, gradient: gradient, flow: flow))"
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
                    Text(InsideCopy.detail(heatState, gradient: gradient, flow: flow))
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
        let stage = InsideStage(canvas: size, blowerCount: fans.count)
        guard stage.chassis.width > 240, stage.chassis.height > 170 else { return }

        let shell = Path(roundedRect: stage.chassis, cornerRadius: 18)
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
            drawBlower(board, at: frame, fan: fans[index], seconds: seconds)
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
        let outflowC = blocks.first { $0.role == .outflow }?.celsius ?? intakeC
        let speed = 0.035 + fraction * 0.22
        let perBlower = 14

        for (index, blower) in stage.blowers.enumerated() {
            // Each blower draws from the side it sits on.
            let fromLeft = blower.midX < stage.chassis.midX
            let channelX = fromLeft ? stage.chassis.minX + 16 : stage.chassis.maxX - 16
            for step in 0 ..< perBlower {
                let offset = Double(step) / Double(perBlower) + Double(index) * 0.037
                let phase = reduceMotion
                    ? offset.truncatingRemainder(dividingBy: 1)
                    : (seconds * speed + offset).truncatingRemainder(dividingBy: 1)
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
                    temperature = intakeC
                } else {
                    // Out through the fins at the back edge.
                    let u = CGFloat((phase - 0.62) / 0.38)
                    point = CGPoint(
                        x: blower.midX + lane * blower.width * 0.55,
                        y: blower.midY - (blower.midY - (stage.chassis.minY + 4)) * u
                    )
                    temperature = outflowC
                }
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 1.7, y: point.y - 1.7, width: 3.4, height: 3.4)),
                    with: .color(Theme.temperatureColor(temperature)
                        .opacity(fraction < 0.02 ? 0.12 : 0.24 + fraction * 0.32))
                )
            }
        }
    }

    private func drawVents(_ context: GraphicsContext, stage: InsideStage) {
        var slots = Path()
        for vent in stage.sideVents {
            let rows = max(4, Int(vent.height / 9))
            for row in 0 ..< rows {
                let y = vent.minY + vent.height * (CGFloat(row) + 0.5) / CGFloat(rows)
                slots.move(to: CGPoint(x: vent.minX, y: y))
                slots.addLine(to: CGPoint(x: vent.maxX, y: y))
            }
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
        let colour = Theme.temperatureColor(hottest).opacity(0.30)
        for blower in stage.blowers {
            var pipe = Path()
            let y = stage.logicBoard.minY + stage.logicBoard.height * 0.28
            let fromX = blower.midX < stage.chassis.midX ? stage.logicBoard.minX : stage.logicBoard.maxX
            pipe.move(to: CGPoint(x: fromX, y: y))
            pipe.addLine(to: CGPoint(x: blower.midX, y: y))
            pipe.addLine(to: CGPoint(x: blower.midX, y: blower.midY))
            context.stroke(pipe, with: .color(colour), style: StrokeStyle(lineWidth: 6, lineJoin: .round))
        }
    }

    /// The fin stack the blower vents into: a real stack seen edge-on, with
    /// the fins running along the airflow rather than a block of hatching.
    private func drawFins(_ context: GraphicsContext, stage: InsideStage) {
        let exhaust = blocks.first { $0.role == .outflow }?.celsius
            ?? blocks.first { $0.role == .intake }?.celsius ?? 40
        let colour = Theme.temperatureColor(exhaust)
        for fin in stage.fins {
            context.fill(
                Path(roundedRect: fin, cornerRadius: 2),
                with: .linearGradient(
                    Gradient(colors: [colour.opacity(0.22), colour.opacity(0.06)]),
                    startPoint: CGPoint(x: fin.midX, y: fin.minY),
                    endPoint: CGPoint(x: fin.midX, y: fin.maxY)
                )
            )
            var blades = Path()
            let count = max(8, Int(fin.width / 5))
            for index in 0 ... count {
                let x = fin.minX + fin.width * CGFloat(index) / CGFloat(count)
                blades.move(to: CGPoint(x: x, y: fin.minY + 1))
                blades.addLine(to: CGPoint(x: x, y: fin.maxY - 1))
            }
            context.stroke(blades, with: .color(colour.opacity(0.55)), lineWidth: 0.8)
            // The base the fins stand on, so the stack has a bottom edge to sit
            // against instead of floating.
            var base = Path()
            base.move(to: CGPoint(x: fin.minX, y: fin.maxY))
            base.addLine(to: CGPoint(x: fin.maxX, y: fin.maxY))
            context.stroke(base, with: .color(colour.opacity(0.8)), lineWidth: 1.5)
        }
    }

    private func drawLogicBoard(_ context: GraphicsContext, stage: InsideStage) {
        let outline = Path(roundedRect: stage.logicBoard, cornerRadius: 8)
        context.fill(outline, with: .color(.primary.opacity(0.05)))
        context.stroke(outline, with: .color(.primary.opacity(0.16)), lineWidth: 1)
        let sources = blocks.filter { $0.role == .source }
        drawRow(
            context,
            sources,
            slots: stage.slots(in: stage.siliconRow, count: sources.count, maxWidth: 112),
            prominent: true
        )
    }

    /// The front bay: the battery and whatever else is warm but not in the
    /// heat path.
    private func drawComponentBay(_ context: GraphicsContext, stage: InsideStage) {
        let components = blocks.filter { $0.role == .component }
        guard !components.isEmpty else { return }
        let outline = Path(roundedRect: stage.componentBay, cornerRadius: 8)
        context.stroke(outline, with: .color(.primary.opacity(0.10)), lineWidth: 1)
        drawRow(
            context,
            components,
            slots: stage.slots(in: stage.componentRow, count: components.count, maxWidth: 108),
            prominent: false
        )
    }

    /// The trackpad cutout. Purely orientation: it tells you at a glance which
    /// edge is the one nearest you.
    private func drawFrontNotch(_ context: GraphicsContext, stage: InsideStage) {
        context.stroke(
            Path(roundedRect: stage.frontNotch, cornerRadius: 4),
            with: .color(.primary.opacity(0.10)), lineWidth: 1
        )
    }

    /// Which edge is which, and the air temperature at each.
    private func drawEdgeLabels(_ context: GraphicsContext, stage: InsideStage) {
        let intakeC = blocks.first { $0.role == .intake }
        let outflowC = blocks.first { $0.role == .outflow }
        context.draw(
            Text(outflowC.map { "exhaust  \(Int($0.celsius.rounded()))°" } ?? "exhaust")
                .font(.caption2).foregroundStyle(.secondary),
            at: CGPoint(x: stage.chassis.midX, y: stage.chassis.minY - 5), anchor: .bottom
        )
        context.draw(
            Text(intakeC.map { "air in  \(Int($0.celsius.rounded()))°" } ?? "air in")
                .font(.caption2).foregroundStyle(.secondary),
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
    private func drawBlower(_ context: GraphicsContext, at frame: CGRect, fan: Fan, seconds: Double) {
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

        let turns = reduceMotion ? 0 : FanRotation.phase(rpm: fan.actualRPM, maxRPM: fan.maxRPM, at: seconds)
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
        context.draw(
            Text("\(fan.name)  \(RPM.text(fan.actualRPM))").font(.caption2).foregroundStyle(.secondary),
            at: CGPoint(x: centre.x, y: frame.maxY + 5), anchor: .top
        )
    }

    private func drawRow(
        _ context: GraphicsContext, _ row: [InsideLayout.Block], slots: [CGRect], prominent: Bool
    ) {
        for (block, frame) in zip(row, slots) {
            let shape = Path(roundedRect: frame, cornerRadius: 7)
            let colour = Theme.temperatureColor(block.celsius)
            let heat = min(1, max(0, (block.celsius - 45) / 50))
            context.fill(
                shape,
                with: .linearGradient(
                    Gradient(colors: [
                        colour.opacity(prominent ? 0.20 + heat * 0.38 : 0.16),
                        colour.opacity(prominent ? 0.08 + heat * 0.22 : 0.06),
                    ]),
                    startPoint: CGPoint(x: frame.midX, y: frame.minY),
                    endPoint: CGPoint(x: frame.midX, y: frame.maxY)
                )
            )
            context.stroke(shape, with: .color(colour.opacity(prominent ? 0.75 : 0.42)), lineWidth: 1)
            context.draw(
                Text("\(Int(block.celsius.rounded()))°")
                    .font(prominent ? .title3.weight(.semibold).monospacedDigit() : .callout.monospacedDigit()),
                at: CGPoint(x: frame.midX, y: frame.midY - (prominent ? 6 : 5)), anchor: .center
            )
            context.draw(
                Text(block.label).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: frame.midX, y: frame.maxY - 6), anchor: .center
            )
        }
    }
}
