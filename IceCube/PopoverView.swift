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

    /// Closes whichever window is hosting this view — SwiftUI's `MenuBarExtra`
    /// window, or the `NSPopover` in vendored hosting. Named for what it is, so
    /// `dismissPopover()` below can be the one thing the rest of the file calls.
    @Environment(\.dismiss) private var dismissHostingWindow

    /// Closes the popover in both hosting modes. Call this before opening any
    /// window from inside the popover.
    ///
    /// **Why the popover has to be closed at all:** its window sits at window
    /// level 101 while a `Window` scene sits at level 0, so it covers the
    /// window it just opened even though that window is correctly key and main.
    /// The Settings window was never opening behind anything — it was being
    /// drawn over.
    ///
    /// **Why two calls.** Neither one covers both modes. `dismissHostingWindow`
    /// is the only thing that closes SwiftUI's `MenuBarExtra` window without
    /// desyncing its presentation state — `NSWindow.close()` makes the next
    /// click on the menu bar icon do nothing and `performClose(_:)` does not
    /// hide it at all, both measured on macOS 26.4. It closes a vendored
    /// `NSPopover` too, but *only while that popover's window is key*, and the
    /// `makeKey()` in `StatusItemController.showPopover` is best-effort; when
    /// it has failed, `.transient`'s close-on-resign has no key window to
    /// resign either, so the explicit close is all that is left.
    ///
    /// **Neither call touches `state.isPopoverVisible`.** Whichever close wins
    /// reports itself — `.onDisappear` below in SwiftUI hosting,
    /// `popoverDidClose` in vendored. Clearing the flag here as well would do
    /// it while the popover is still animating out, and `body` would swap in
    /// the 1 pt placeholder: a 380×1 sliver in the user's face.
    private func dismissPopover() {
        dismissHostingWindow()
        // The optional is not a caveat: `AppState.start()` builds the
        // coordinator before the poll task, and `reconcileMenuBarMode()` — the
        // only thing that can ever select `.vendored` — returns early while it
        // is nil. So it is non-nil from launch, and vendored-with-no-coordinator
        // is unreachable rather than merely unlikely.
        state.menuBar?.closeVendoredPopover()
    }

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
        .onAppear {
            state.popoverAppeared()
            quickSwitchIfOptionHeld()
        }
        .onDisappear { state.popoverDisappeared() }
    }

    /// ⌥-click on the menu bar item switches to the next preset (PLAN.md §1.1).
    ///
    /// **The popover still opens** — it just opens already switched. That is the
    /// cheap half of the plan's two variants and it is deliberately first:
    /// `MenuBarExtra` gives no way to intercept a click before the window
    /// appears, and the silent variant needs a hand-rolled `NSStatusItem` to
    /// host the glyph. Doing that here would put the whole menu bar at risk for
    /// a gesture; this reads one flag.
    ///
    /// Read at *appear* rather than captured earlier because there is nowhere
    /// earlier to read it. `NSEvent.modifierFlags` is the live keyboard state,
    /// so a user who releases ⌥ between the click and the window appearing gets
    /// an ordinary open — which is the harmless direction to be wrong in.
    private func quickSwitchIfOptionHeld() {
        // Only in SwiftUI hosting. `StatusItemController` reads the modifier
        // from the click event itself and usually never opens the popover at
        // all — but it does open it when a switch is refused, and ⌥ is often
        // still down at that moment, which would apply a second switch here.
        guard state.menuBar?.mode != .vendored else { return }
        guard NSEvent.modifierFlags.contains(.option) else { return }
        Task { await state.helper.cyclePreset(in: PresetStore.builtins) }
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
                    FanControlSection(
                        helper: state.helper,
                        fans: state.fans,
                        dismissPopover: dismissPopover
                    )
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
    /// The full per-sensor list, grouped as a titled card.
    ///
    /// The height is **reserved**, not measured: see ``SensorListMetrics``. On
    /// a curated Mac it is exactly the list; on a Mac whose sensors are
    /// enumerated rather than curated it is the cap, and the region scrolls
    /// instead of pushing the footer — and the app's only Quit — off screen.
    private var temperatureListCard: some View {
        // The inventory is what this Mac HAS; the published rows are what is
        // reporting this second. `max` covers the moment before the inventory
        // lands, and the enumerating path where the two are the same thing.
        let count = max(state.sensorInventoryCount, state.temperatures.count)
        let layout = SensorListMetrics.layout(sensorCount: count, availableHeight: availableHeight)
        return VStack(alignment: .leading, spacing: Theme.Metrics.cardContentSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sensors").premiumSectionLabel()
                Spacer()
                // Only when the region cannot hold them all: the count is the
                // one fact that explains why you are scrolling, and the
                // footer's Sensors… button is already the see-everything
                // affordance. Derived from the inventory, so it is decided once
                // per launch and cannot blink in and out.
                if layout.scrolls {
                    Text("\(count) total").premiumSectionLabel()
                }
            }
            temperatureListSection
                .frame(height: layout.height, alignment: .top)
        }
        .popoverCard()
    }

    /// The height the popover has to live in. `visibleFrame` has already
    /// excluded the menu bar and the Dock.
    ///
    /// Read per render rather than captured once — it is a cheap lookup and the
    /// display can change under an open popover. No screen at all (headless, or
    /// mid display change) falls back to the absolute cap rather than the
    /// floor, the same choice `IceCubeApp` makes for the Sensors window.
    private var availableHeight: CGFloat {
        NSScreen.main?.visibleFrame.height ?? .infinity
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
        // Derived once so every part of the row answers from the same snapshot
        // rather than re-deriving from `fan` four times.
        let activity = FanActivity(fan)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fan.name)
                    .font(.callout.weight(.medium))
                // Beside the NAME, not the number. The number is right-aligned,
                // so anything reserved next to it pushes the number left even
                // when empty. Here the Spacer absorbs the hint appearing and
                // disappearing, so the reading never moves — which is the rule
                // this popover holds to: no reflow on data change.
                if let heading = activity.rampTargetRPM {
                    Text(verbatim: "→ \(RPM.text(heading))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .transition(.opacity)
                }
                Spacer()
                rpmReadout(fan, activity: activity)
            }
            // Keyed on the hint's PRESENCE, not on `activity`: the value is
            // Equatable but carries `fillFraction`, so it differs on every 1 Hz
            // reading and would animate this row continuously.
            .animation(readingAnimation, value: activity.rampTargetRPM != nil)
            FanSpeedBar(
                fraction: activity.fillFraction,
                target: activity.rampTargetFraction,
                animated: state.chartSettings.smoothReadings
            )
        }
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
    private func rpmReadout(_ fan: Fan, activity: FanActivity) -> some View {
        HStack(spacing: 3) {
            if activity.readout == .starting {
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
    ///
    /// Scrolls inside a height its caller reserves. The rows themselves are
    /// unchanged: discovery order, never sorted by temperature, the hottest
    /// emphasized in place — sorting is what made the whole list reshuffle
    /// every second.
    private var temperatureListSection: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SensorListMetrics.rowSpacing) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Without this, a list shorter than its reserved height rubber-bands on
        // a trackpad flick — motion in the one card meant to be still.
        .scrollBounceBehavior(.basedOnSize)
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
            // The same omission as the Control card's error line: a fixed
            // 380 pt popover truncates any real sentence at one line.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Error: \(message)")
    }

    // MARK: - Footer

    /// Needed to open the sensors window scene from inside the popover.
    @Environment(\.openWindow) private var openWindow

    private var footer: some View {
        HStack {
            Button("Sensors…") {
                WindowOpener.openFromPopover(
                    WindowOpener.ID.sensors, using: openWindow, dismissing: dismissPopover
                )
            }
            .help("Browse every SMC key and export a diagnostics report")
            Button("Settings…") {
                WindowOpener.openFromPopover(
                    WindowOpener.ID.settings, using: openWindow, dismissing: dismissPopover
                )
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
