// SensorsBrowserView.swift — the Sensors window: readable named sensors by default, raw SMC keys on demand.

import IceCubeKit
import SwiftUI
import UniformTypeIdentifiers

/// Shows what the Mac is reporting.
///
/// By default a **readable** list of the recognized, human-labeled sensors
/// (CPU/GPU/battery/…) and fans, refreshed live. The full ~2000-key raw SMC
/// dump — useful only to tinkerers and to the "new Mac model" diagnostics
/// pipeline — is hidden behind an advanced toggle and loaded on demand. The
/// Export button writes the full ``DiagnosticsReport`` JSON, which a GitHub
/// issue attaches to get an unmapped model supported.
struct SensorsBrowserView: View {
    /// The shared observable state; owned by `IceCubeApp`.
    let state: AppState

    /// Advanced: reveal every raw SMC key (off by default).
    @State private var showAllKeys = false
    /// The raw key dump; loaded only while `showAllKeys` is on.
    @State private var rows: [SMCKeyDump]?
    @State private var filter = ""
    @State private var isExporting = false
    @State private var exportDocument: DiagnosticsDocument?
    @State private var exportMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if showAllKeys {
                allKeysTable
            } else {
                recognizedList
            }
        }
        .frame(minWidth: 420, minHeight: 440)
        // Load the expensive raw dump only when the advanced view is showing.
        .task(id: showAllKeys) {
            guard showAllKeys else { return }
            while !Task.isCancelled {
                rows = await state.keyDump()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "icecube-diagnostics-\(HostInfo.modelIdentifier())"
        ) { result in
            switch result {
            case .success: exportMessage = "Report exported."
            case let .failure(error): exportMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Controls row

    private var controls: some View {
        HStack(spacing: 8) {
            Toggle("All SMC keys", isOn: $showAllKeys)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Advanced: show every raw SMC register this Mac exposes")
            if showAllKeys {
                TextField("Filter…", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
            }
            if state.isSimulated {
                Text("SIMULATED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.warning)
            }
            Spacer()
            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Export Diagnostics…") {
                Task {
                    do {
                        exportDocument = try await DiagnosticsDocument(data: state.diagnosticsJSON())
                        isExporting = true
                    } catch {
                        exportMessage = error.localizedDescription
                    }
                }
            }
            .help(
                "Save a full machine report as JSON — attach it to a GitHub issue to get your Mac model's sensors mapped"
            )
        }
        .padding(10)
    }

    // MARK: - Recognized sensors (the readable default)

    private var recognizedList: some View {
        List {
            Section("Temperatures") {
                // Stable alphabetical order so rows never reshuffle as values
                // change — sorting by temperature made the whole list jump every
                // second. The hottest sensor is flagged in place instead.
                let temps = state.temperatures.sorted { $0.label < $1.label }
                if temps.isEmpty {
                    Text("No named temperature sensors on this model yet — Export Diagnostics to help add them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(temps) { reading in
                    let isHottest = reading.id == state.hottest?.id
                    HStack(spacing: 6) {
                        Text(reading.label)
                            .fontWeight(isHottest ? .semibold : .regular)
                        if isHottest {
                            Image(systemName: "flame.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.temperatureColor(reading.celsius))
                                .help("Hottest sensor right now")
                        }
                        Spacer()
                        Text(state.temperatureUnit.text(reading.celsius))
                            .monospacedDigit()
                            .foregroundStyle(Theme.temperatureColor(reading.celsius))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(reading.label) \(Int(reading.celsius.rounded())) degrees\(isHottest ? ", hottest" : "")"
                    )
                }
            }
            Section("Fans") {
                if state.fans.isEmpty {
                    Text("No fans reported (fanless Mac).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(state.fans) { fan in
                    HStack {
                        Text(fan.name)
                        Spacer()
                        Text(RPM.labeled(fan.actualRPM))
                            .monospacedDigit()
                        Text(verbatim: "(\(RPM.text(fan.minRPM))–\(RPM.text(fan.maxRPM)))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    // MARK: - Advanced: every raw SMC key

    private var filteredRows: [SMCKeyDump] {
        guard let rows else { return [] }
        guard !filter.isEmpty else { return rows }
        let needle = filter.lowercased()
        return rows.filter {
            $0.key.lowercased().contains(needle)
                || $0.type.lowercased().contains(needle)
                || ($0.text?.lowercased().contains(needle) ?? false)
        }
    }

    @ViewBuilder
    private var allKeysTable: some View {
        if rows == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Reading all SMC keys…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(filteredRows) {
                TableColumn("Key") { Text($0.key).font(.body.monospaced()) }
                    .width(min: 56, ideal: 64)
                TableColumn("Type") { Text($0.type).font(.body.monospaced()).foregroundStyle(.secondary) }
                    .width(min: 48, ideal: 56)
                TableColumn("Value") { Text(displayValue(of: $0)).font(.body.monospaced()) }
                TableColumn("Bytes") { Text($0.bytesHex).font(.body.monospaced()).foregroundStyle(.tertiary) }
            }
        }
    }

    /// Decoded value when we can, hex placeholder when we can't.
    private func displayValue(of row: SMCKeyDump) -> String {
        if let value = row.value {
            return value == value.rounded() && abs(value) < 1_000_000
                ? String(Int(value))
                : String(format: "%.2f", value)
        }
        return row.text ?? "—"
    }
}

/// An export payload for `fileExporter` — write-only, never opened.
///
/// Declares **both** types it is used for: the sensors browser exports JSON
/// diagnostics, the dashboard exports CSV history. It previously declared only
/// `.json` while `DashboardView` asked the exporter for `.commaSeparatedText`,
/// so the document and the exporter disagreed about what was being written.
/// `fileExporter(contentType:)` selects from this list per call site.
struct DiagnosticsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json, .commaSeparatedText]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
