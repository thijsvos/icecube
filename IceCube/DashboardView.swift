// DashboardView.swift — the popover's chart stack: window switcher, pause, and one ChartRowView per row.

import IceCubeKit
import SwiftUI
import UniformTypeIdentifiers

/// The live-charts section of the popover (PLAN.md §1.2): a title that doubles
/// as the live window caption ("1 MIN HISTORY"), a CSV export button, a pause
/// button, and the stacked chart rows.
///
/// The window picker itself moved to Settings → Menu → Charts along with the
/// row-visibility toggles, which is why this view only *reads*
/// `chartSettings.window` and re-renders on change. Only the two live actions
/// stayed: pausing and exporting are things you do while looking at the charts,
/// and a picker is a thing you set once.
///
/// The section's height is constant once rows exist — rows are a static set
/// (see `ChartStore`) and each row has a fixed frame, so the popover never
/// resizes while you watch.
struct DashboardView: View {
    /// The shared observable state; owned by `IceCubeApp`.
    /// Plain `let`: @Bindable exists to project `$`-bindings, and this view
    /// forms none — it only reads and calls methods.
    let state: AppState

    /// CSV export flow state.
    @State private var isExportingCSV = false
    @State private var exportDocument: DiagnosticsDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardContentSpacing) {
            controls
                .fileExporter(
                    isPresented: $isExportingCSV,
                    document: exportDocument,
                    contentType: .commaSeparatedText,
                    defaultFilename: "icecube-history"
                ) { result in
                    // A failed export used to vanish entirely — the sheet closed
                    // and nothing was written or said. Surface it the same way
                    // every other app-side failure is surfaced.
                    if case let .failure(error) = result {
                        state.reportError("Could not export history: \(error.localizedDescription)")
                    }
                }
            if state.chartRows.isEmpty {
                collectingPlaceholder
            } else {
                ForEach(state.chartRows) { row in
                    ChartRowView(
                        row: row,
                        xDomain: state.chartXDomain,
                        unit: state.temperatureUnit,
                        options: state.chartSettings,
                        decisions: state.helper.decisions
                    )
                }
            }
        }
        // The window and row-visibility live in Settings now; re-render when
        // any of them changes so the popover reflects the new choice at once.
        .onChange(of: state.chartSettings.window) { state.refreshCharts() }
        .onChange(of: chartFilterSignature) { state.refreshCharts() }
        // Charts were the one popover section that sat bare in the stack while
        // Fans, Control and Sensors were all grouped cards — and because the
        // compact temperature line that replaces this section *is* a card, the
        // "Show charts" toggle silently changed whether that slot had a card at
        // all. Same treatment now, either way.
        .popoverCard()
    }

    /// A value that changes whenever a row-visibility toggle flips — cheaper
    /// than observing each Bool separately.
    private var chartFilterSignature: [Bool] {
        [
            state.chartSettings.showCPU,
            state.chartSettings.showGPU,
            state.chartSettings.showFans,
            state.chartSettings.showPower,
        ]
    }

    // MARK: - Controls (live actions only — settings moved to the Settings window)

    private var controls: some View {
        HStack(spacing: 8) {
            // Doubles as this card's title, so it wears the same quiet
            // uppercase treatment as FANS / CONTROL / SENSORS rather than the
            // one-off secondary caption it used to be. Still carries the live
            // window ("1 MIN HISTORY"), which is the only place that shows.
            Text("\(state.chartSettings.window.title) History")
                .premiumSectionLabel()
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
