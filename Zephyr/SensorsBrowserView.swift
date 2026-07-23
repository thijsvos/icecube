// SensorsBrowserView.swift — the SMC key browser window: every key, live values, JSON diagnostics export.

import SwiftUI
import UniformTypeIdentifiers
import ZephyrKit

/// Browses every SMC key the machine exposes, refreshing values every 2 s
/// while the window is open. Doubles as the community diagnostics tool: the
/// Export button writes the full ``DiagnosticsReport`` as JSON, which is what
/// a "new Mac model" GitHub issue asks the reporter to attach.
struct SensorsBrowserView: View {
    /// The shared observable state; owned by `ZephyrApp`.
    let state: AppState

    /// The latest dump; `nil` until the first one lands (loading state).
    @State private var rows: [SMCKeyDump]?
    /// Case-insensitive substring filter over key, type, and label text.
    @State private var filter = ""
    /// Export flow state.
    @State private var isExporting = false
    @State private var exportDocument: DiagnosticsDocument?
    @State private var exportMessage: String?

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

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            table
        }
        .frame(minWidth: 460, minHeight: 380)
        // .task cancels with the view: closing the window stops the refresh.
        .task {
            while !Task.isCancelled {
                rows = await state.keyDump()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "zephyr-diagnostics-\(HostInfo.modelIdentifier())"
        ) { result in
            switch result {
            case .success:
                exportMessage = "Report exported."
            case let .failure(error):
                exportMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Controls row

    private var controls: some View {
        HStack(spacing: 8) {
            TextField("Filter keys…", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
            if state.isSimulated {
                Text("SIMULATED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let exportMessage {
                Text(exportMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(filteredRows.count) of \(rows?.count ?? 0) keys")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
            .help("Save the full machine report as JSON — attach it to a GitHub issue to get your Mac model supported")
        }
        .padding(10)
    }

    // MARK: - Key table

    @ViewBuilder
    private var table: some View {
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
                TableColumn("Key") { row in
                    Text(row.key)
                        .font(.body.monospaced())
                }
                .width(min: 56, ideal: 64)
                TableColumn("Type") { row in
                    Text(row.type)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                }
                .width(min: 48, ideal: 56)
                TableColumn("Value") { row in
                    Text(displayValue(of: row))
                        .font(.body.monospaced())
                }
                TableColumn("Bytes") { row in
                    Text(row.bytesHex)
                        .font(.body.monospaced())
                        .foregroundStyle(.tertiary)
                }
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

/// A JSON payload for `fileExporter` — write-only, never opened.
struct DiagnosticsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

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
