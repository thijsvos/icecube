// AppSettings.swift — user-preference enums shared by the settings UI and display code.

import Foundation

/// Display unit for temperatures. Storage and all math stay in °C — this
/// only converts at the last moment, in UI.
enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius
    case fahrenheit

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .celsius: "°C"
        case .fahrenheit: "°F"
        }
    }

    /// Converts a °C value into this unit for display.
    func display(_ celsius: Double) -> Double {
        switch self {
        case .celsius: celsius
        case .fahrenheit: celsius * 9 / 5 + 32
        }
    }

    /// Compact reading like `"62°"` (unit implied by context).
    func text(_ celsius: Double) -> String {
        "\(Int(display(celsius).rounded()))°"
    }
}

/// How often the app samples the SMC for display (the daemon's own 2 s
/// safety tick is independent and never user-configurable).
enum PollInterval: Int, CaseIterable, Identifiable {
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5

    var id: Int {
        rawValue
    }

    var title: String {
        "\(rawValue) s"
    }
}
