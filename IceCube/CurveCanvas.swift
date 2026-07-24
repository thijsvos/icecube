// CurveCanvas.swift — the curve editor's drag/draw surface: Canvas, handles, keyboard nudge, live marker.

import IceCubeKit
import SwiftUI

/// The interactive plot: drag points, double-click to add, Delete to remove,
/// arrow keys to nudge, plus a live "you are here" marker.
///
/// Takes only the editing model and one temperature, deliberately — no
/// `AppState`. That keeps `SMCProviding` and the helper out of the drawing
/// code's dependency graph entirely, and makes the canvas previewable against
/// a bare ``CurveEditorModel``.
struct CurveCanvas: View {
    let model: CurveEditorModel
    /// The hottest die reading, for the live marker; `nil` before the first poll.
    let hottestDie: Double?

    /// The plotted temperature range. Lives here because every user of it —
    /// coordinate mapping, the grid, the curve, the marker — is in this file.
    static let tempRange = 30.0 ... 110.0

    @State private var isDragging = false
    @FocusState private var canvasFocused: Bool

    var body: some View {
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
        guard let die = hottestDie else { return }
        let clamped = die.clamped(to: Self.tempRange)
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
}
