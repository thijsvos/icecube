// PopoverView.swift — the menu-bar popover: fans, temperatures, and the app's only Quit affordance.

import AppKit
import IceCubeKit
import SwiftUI

/// The content of the `MenuBarExtra` window.
///
/// Layout, top to bottom: header (app name, SIMULATED badge, hottest-sensor
/// badge), one row per fan, a divider, the temperature list, and a footer with
/// a placeholder "Open Ice Cube" button plus a working Quit button. Because
/// Ice Cube is an `LSUIElement` app there is no Dock icon — Quit here is the
/// only way out.
///
/// Styling rule: system materials and hierarchical fills only, never opaque
/// custom colors, so the popover looks native in both light and dark mode.
struct PopoverView: View {
    /// The shared observable state; owned by `IceCubeApp`.
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let errorMessage = state.errorMessage {
                errorRow(errorMessage)
            }
            if state.snapshot == nil {
                waitingRow
            } else {
                fanSection
                if state.chartSettings.showControls {
                    FanControlSection(helper: state.helper, fans: state.fans)
                }
                if state.chartSettings.showCharts {
                    Divider()
                    DashboardView(state: state)
                } else {
                    compactTemperatureLine
                }
                if state.chartSettings.showTemperatureList {
                    Divider()
                    temperatureListSection
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // The ice-cube brand mark — instant confirmation you opened the
            // right app the moment the popover appears.
            Image(nsImage: MenuBarGlyph.iceCube)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text("Ice Cube")
                .font(.headline)
            if state.isSimulated {
                badge("SIMULATED")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Simulated data")
            }
            Spacer()
            // No temperature here on purpose: the header is identity, not data.
            // The hottest reading lives in the body (and the menu bar) once —
            // showing it here too was the duplicate readout.
        }
    }

    /// A small capsule label using a hierarchical fill (never an opaque color).
    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    // MARK: - Fans

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.fans) { fan in
                fanRow(fan)
            }
        }
    }

    private func fanRow(_ fan: Fan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(fan.name)
                    .font(.callout.weight(.medium))
                Text(fan.mode.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(fan.actualRPM)) → \(Int(fan.targetRPM)) RPM")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        "\(fan.name) fan: \(Int(fan.actualRPM)) RPM, target \(Int(fan.targetRPM)) RPM, \(fan.mode.displayName) mode"
                    )
            }
            // A gauge-ish readout: actual RPM normalized into the fan's
            // reported [min, max] range, clamped so out-of-range never breaks.
            ProgressView(value: normalizedSpeed(of: fan))
                .controlSize(.small)
                .accessibilityHidden(true) // the RPM text above carries the value
        }
    }

    /// `actualRPM` mapped into `[minRPM, maxRPM]` as 0…1, clamped.
    private func normalizedSpeed(of fan: Fan) -> Double {
        guard fan.maxRPM > fan.minRPM else { return 0 }
        let fraction = (fan.actualRPM - fan.minRPM) / (fan.maxRPM - fan.minRPM)
        return min(max(fraction, 0), 1)
    }

    // MARK: - Minimalist temperature views (when charts are hidden)

    /// A single compact CPU/GPU temperature readout — the whole temperature
    /// story for the minimalist menu, shown once and grouped (not the obscure
    /// hottest-core name, and not duplicated in the header).
    private var compactTemperatureLine: some View {
        HStack(spacing: 14) {
            if let cpu = state.cpuTempMax {
                tempReadout("CPU", cpu)
            }
            if let gpu = state.gpuTempMax {
                tempReadout("GPU", gpu)
            }
            if state.cpuTempMax == nil, state.gpuTempMax == nil {
                Text("—").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func tempReadout(_ label: String, _ celsius: Double) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(state.temperatureUnit.text(celsius))
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Int(celsius.rounded())) degrees")
    }

    /// The full per-sensor list — opt-in for people who want every reading in
    /// the menu (the Sensors window always has the exhaustive view).
    private var temperatureListSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(state.temperatures) { reading in
                HStack {
                    Text(reading.label)
                        .font(.caption)
                        .foregroundStyle(reading.id == state.hottest?
                            .id ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    Spacer()
                    Text(state.temperatureUnit.text(reading.celsius))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(reading.id == state.hottest?
                            .id ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                }
            }
        }
    }

    // MARK: - Waiting / error states

    private var waitingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Waiting for first reading…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityLabel("Error: \(message)")
    }

    // MARK: - Footer

    /// Needed to open the sensors window scene from inside the popover.
    @Environment(\.openWindow) private var openWindow

    private var footer: some View {
        HStack {
            Button("Sensors…") {
                WindowOpener.open(WindowOpener.ID.sensors, using: openWindow)
            }
            .help("Browse every SMC key and export a diagnostics report")
            Button("Settings…") {
                WindowOpener.open(WindowOpener.ID.settings, using: openWindow)
            }
            .help("All Ice Cube settings")
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }
}

private extension FanMode {
    /// Short human-readable mode name for the fan row's secondary label.
    var displayName: String {
        switch self {
        case .auto: "Auto"
        case .forced: "Manual"
        case .system: "System"
        }
    }
}
