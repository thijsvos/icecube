// CoolingHistoryWindow.swift — months of °C/W per fan-speed band: the chart, the verdict, the controls.

import Charts
import IceCubeKit
import SwiftUI

/// The history behind the trend verdict. One band at a time, deliberately:
/// cross-band overlay is an invitation to the exact comparison the physics
/// forbids (°C/W at 3550 RPM and at 5950 are different quantities). Every
/// number drawn here comes from `CoolingTrend.seriesByBand` — the same data
/// the verdict judged, so the picture and the sentence cannot disagree.
struct CoolingHistoryWindow: View {
    @Bindable var state: AppState

    /// Selected band; nil until first render picks the most-evidenced one.
    @State private var selectedBand: FanBand?
    /// Frozen on appear: the anti-jump rule forbids an axis that rescales
    /// while you watch, and computing on open is not while you watch.
    @State private var frozenYDomain: ClosedRange<Double>?
    @State private var isConfirmingClear = false
    @State private var isConfirmingCleaned = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            header
            verdictRow
            chart
            footer
        }
        .padding(Theme.Metrics.popoverPadding)
        .frame(minWidth: 480, minHeight: 360)
        .onAppear {
            let options = bandOptions
            if selectedBand == nil {
                selectedBand = options.first?.band
            }
            if frozenYDomain == nil {
                frozenYDomain = CoolingHistoryChartModel.yDomain(
                    options.flatMap { CoolingHistoryChartModel.points(series[$0.band] ?? []) }
                )
            }
        }
    }

    // MARK: - Data (always through the verdict's own series)

    private var series: [FanBand: [CoolingDayAggregate]] {
        guard let history = state.history.history else { return [:] }
        return CoolingTrend.seriesByBand(history, now: Date())
    }

    private var bandOptions: [CoolingHistoryChartModel.BandOption] {
        CoolingHistoryChartModel.bandOptions(series)
    }

    private var points: [CoolingHistoryChartModel.DayPoint] {
        guard let selectedBand else { return [] }
        return CoolingHistoryChartModel.points(series[selectedBand] ?? [])
    }

    private var comparison: CoolingTrend.Comparison? {
        switch state.coolingTrend {
        case let .stable(comparison), let .slowRise(comparison), let .improved(comparison):
            comparison.band == selectedBand ? comparison : nil
        default:
            nil
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            if bandOptions.count > 1, let fan = state.fans.first {
                Picker("Fan speed", selection: $selectedBand) {
                    ForEach(bandOptions) { option in
                        Text(label(option.band, fan: fan))
                            .tag(Optional(option.band))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Readings are only comparable within one fan-speed band, "
                    + "so the chart shows one band at a time — never an overlay.")
            } else {
                Text(bandTitle)
                    .font(.headline)
            }
            Spacer()
            if state.isSimulated {
                Label("Simulated", systemImage: "theatermasks")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.warning.opacity(0.15), in: Capsule())
                    .help("Invented history, seeded so this window can be demonstrated "
                        + "without months of uptime. A real run never loads it.")
            }
        }
    }

    private var verdictRow: some View {
        let copy = CoolingTrendCopy.row(
            state.coolingTrend,
            capabilities: .init(snapshot: state.snapshot),
            readings: state.history.readingCount(),
            style: state.temperatureUnit.style,
            now: Date()
        )
        let isWarning = CoolingTrendCopy.isWarning(state.coolingTrend)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if isWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
                Text(copy.title)
                    .font(.headline)
                    .foregroundStyle(isWarning ? Theme.warning : .primary)
            }
            if let metric = copy.metric {
                Text(metric)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let note = copy.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .help(copy.hover ?? "")
        .accessibilityHint(copy.hover ?? "")
    }

    @ViewBuilder
    private var chart: some View {
        if points.isEmpty {
            // No axes around nothing: the verdict row above already says
            // what is being waited for.
            Spacer()
        } else {
            let style = state.temperatureUnit.style
            Chart {
                // Dots, not a line, for the days themselves: a line across a
                // data gap asserts continuity nothing measured. The median
                // line below joins only days ≤ 3 apart.
                ForEach(points) { point in
                    PointMark(
                        x: .value("Day", point.date),
                        y: .value("\(style.symbol)/W", style.delta(point.median))
                    )
                    .symbolSize(by: .value("Readings", point.readings))
                    .foregroundStyle(Theme.accent.opacity(0.65))
                }
                ForEach(
                    Array(CoolingHistoryChartModel.medianRuns(points).enumerated()),
                    id: \.offset
                ) { _, run in
                    ForEach(run) { point in
                        LineMark(
                            x: .value("Day", point.date),
                            y: .value("\(style.symbol)/W", style.delta(point.median)),
                            series: .value("Run", "run-\(run.first?.id.timeIntervalSince1970 ?? 0)")
                        )
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.secondary)
                    }
                }
                // The verdict, drawn: two rules whose gap IS the change.
                if let comparison {
                    RuleMark(y: .value("Baseline", style.delta(comparison.baselineMedian)))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(.tertiary)
                        .annotation(position: .top, alignment: .leading) {
                            Text("baseline \(style.perWatt(comparison.baselineMedian))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    RuleMark(y: .value("Now", style.delta(comparison.recentMedian)))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(Theme.accent)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("now \(style.perWatt(comparison.recentMedian))")
                                .font(.caption2)
                                .foregroundStyle(Theme.accent)
                        }
                }
            }
            .chartYScale(domain: scaledYDomain)
            .chartXScale(domain: xDomain)
            .chartYAxisLabel("\(style.symbol)/W")
            .accessibilityLabel("Cooling efficiency per day, \(points.count) days charted")
        }
    }

    private var footer: some View {
        HStack {
            Text("\(state.history.readingCount()) readings")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Mark as Cleaned…") { isConfirmingCleaned = true }
                .disabled(state.history.history == nil)
                .help("Records that you cleaned the vents or repasted today. The baseline "
                    + "restarts after a cleaning, so \u{201C}better than before\u{201D} compares "
                    + "against the dust rather than through it.")
                .confirmationDialog(
                    "Mark today as a cleaning?",
                    isPresented: $isConfirmingCleaned
                ) {
                    Button("Mark as Cleaned") {
                        state.markCoolingServiced()
                    }
                } message: {
                    Text("The trend's baseline will restart from today. Use this after "
                        + "clearing the vents or repasting.")
                }
            Button("Clear History…", role: .destructive) { isConfirmingClear = true }
                .disabled(state.history.history == nil)
                .confirmationDialog(
                    "Delete \(state.history.readingCount()) readings?",
                    isPresented: $isConfirmingClear
                ) {
                    Button("Delete", role: .destructive) {
                        state.clearCoolingHistory()
                    }
                } message: {
                    Text("The baseline starts over, and it will be about six weeks before "
                        + "Ice Cube can say anything about the trend again.")
                }
        }
    }

    // MARK: - Small helpers

    private var scaledYDomain: ClosedRange<Double> {
        let style = state.temperatureUnit.style
        let domain = frozenYDomain ?? CoolingHistoryChartModel.yDomain(points)
        return style.delta(domain.lowerBound) ... style.delta(domain.upperBound)
    }

    /// Forward while collecting: sparse early points sit at the left with
    /// room ahead of them, which reads as a thing filling up rather than a
    /// thing that is empty.
    private var xDomain: ClosedRange<Date> {
        let now = Date()
        guard let first = points.first?.date else { return now.addingTimeInterval(-86400) ... now }
        let end = max(now, first.addingTimeInterval(14 * 86400))
        return first.addingTimeInterval(-43200) ... end
    }

    private var bandTitle: String {
        guard let selectedBand else { return "Cooling History" }
        guard let fan = state.fans.first else {
            return selectedBand == .fanless ? "No fans" : "Cooling History"
        }
        return label(selectedBand, fan: fan)
    }

    private func label(_ band: FanBand, fan: Fan) -> String {
        CoolingHistoryChartModel.rpmLabel(band, minRPM: fan.minRPM, maxRPM: fan.maxRPM)
    }
}
