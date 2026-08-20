// SettingsMenuTab.swift — what the menu bar and popover show.

import IceCubeKit
import SwiftUI

/// The Menu pane. Storage stays in `SettingsWindowView`; see
/// ``SettingsGeneralTab`` for why.
struct SettingsMenuTab: View {
    @Bindable var state: AppState

    var body: some View {
        menuTab
    }

    private var menuTab: some View {
        @Bindable var chart = state.chartSettings
        return Form {
            Section("Menu bar") {
                Picker("Show beside the icon", selection: $state.menuBarDisplay) {
                    ForEach(MenuBarDisplayMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("⌥-click switches preset silently", isOn: $state.prefersSilentOptionClick)
                    .help(
                        "Off: ⌥-click opens the popover already switched to the next preset. "
                            + "On: it switches without opening anything, using Ice Cube's own "
                            + "menu bar item. Either way, a preset you pick by hand still gives "
                            + "way to the power-source rule the next time you plug in or unplug."
                    )
            }
            Section("In the menu") {
                Toggle("Fan controls", isOn: $chart.showControls)
                Toggle("Full temperature list", isOn: $chart.showTemperatureList)
                Toggle("Live charts", isOn: $chart.showCharts)
                // Beside "Live charts" because it is the same kind of decision —
                // what the popover shows — and this pane is where those live.
                // It first shipped in General next to the experimental switch
                // that enables the feature, which put one popover toggle in a
                // different tab from all the others.
                if state.isInsideEnabled {
                    Toggle("Inside cooling view", isOn: $state.showsInsideInPopover)
                        .help("A compact live drawing of the heat path, above the charts.")
                }
                Toggle("Smoothly animate readings", isOn: $chart.smoothReadings)
                    .help(
                        "Numbers roll in place and gauge bars slide to each new reading; off makes them snap instantly"
                    )
            }
            if chart.showCharts {
                Section("Charts") {
                    Picker("Time window", selection: $chart.window) {
                        ForEach(ChartStore.Window.allCases) { window in
                            Text(window.title).tag(window)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("CPU graph", isOn: $chart.showCPU)
                    Toggle("GPU graph", isOn: $chart.showGPU)
                    Toggle("Fan RPM graphs", isOn: $chart.showFans)
                    Toggle("Power draw graph", isOn: $chart.showPower)
                    Toggle("Min/max band", isOn: $chart.showBand)
                    Toggle("Average / target line", isOn: $chart.showSecondary)
                    Picker("Height", selection: $chart.height) {
                        ForEach(ChartHeight.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
