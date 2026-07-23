// DashboardView.swift — the popover's chart stack: window switcher, pause, and one ChartRowView per row.

import SwiftUI
import UniformTypeIdentifiers
import ZephyrKit

/// The live-charts section of the popover (PLAN.md §1.2): a window picker
/// (1/5/15/60 min), a pause button, and the stacked chart rows.
///
/// The section's height is constant once rows exist — rows are a static set
/// (see `ChartStore`) and each row has a fixed frame, so the popover never
/// resizes while you watch.
struct DashboardView: View {
    /// The shared observable state; owned by `ZephyrApp`.
    @Bindable var state: AppState

    private static let windowTitles = ["1 min", "5 min", "15 min", "1 hr"]

    /// CSV export flow state.
    @State private var isExportingCSV = false
    @State private var exportDocument: DiagnosticsDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
                .fileExporter(
                    isPresented: $isExportingCSV,
                    document: exportDocument,
                    contentType: .commaSeparatedText,
                    defaultFilename: "zephyr-history"
                ) { _ in }
            if state.chartRows.isEmpty {
                collectingPlaceholder
            } else {
                ForEach(state.chartRows) { row in
                    ChartRowView(row: row, xDomain: state.chartXDomain, unit: state.temperatureUnit)
                }
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Chart window", selection: $state.selectedWindowIndex) {
                ForEach(0 ..< Self.windowTitles.count, id: \.self) { index in
                    Text(Self.windowTitles[index]).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .disabled(state.isPaused) // switching windows would contradict the freeze
            .frame(maxWidth: 240)
            Spacer()
            Button {
                Task {
                    exportDocument = await DiagnosticsDocument(data: Data(state.chartsCSV().utf8))
                    isExportingCSV = true
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Export the chart history (up to 60 min) as CSV")
            .accessibilityLabel("Export history as CSV")
            Button {
                state.togglePaused()
            } label: {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(state.isPaused ? "Resume live charts" : "Freeze the charts (data keeps recording)")
            .accessibilityLabel(state.isPaused ? "Resume charts" : "Pause charts")
        }
    }

    /// Same footprint as one chart row, so the layout doesn't lurch when the
    /// first real row set arrives a second after launch.
    private var collectingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Collecting readings…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(height: 64)
        .frame(maxWidth: .infinity)
    }
}
