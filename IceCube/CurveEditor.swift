// CurveEditor.swift — the draggable fan-curve editor: Canvas, handles, keyboard nudge, live marker.

import IceCubeKit
import SwiftUI

/// Editing state for one curve: points with live constraints.
@MainActor
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
            celsius: min(max(raw.celsius, lowerX), max(lowerX, upperX)),
            fraction: min(max(raw.fraction, lowerY), upperY)
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

/// The curve editor window: drag points, double-click to add, Delete to
/// remove, arrow keys to nudge. Shows a live "you are here" marker from the
/// current readings (simulated or real).
struct CurveEditorView: View {
    let state: AppState
    @State private var model = CurveEditorModel()
    @State private var presetName = ""
    @AppStorage("persistCurve") private var persistCurve = false
    @FocusState private var canvasFocused: Bool

    private static let tempRange = 30.0 ... 110.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            canvas
                .frame(minHeight: 240)
            footer
        }
        .padding(14)
        .frame(minWidth: 600, minHeight: 430)
        // Sliders, toggle, and buttons all take the ice-blue brand accent.
        .tint(Theme.accent)
        .onChange(of: state.snapshot) {
            if let die = state.hottestDie {
                model.updatePreview(die: die)
            }
        }
    }

    // MARK: - Header: load presets into the editor

    private var header: some View {
        HStack(spacing: 8) {
            // The preset loaders live in a floating glass pod — a small hovering
            // control cluster, distinct from the canvas it acts on.
            HStack(spacing: 8) {
                Text("Load").premiumSectionLabel()
                ForEach(
                    [("Quiet", FanCurve.quiet), ("Balanced", .balanced), ("Cold", .cold), ("Max", .max)],
                    id: \.0
                ) { name, curve in
                    Button(name) { model.load(curve) }
                        .buttonStyle(.borderless)
                }
                ForEach(state.presets.userPresets) { preset in
                    if let curve = preset.config.sharedCurve {
                        Button(preset.name) { model.load(curve) }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .floatingGlass(in: Capsule())
            Spacer()
            Text("double-click: add · ⌫: remove · arrows: nudge")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size).insetBy(dx: 30, dy: 18)
            ZStack {
                Canvas { context, _ in
                    drawGrid(context, rect)
                    drawCurve(context, rect)
                    drawLiveMarker(context, rect)
                    drawHandles(context, rect)
                }
                .accessibilityLabel("Fan curve editor: \(model.points.count) points")
            }
            .contentShape(Rectangle())
            .focusable()
            .focused($canvasFocused)
            .gesture(dragGesture(rect))
            .onTapGesture(count: 2) { location in
                model.addPoint(at: value(at: location, in: rect))
                canvasFocused = true
            }
            .onTapGesture { location in
                model.selected = handleIndex(near: location, in: rect)
                canvasFocused = true
            }
            .onDeleteCommand { model.removeSelected() }
            .onMoveCommand { direction in
                switch direction {
                case .left: model.nudgeSelected(dCelsius: -1, dFraction: 0)
                case .right: model.nudgeSelected(dCelsius: 1, dFraction: 0)
                case .up: model.nudgeSelected(dCelsius: 0, dFraction: 0.02)
                case .down: model.nudgeSelected(dCelsius: 0, dFraction: -0.02)
                @unknown default: break
                }
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8)) // drawings never bleed past the panel
    }

    private func dragGesture(_ rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { drag in
                if model.selected == nil || !isDragging {
                    model.selected = handleIndex(near: drag.startLocation, in: rect)
                    isDragging = true
                }
                if let index = model.selected {
                    model.move(index, to: value(at: drag.location, in: rect))
                }
            }
            .onEnded { _ in isDragging = false }
    }

    @State private var isDragging = false

    // MARK: - Coordinate mapping

    private func position(of point: CurvePoint, in rect: CGRect) -> CGPoint {
        let x = rect.minX + rect.width * (point.celsius - Self.tempRange.lowerBound)
            / (Self.tempRange.upperBound - Self.tempRange.lowerBound)
        let y = rect.maxY - rect.height * point.fraction
        return CGPoint(x: x, y: y)
    }

    private func value(at location: CGPoint, in rect: CGRect) -> CurvePoint {
        let celsius = Self.tempRange.lowerBound + (location.x - rect.minX) / rect.width
            * (Self.tempRange.upperBound - Self.tempRange.lowerBound)
        let fraction = (rect.maxY - location.y) / rect.height
        return CurvePoint(celsius: celsius, fraction: fraction)
    }

    private func handleIndex(near location: CGPoint, in rect: CGRect) -> Int? {
        model.points.indices.min { a, b in
            distance(location, position(of: model.points[a], in: rect))
                < distance(location, position(of: model.points[b], in: rect))
        }.flatMap { index in
            distance(location, position(of: model.points[index], in: rect)) < 14 ? index : nil
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - Drawing

    private func drawGrid(_ context: GraphicsContext, _ rect: CGRect) {
        let gridStroke = StrokeStyle(lineWidth: 0.5, dash: [2, 3])
        for temp in stride(from: 30.0, through: 110.0, by: 10) {
            let x = position(of: CurvePoint(celsius: temp, fraction: 0), in: rect).x
            context.stroke(
                Path { $0.move(to: CGPoint(x: x, y: rect.minY)); $0.addLine(to: CGPoint(x: x, y: rect.maxY)) },
                with: .color(.gray.opacity(0.15)),
                style: gridStroke
            )
            context.draw(
                Text("\(Int(temp))°").font(.caption2).foregroundStyle(.tertiary),
                at: CGPoint(x: x, y: rect.maxY + 9)
            )
        }
        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
            let y = rect.maxY - rect.height * fraction
            context.stroke(
                Path { $0.move(to: CGPoint(x: rect.minX, y: y)); $0.addLine(to: CGPoint(x: rect.maxX, y: y)) },
                with: .color(.gray.opacity(0.15)),
                style: gridStroke
            )
            context.draw(
                Text("\(Int(fraction * 100))%").font(.caption2).foregroundStyle(.tertiary),
                at: CGPoint(x: rect.minX - 16, y: y)
            )
        }
    }

    private func drawCurve(_ context: GraphicsContext, _ rect: CGRect) {
        let curve = model.curve
        guard curve.isUsable else { return }
        var line = Path()
        var fill = Path()
        let start = position(of: CurvePoint(
            celsius: Self.tempRange.lowerBound,
            fraction: curve.fraction(at: Self.tempRange.lowerBound)
        ), in: rect)
        line.move(to: start)
        fill.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        fill.addLine(to: start)
        for temp in stride(from: Self.tempRange.lowerBound, through: Self.tempRange.upperBound, by: 1) {
            let p = position(of: CurvePoint(celsius: temp, fraction: curve.fraction(at: temp)), in: rect)
            line.addLine(to: p)
            fill.addLine(to: p)
        }
        fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        fill.closeSubpath()
        context.fill(fill, with: .linearGradient(
            Gradient(colors: [Theme.accent.opacity(0.28), Theme.accent.opacity(0.02)]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY),
            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
        ))
        context.stroke(line, with: .color(Theme.accent), lineWidth: 2)
    }

    private func drawLiveMarker(_ context: GraphicsContext, _ rect: CGRect) {
        guard let die = state.hottestDie else { return }
        let clamped = min(max(die, Self.tempRange.lowerBound), Self.tempRange.upperBound)
        // The marker is a temperature, so it wears the thermal color — warm as
        // the die heats — which also keeps it legible over the blue curve.
        let heat = Theme.temperatureColor(die)
        let x = position(of: CurvePoint(celsius: clamped, fraction: 0), in: rect).x
        context.stroke(
            Path { $0.move(to: CGPoint(x: x, y: rect.minY)); $0.addLine(to: CGPoint(x: x, y: rect.maxY)) },
            with: .color(heat.opacity(0.7)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )
        context.draw(
            Text("\(Int(die.rounded()))°").font(.caption2.bold()).foregroundStyle(heat),
            at: CGPoint(x: x, y: rect.minY - 8)
        )
        // The "applied" dot: where hysteresis + ramp have actually gotten to.
        let dot = position(of: CurvePoint(celsius: clamped, fraction: model.previewFraction), in: rect)
        context.fill(
            Path(ellipseIn: CGRect(x: dot.x - 5, y: dot.y - 5, width: 10, height: 10)),
            with: .color(heat)
        )
    }

    private func drawHandles(_ context: GraphicsContext, _ rect: CGRect) {
        for (index, point) in model.points.enumerated() {
            let p = position(of: point, in: rect)
            let r: CGFloat = index == model.selected ? 8 : 6
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                with: .color(Theme.accent)
            )
            if index == model.selected {
                context.stroke(
                    Path(ellipseIn: CGRect(x: p.x - r - 3, y: p.y - r - 3, width: 2 * r + 6, height: 2 * r + 6)),
                    with: .color(.primary),
                    lineWidth: 2
                )
            }
        }
    }

    // MARK: - Footer: parameters, persist, apply, save

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Two rows, each narrower than the window's minimum width — a
            // footer that can outgrow the window pushes the whole layout past
            // its borders. Labels stay fixed-width + monospaced so nothing
            // moves while a slider is being dragged.
            HStack(spacing: 10) {
                Text("Hysteresis \(model.hysteresis, specifier: "%.0f")°")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 78, alignment: .leading)
                Slider(value: $model.hysteresis, in: 0 ... 8, step: 1)
                    .frame(width: 100)
                    .controlSize(.mini)
                Text("Ramp \(Int(model.ramp * 100))%/tick")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 86, alignment: .leading)
                Slider(value: $model.ramp, in: 0.02 ... 0.3)
                    .frame(width: 100)
                    .controlSize(.mini)
                Spacer(minLength: 0)
                if state.isSimulated {
                    Text("SIMULATED")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .help("Applying a curve needs real hardware")
                }
            }
            HStack(spacing: 8) {
                Toggle("Keep running when app quits", isOn: $persistCurve)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                TextField("Preset name", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Button("Save Preset") {
                    state.presets.saveUserPreset(named: presetName, curve: model.curve)
                    presetName = ""
                }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Apply Curve") {
                    Task { await applyCurve() }
                }
                .primaryGlassButton()
                .disabled(!canApply)
            }
        }
        .controlSize(.small)
    }

    private var canApply: Bool {
        guard case .connected = state.helper.connection else { return false }
        return model.curve.isUsable && !state.isSimulated
    }

    private func applyCurve() async {
        var config = FanConfig.curve(model.curve, persists: persistCurve)
        config.hysteresisCelsius = model.hysteresis
        config.rampPerTick = model.ramp
        await state.helper.apply(config)
    }
}
