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

/// Everything the user can tune about the live charts.
///
/// Kept out of `AppState` (already the polling/control hub) so the display
/// surface is a self-contained unit — and so the popover can be made as
/// minimal or as detailed as the user wants. Each property persists itself to
/// `UserDefaults` on change; `Key` centralizes the string keys.
@Observable
final class ChartSettings {
    private enum Key {
        static let show = "charts.show", window = "charts.window"
        static let cpu = "charts.cpu", gpu = "charts.gpu", fans = "charts.fans"
        static let power = "charts.power"
        static let band = "charts.band", secondary = "charts.secondary"
        static let height = "charts.height", tempList = "charts.templist"
        static let controls = "menu.controls"
        static let smooth = "menu.smoothReadings"
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

    /// Default time window.
    var window: ChartStore.Window {
        didSet { defaults.set(window.rawValue, forKey: Key.window) }
    }

    /// Per-row visibility — tinkerers pick exactly which graphs they want.
    var showCPU: Bool {
        didSet { defaults.set(showCPU, forKey: Key.cpu) }
    }

    var showGPU: Bool {
        didSet { defaults.set(showGPU, forKey: Key.gpu) }
    }

    /// Off by default, unlike the other row families.
    ///
    /// Watts is the newest row and the popover is already dense — the owner's
    /// standing note is that the popover must not become "too much info". The
    /// always-visible home for power is the Sensors window, which has room to
    /// explain what the number means; this toggle is for someone who wants it
    /// on the live stack too.
    var showPower: Bool {
        didSet { defaults.set(showPower, forKey: Key.power) }
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

    /// Smoothly glide the live numbers and gauge bars to each new reading
    /// (digits roll in place, the bar slides). Off → values snap instantly,
    /// for anyone who prefers no motion at all.
    var smoothReadings: Bool {
        didSet { defaults.set(smoothReadings, forKey: Key.smooth) }
    }

    private let defaults: any KeyValueStore

    /// - Parameter defaults: where the twelve preferences live. Injected, and
    ///   that is load-bearing: this used to read `UserDefaults.standard`
    ///   directly while every other seam in the graph was substituted, so a
    ///   simulated launch wrote chart settings into the owner's real
    ///   preferences domain — the same hole `CompositionRoot` was rebuilt to
    ///   close for the daemon, the presets file and the power watcher.
    init(defaults: any KeyValueStore = UserDefaults.standard) {
        self.defaults = defaults
        // Use a local `d` (not `self.defaults`) so the helper doesn't capture
        // self before stored properties are initialized. `object(forKey:) == nil`
        // distinguishes "never set" from "set false" for first-run defaults.
        let d = defaults
        func bool(_ key: String, _ def: Bool) -> Bool {
            d.object(forKey: key) == nil ? def : d.bool(forKey: key)
        }
        showCharts = bool(Key.show, true)
        showControls = bool(Key.controls, true)
        // Raw values are the old array indices, so an existing preference
        // migrates as-is. The absent/present distinction is load-bearing and
        // lives in `Window.stored(_:)` — see the trap documented there.
        window = .stored(d.object(forKey: Key.window) == nil ? nil : d.integer(forKey: Key.window))
        showCPU = bool(Key.cpu, true)
        showGPU = bool(Key.gpu, true)
        showFans = bool(Key.fans, true)
        showPower = bool(Key.power, false)
        showBand = bool(Key.band, true)
        showSecondary = bool(Key.secondary, true)
        height = ChartHeight(rawValue: d.string(forKey: Key.height) ?? "") ?? .regular
        showTemperatureList = bool(Key.tempList, false)
        smoothReadings = bool(Key.smooth, true)
    }

    /// Whether a `ChartStore.Row` id passes the current row-visibility filter.
    func includesRow(id: String) -> Bool {
        if id == "cpu" {
            return showCPU
        }
        if id == "gpu" {
            return showGPU
        }
        if id == "power" {
            return showPower
        }
        if id.hasPrefix("fan.") {
            return showFans
        }
        return true
    }
}
