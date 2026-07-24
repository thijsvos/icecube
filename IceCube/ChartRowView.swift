// ChartRowView.swift — one dashboard chart row: gradient band + average line, fixed axes, hover crosshair.

import Charts
import IceCubeKit
import SwiftUI

/// Renders one ``ChartStore/Row`` as an Afterburner-style strip chart.
///
/// Anti-jump rules baked in: the y domain comes fixed from the row, the x
/// domain is passed in so all rows share one time axis, the frame height is
/// constant, and there are **no implicit animations** on live marks (PLAN.md
/// §1.2). Hover state is `@State` local to this row, so moving the crosshair
/// in one chart never invalidates its siblings.
struct ChartRowView: View {
    let row: ChartStore.Row
    /// Shared time axis, ending at the latest sample.
    let xDomain: ClosedRange<Date>
    /// Display unit for temperature rows (RPM rows ignore it).
    var unit: TemperatureUnit = .celsius
    /// User chart preferences (band, secondary line, height).
    var options: ChartSettings

    /// The crosshair position while the pointer is over this row's plot.
    @State private var hoverDate: Date?

    /// The series to draw — the secondary (average/target) line is optional.
    private var visibleSeries: [ChartStore.Series] {
        options.showSecondary ? row.series : row.series.filter { !$0.isSecondary }
    }

    /// Whether this row's values get unit-converted for display.
    private var convertsUnit: Bool {
        row.unit == .celsius && unit == .fahrenheit
    }

    /// A display value in the row's effective unit.
    private func displayValue(_ celsius: Double) -> Double {
        convertsUnit ? unit.display(celsius) : celsius
    }

    /// The unit label shown in the header.
    private var displayUnit: String {
        convertsUnit ? "°F" : row.unit.rawValue
    }

    /// Per-row accent, on the app's palette: temperature rows glow by heat
    /// (thermal color of the live value), fan rows use the ice-blue brand accent
    /// — the same language as the popover gauges and readouts.
    private var accent: Color {
        switch row.unit {
        case .celsius:
            let latest = row.series.first?.stats?.latest ?? row.yDomainMax
            return Theme.temperatureColor(latest)
        case .rpm:
            return Theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            chart
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Header (fixed layout slots; content swaps on hover)

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.title)
                .font(.caption.weight(.semibold))
            Text(latestText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(accent)
            Spacer()
            Text(trailingText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The primary series' live value, e.g. `"66 °C"` / `"4996 RPM"`.
    private var latestText: String {
        guard let stats = row.series.first?.stats else { return "—" }
        return "\(format(stats.latest)) \(displayUnit)"
    }

    /// `min · avg · max` normally; the values under the crosshair on hover.
    private var trailingText: String {
        if let hoverDate {
            let parts = row.series.compactMap { series -> String? in
                guard let bucket = nearestBucket(in: series, to: hoverDate) else { return nil }
                return "\(series.label.lowercased()) \(format(bucket.avg))"
            }
            if !parts.isEmpty {
                return parts.joined(separator: " · ")
            }
        }
        guard let stats = row.series.first?.stats else { return "collecting…" }
        return "min \(format(stats.min)) · avg \(format(stats.avg)) · max \(format(stats.max))"
    }

    /// Formats a raw (°C/RPM) value in the display unit.
    private func format(_ value: Double) -> String {
        String(Int(displayValue(value).rounded()))
    }

    private func nearestBucket(in series: ChartStore.Series, to date: Date) -> ChartBucket? {
        series.buckets.min {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }
    }

    private var accessibilitySummary: String {
        guard let stats = row.series.first?.stats else { return "\(row.title): collecting data" }
        return "\(row.title): now \(format(stats.latest)) \(displayUnit), "
            + "minimum \(format(stats.min)), average \(format(stats.avg)), maximum \(format(stats.max))"
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(visibleSeries) { series in
                ForEach(series.buckets, id: \.time) { bucket in
                    // The min–max band: only for the primary series (the
                    // secondary target/average line stays a clean dash), and
                    // only when the user wants it.
                    if !series.isSecondary, options.showBand {
                        AreaMark(
                            x: .value("Time", bucket.time),
                            yStart: .value("Min", displayValue(bucket.min)),
                            yEnd: .value("Max", displayValue(bucket.max))
                        )
                        .foregroundStyle(bandGradient)
                    }
                    LineMark(
                        x: .value("Time", bucket.time),
                        y: .value("Value", displayValue(bucket.avg)),
                        series: .value("Series", series.id)
                    )
                    .foregroundStyle(series.isSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
                    .lineStyle(StrokeStyle(
                        lineWidth: series.isSecondary ? 1 : 1.5,
                        dash: series.isSecondary ? [3, 3] : []
                    ))
                }
            }
            if let hoverDate {
                RuleMark(x: .value("Time", hoverDate))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: displayValue(row.yDomainMin) ... displayValue(row.yDomainMax))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(.quaternary)
                AxisValueLabel().font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            if let plotFrame = proxy.plotFrame {
                                let x = location.x - geo[plotFrame].origin.x
                                hoverDate = proxy.value(atX: x)
                            }
                        case .ended:
                            hoverDate = nil
                        }
                    }
            }
        }
        .frame(height: options.height.points)
    }

    private var bandGradient: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.35), accent.opacity(0.03)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
