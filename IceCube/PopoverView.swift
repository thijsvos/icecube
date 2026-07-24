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

    /// The easing used for live readings, or `nil` when the user has turned the
    /// "smooth readings" preference off (values then snap instantly).
    private var readingAnimation: Animation? {
        state.chartSettings.smoothReadings ? .easeInOut(duration: 0.35) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            header
            if let errorMessage = state.errorMessage {
                errorRow(errorMessage)
            }
            if state.snapshot == nil {
                waitingRow
            } else {
                fanCard
                if state.chartSettings.showControls {
                    FanControlSection(helper: state.helper, fans: state.fans)
                }
                if state.chartSettings.showCharts {
                    DashboardView(state: state)
                } else {
                    compactTemperatureCard
                }
                if state.chartSettings.showTemperatureList {
                    temperatureListCard
                }
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
        // Opening the popover forces an immediate reconnect + reconcile, so the
        // highlighted preset is correct the instant you look — no waiting for
        // the 5 s maintenance tick after a wake.
        .onAppear { state.helper.refreshNow() }
    }

    /// The fan readouts, grouped as a titled card.
    private var fanCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fans").premiumSectionLabel()
            fanSection
        }
        .popoverCard()
    }

    /// The compact CPU/GPU line, grouped as a titled card (shown when the full
    /// charts are hidden).
    private var compactTemperatureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Temperature").premiumSectionLabel()
            compactTemperatureLine
        }
        .popoverCard()
    }

    /// The full per-sensor list, grouped as a titled card.
    private var temperatureListCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sensors").premiumSectionLabel()
            temperatureListSection
        }
        .popoverCard()
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fan.name)
                    .font(.callout.weight(.medium))
                Spacer()
                rpmReadout(fan)
            }
            FanSpeedBar(
                fraction: normalizedSpeed(of: fan),
                target: targetSpeed(of: fan),
                animated: state.chartSettings.smoothReadings
            )
        }
    }

    /// The fan's target speed as 0…1 of max, for the gauge tick — nil when
    /// there's nothing meaningful to aim at (no target reported).
    private func targetSpeed(of fan: Fan) -> Double? {
        guard fan.maxRPM > 0, fan.targetRPM > 0 else { return nil }
        return min(max(fan.targetRPM / fan.maxRPM, 0), 1)
    }

    /// The current RPM, prominent, with a quiet unit label — and a fixed
    /// layout. The digits glide (numericText) to each new reading, but the row
    /// never reflows: the old "→ target" arrow toggled on and off every tick and
    /// shoved the number sideways, which was hard on the eyes. The fan's motion
    /// toward a target is shown by the sliding gauge bar below instead.
    private func rpmReadout(_ fan: Fan) -> some View {
        HStack(spacing: 3) {
            Text("\(Int(fan.actualRPM))")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("RPM")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .animation(readingAnimation, value: Int(fan.actualRPM))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(fan.name) fan: \(Int(fan.actualRPM)) RPM, target \(Int(fan.targetRPM)) RPM"
        )
    }

    /// `actualRPM` as a fraction of the fan's maximum (0…1), measured from 0 —
    /// NOT from the minimum. A fan spinning at its floor (e.g. Quiet parks it at
    /// Mn) must still show a visibly partial bar, never an empty one that reads
    /// as "stopped." The only empty bar is a genuinely stopped fan (0 RPM).
    private func normalizedSpeed(of fan: Fan) -> Double {
        guard fan.maxRPM > 0 else { return 0 }
        return min(max(fan.actualRPM / fan.maxRPM, 0), 1)
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
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.temperatureColor(celsius))
                .contentTransition(.numericText())
                .animation(readingAnimation, value: state.temperatureUnit.text(celsius))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(Int(celsius.rounded())) degrees")
    }

    /// The full per-sensor list — opt-in for people who want every reading in
    /// the menu (the Sensors window always has the exhaustive view).
    private var temperatureListSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(state.temperatures) { reading in
                let isHottest = reading.id == state.hottest?.id
                HStack {
                    Text(reading.label)
                        .font(.caption.weight(isHottest ? .medium : .regular))
                        .foregroundStyle(isHottest ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    Spacer()
                    // Each value tinted by its own heat — the list reads as a
                    // subtle thermal map instead of flat gray with one orange row.
                    Text(state.temperatureUnit.text(reading.celsius))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.temperatureColor(reading.celsius))
                        .contentTransition(.numericText())
                        .animation(readingAnimation, value: state.temperatureUnit.text(reading.celsius))
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
