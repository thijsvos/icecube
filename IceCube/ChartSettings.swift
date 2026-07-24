// ChartSettings.swift — user-customizable chart/display preferences (the tinkerer surface), persisted.

import Foundation
import IceCubeKit
import Observation

/// How tall each chart row draws.
enum ChartHeight: String, CaseIterable, Identifiable {
    case compact, regular, tall

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .regular: "Regular"
        case .tall: "Tall"
        }
    }

    var points: CGFloat {
        switch self {
        case .compact: 44
        case .regular: 64
        case .tall: 92
        }
    }
}

/// Everything the user can tune about the live charts. Kept out of `AppState`
/// (already the polling/control hub) so the display surface is a
/// self-contained unit — and so the popover can be made as minimal or as
/// detailed as the user wants. Each property persists itself to `UserDefaults`
/// on change; `Key` centralizes the string keys.
@MainActor
@Observable
final class ChartSettings {
    private enum Key {
        static let show = "charts.show", window = "charts.window"
        static let cpu = "charts.cpu", gpu = "charts.gpu", fans = "charts.fans"
        static let band = "charts.band", secondary = "charts.secondary"
        static let height = "charts.height", tempList = "charts.templist"
        static let controls = "menu.controls"
    }

    /// Master switch. Off → the popover hides the whole chart section for a
    /// minimalist menu-bar app (fans + control + a compact temp line only).
    var showCharts: Bool {
        didSet { defaults.set(showCharts, forKey: Key.show) }
    }

    /// Show the fan-control panel (presets, manual, curves) in the menu.
    /// Off → a pure monitoring readout (temperatures + fan RPM only); control
    /// still lives in the Settings window.
    var showControls: Bool {
        didSet { defaults.set(showControls, forKey: Key.controls) }
    }

    /// Default time window, as an index into `ChartStore.windows`.
    var windowIndex: Int {
        didSet { defaults.set(windowIndex, forKey: Key.window) }
    }

    /// Per-row visibility — tinkerers pick exactly which graphs they want.
    var showCPU: Bool {
        didSet { defaults.set(showCPU, forKey: Key.cpu) }
    }

    var showGPU: Bool {
        didSet { defaults.set(showGPU, forKey: Key.gpu) }
    }

    var showFans: Bool {
        didSet { defaults.set(showFans, forKey: Key.fans) }
    }

    /// Draw the min/max range band (off = clean single line).
    var showBand: Bool {
        didSet { defaults.set(showBand, forKey: Key.band) }
    }

    /// Draw the secondary series (CPU average line, fan target line).
    var showSecondary: Bool {
        didSet { defaults.set(showSecondary, forKey: Key.secondary) }
    }

    /// Chart row height.
    var height: ChartHeight {
        didSet { defaults.set(height.rawValue, forKey: Key.height) }
    }

    /// Show the per-sensor temperature list in the popover (the Sensors window
    /// always has the exhaustive view).
    var showTemperatureList: Bool {
        didSet { defaults.set(showTemperatureList, forKey: Key.tempList) }
    }

    private let defaults = UserDefaults.standard

    init() {
        // Use a local `d` (not `self.defaults`) so the helper doesn't capture
        // self before stored properties are initialized. `object(forKey:) == nil`
        // distinguishes "never set" from "set false" for first-run defaults.
        let d = UserDefaults.standard
        func bool(_ key: String, _ def: Bool) -> Bool {
            d.object(forKey: key) == nil ? def : d.bool(forKey: key)
        }
        showCharts = bool(Key.show, true)
        showControls = bool(Key.controls, true)
        let storedWindow = d.object(forKey: Key.window) == nil ? 1 : d.integer(forKey: Key.window)
        windowIndex = min(max(storedWindow, 0), ChartStore.windows.count - 1)
        showCPU = bool(Key.cpu, true)
        showGPU = bool(Key.gpu, true)
        showFans = bool(Key.fans, true)
        showBand = bool(Key.band, true)
        showSecondary = bool(Key.secondary, true)
        height = ChartHeight(rawValue: d.string(forKey: Key.height) ?? "") ?? .regular
        showTemperatureList = bool(Key.tempList, false)
    }

    /// Whether a `ChartStore.Row` id passes the current row-visibility filter.
    func includesRow(id: String) -> Bool {
        if id == "cpu" {
            return showCPU
        }
        if id == "gpu" {
            return showGPU
        }
        if id.hasPrefix("fan.") {
            return showFans
        }
        return true
    }
}
