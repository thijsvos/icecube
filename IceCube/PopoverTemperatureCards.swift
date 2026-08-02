// PopoverTemperatureCards.swift — the compact CPU/GPU line, and the opt-in per-sensor list.

import AppKit
import IceCubeKit
import SwiftUI

/// The temperature surfaces of the popover: the compact two-value line shown
/// when charts are off, and the full per-sensor list shown when the user asks
/// for it.
///
/// The list's height is *reserved* from the sensor inventory rather than
/// measured from the rows on screen — see ``SensorListMetrics``. That is
/// load-bearing and moved here unchanged.
struct PopoverTemperatureCards: View {
    let state: AppState

    /// Which surface to show is the caller's setting, kept here so the
    /// popover body stays a list of cards.
    var body: some View {
        // The compact line is the stand-in for the charts, so it appears only
        // when they are off. The full list is independent and opt-in.
        if !state.chartSettings.showCharts {
            compactTemperatureCard
        }
        if state.chartSettings.showTemperatureList {
            temperatureListCard
        }
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
                .animation(state.readingAnimation, value: state.temperatureUnit.text(celsius))
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
                            .animation(state.readingAnimation, value: state.temperatureUnit.text(reading.celsius))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Without this, a list shorter than its reserved height rubber-bands on
        // a trackpad flick — motion in the one card meant to be still.
        .scrollBounceBehavior(.basedOnSize)
    }
}
