// DashboardView.swift — the popover's chart stack: window switcher, pause, and one ChartRowView per row.

import IceCubeKit
import SwiftUI
import UniformTypeIdentifiers

/// The live-charts section of the popover (PLAN.md §1.2): a window picker
/// (1/5/15/60 min), a pause button, and the stacked chart rows.
///
/// The section's height is constant once rows exist — rows are a static set
/// (see `ChartStore`) and each row has a fixed frame, so the popover never
/// resizes while you watch.
struct DashboardView: View {
    /// The shared observable state; owned by `IceCubeApp`.
    // Plain `let`: @Bindable exists to project `$`-bindings, and this view
    // forms none — it only reads and calls methods.
    let state: AppState


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
                    defaultFilename: "icecube-history"
                ) { _ in }
            if state.chartRows.isEmpty {
                collectingPlaceholder
            } else {
                ForEach(state.chartRows) { row in
                    ChartRowView(
                        row: row,
                        xDomain: state.chartXDomain,
                        unit: state.temperatureUnit,
                        options: state.chartSettings
                    )
                }
            }
        }
        // The window and row-visibility live in Settings now; re-render when
        // any of them changes so the popover reflects the new choice at once.
        .onChange(of: state.chartSettings.window) { state.refreshCharts() }
        .onChange(of: chartFilterSignature) { state.refreshCharts() }
    }

    /// A value that changes whenever a row-visibility toggle flips — cheaper
    /// than observing each Bool separately.
    private var chartFilterSignature: [Bool] {
        [state.chartSettings.showCPU, state.chartSettings.showGPU, state.chartSettings.showFans]
    }

    // MARK: - Controls (live actions only — settings moved to the Settings window)

    private var controls: some View {
        HStack(spacing: 8) {
            Text("\(state.chartSettings.window.title) history")
                .font(.caption)
                .foregroundStyle(.secondary)
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
