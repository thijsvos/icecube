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
        // MenuBarExtra(.window) keeps this view graph alive after the first
        // open, so while the window is off screen the live content must not be
        // built at all. It is not enough to stop publishing chart rows: the fan
        // gauges animate (0.45 s easeInOut) and the RPM readouts use
        // .contentTransition(.numericText()), both keyed on values that change
        // every second — which kept the hidden window in a continuous
        // CoreAnimation display cycle at ~18 % CPU. The lifecycle modifiers sit
        // on this outer Group so they still fire while the body is swapped out.
        Group {
            if state.isPopoverVisible {
                liveContent
            } else {
                // Same width token as the live content, so the window doesn't
                // resize on reopen.
                Color.clear.frame(width: Theme.Metrics.popoverWidth, height: 1)
            }
        }
        .task { await state.helper.maintainOnce() }
        .onAppear { state.popoverAppeared() }
        .onDisappear { state.popoverDisappeared() }
    }

    private var liveContent: some View {
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
        .padding(Theme.Metrics.popoverPadding)
        .frame(width: Theme.Metrics.popoverWidth)
    }

    /// The fan readouts, grouped as a titled card.
    private var fanCard: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardContentSpacing) {
            Text("Fans").premiumSectionLabel()
            fanSection
        }
        .popoverCard()
    }

    /// The compact CPU/GPU line, grouped as a titled card (shown when the full
    /// charts are hidden).
    private var compactTemperatureCard: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardContentSpacing) {
            Text("Temperature").premiumSectionLabel()
            compactTemperatureLine
        }
        .popoverCard()
    }

    /// The full per-sensor list, grouped as a titled card.
    private var temperatureListCard: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardContentSpacing) {
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
                    .foregroundStyle(Theme.warning)
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
                // Beside the NAME, not the number. The number is right-aligned,
                // so anything reserved next to it pushes the number left even
                // when empty. Here the Spacer absorbs the hint appearing and
                // disappearing, so the reading never moves — which is the rule
                // this popover holds to: no reflow on data change.
                if isRampingUp(fan) {
                    Text(verbatim: "→ \(RPM.text(fan.targetRPM))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .transition(.opacity)
                }
                Spacer()
                rpmReadout(fan)
            }
            .animation(readingAnimation, value: isRampingUp(fan))
            FanSpeedBar(
                fraction: normalizedSpeed(of: fan),
                target: targetSpeed(of: fan),
                animated: state.chartSettings.smoothReadings
            )
        }
    }

    /// The fan's target speed as 0…1 of max, for the gauge tick — nil when
    /// there's nothing meaningful to aim at.
    ///
    /// Same `.forced` requirement as ``isRampingUp(_:)`` and for the same
    /// reason: once control is handed back to macOS the last written target
    /// lingers in `F{i}Tg`, so the tick would sit at the fan's minimum
    /// indefinitely while the fan is stopped, marking a destination nothing is
    /// travelling to.
    private func targetSpeed(of fan: Fan) -> Double? {
        guard fan.mode == .forced, fan.maxRPM > 0, fan.targetRPM > 0 else { return nil }
        return (fan.targetRPM / fan.maxRPM).clamped(to: 0 ... 1)
    }

    /// How far a fan may trail its target before the row says where it is
    /// heading. Below this, the gauge tick alone tells the story.
    private static let rampVisibleRPM: Double = 300

    /// Whether this fan is still meaningfully short of its commanded speed.
    ///
    /// Requires `.forced` — Ice Cube actually driving this fan. `targetRPM` is
    /// simply the last value written to `F{i}Tg`, and it PERSISTS after control
    /// is handed back: a revert parks it at the fan's minimum and then gives
    /// the fan to macOS, which may well settle on 0 RPM. Reading that stale
    /// number as a destination made Automatic display a permanent "→ 2317"
    /// while the fan sat still — promising something nothing was working
    /// toward, which is worse than saying nothing.
    ///
    /// Only counts ramping UP: winding down is not something a user waits on,
    /// and showing it would put a hint on screen most of the time for no gain.
    private func isRampingUp(_ fan: Fan) -> Bool {
        fan.mode == .forced
            && fan.targetRPM > 0
            && fan.targetRPM - fan.actualRPM > Self.rampVisibleRPM
    }

    /// Whether this fan is commanded but not yet reporting motion.
    ///
    /// Measured on a Mac14,9 at 5 samples/s: a stopped fan given a target reads
    /// EXACTLY 0 RPM for ~1.5 s before the tachometer shows anything, then
    /// climbs to speed over another ~3 s. The whole ramp is firmware-paced —
    /// driving the fan at 6800 instead of 4250 produced an identical curve
    /// (295/573/839/1731…) and an identical dead time, so it cannot be made
    /// faster from here.
    ///
    /// What it CAN do is stop lying about it. "0 RPM" during that window says
    /// nothing is happening when the fan is in fact starting, which is exactly
    /// when someone concludes the app is broken and switches back.
    private func isStarting(_ fan: Fan) -> Bool {
        fan.mode == .forced && fan.targetRPM > fan.minRPM && fan.actualRPM < 100
    }

    /// The current RPM, prominent, with a quiet unit label, plus where the fan
    /// is heading while it is still getting there.
    ///
    /// The destination slot is **permanently reserved** rather than inserted
    /// when needed. An earlier version appended "→ target" only while ramping,
    /// which toggled on and off every tick and shoved the number sideways; a
    /// fixed-width slot shows the same information without ever reflowing.
    ///
    /// Worth showing because the gap can be large and slow: switching from
    /// Automatic (where macOS may park the fans at 0) to a curve commands the
    /// new speed within a second, but the fan takes many seconds to physically
    /// wind up. Without this the popover reads "0 RPM" while everything is in
    /// fact working, which is indistinguishable from broken.
    private func rpmReadout(_ fan: Fan) -> some View {
        HStack(spacing: 3) {
            if isStarting(fan) {
                Text("starting…")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(RPM.text(fan.actualRPM))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("RPM")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .animation(readingAnimation, value: Int(fan.actualRPM))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(fan.name) fan: \(RPM.labeled(fan.actualRPM)), target \(RPM.labeled(fan.targetRPM))"
        )
    }

    /// `actualRPM` as a fraction of the fan's maximum (0…1), measured from 0 —
    /// NOT from the minimum. A fan spinning at its floor (e.g. Quiet parks it at
    /// Mn) must still show a visibly partial bar, never an empty one that reads
    /// as "stopped." The only empty bar is a genuinely stopped fan (0 RPM).
    private func normalizedSpeed(of fan: Fan) -> Double {
        guard fan.maxRPM > 0 else { return 0 }
        return (fan.actualRPM / fan.maxRPM).clamped(to: 0 ... 1)
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
                        .foregroundStyle(isHottest ? HierarchicalShapeStyle.primary : .secondary)
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
            .foregroundStyle(Theme.warning)
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
