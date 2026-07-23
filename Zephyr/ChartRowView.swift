// ChartRowView.swift — one dashboard chart row: gradient band + average line, fixed axes, hover crosshair.

import Charts
import SwiftUI
import ZephyrKit

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

    /// The crosshair position while the pointer is over this row's plot.
    @State private var hoverDate: Date?

    /// Per-row accent: CPU orange, GPU purple, fans teal.
    private var accent: Color {
        if row.id == "cpu" {
            .orange
        } else if row.id == "gpu" {
            .purple
        } else {
            .teal
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
        return "\(format(stats.latest)) \(row.unit)"
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

    private func format(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private func nearestBucket(in series: ChartStore.Series, to date: Date) -> ChartBucket? {
        series.buckets.min {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }
    }

    private var accessibilitySummary: String {
        guard let stats = row.series.first?.stats else { return "\(row.title): collecting data" }
        return "\(row.title): now \(format(stats.latest)) \(row.unit), "
            + "minimum \(format(stats.min)), average \(format(stats.avg)), maximum \(format(stats.max))"
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            ForEach(row.series) { series in
                ForEach(series.buckets, id: \.time) { bucket in
                    // The min–max band: only for the primary series (the
                    // secondary target/average line stays a clean dash).
                    if !series.isSecondary {
                        AreaMark(
                            x: .value("Time", bucket.time),
                            yStart: .value("Min", bucket.min),
                            yEnd: .value("Max", bucket.max)
                        )
                        .foregroundStyle(bandGradient)
                    }
                    LineMark(
                        x: .value("Time", bucket.time),
                        y: .value("Value", bucket.avg),
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
        .chartYScale(domain: row.yDomainMin ... row.yDomainMax)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(.quaternary)
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
        .frame(height: 64)
    }

    private var bandGradient: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.35), accent.opacity(0.03)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
