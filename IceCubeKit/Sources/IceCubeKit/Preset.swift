// Preset.swift — a named curve the user can pick from the popover.

import Foundation

/// A named, user-selectable fan configuration.
public struct Preset: Identifiable, Sendable, Codable, Equatable {
    /// Which built-in a preset is. Every case means **Ice Cube is driving**;
    /// there is deliberately no "hand the fans back" kind any more.
    public enum Kind: String, Sendable, Codable {
        case quiet, balanced, cold, max, custom

        /// What picking this actually does, in one sentence, for a tooltip.
        ///
        /// There used to be an `auto` kind here — "hand the fans back to macOS"
        /// — carrying by far the longest explanation, because it was the one
        /// people misread: in a fan-control app "Auto" reads as "the app manages
        /// this for me" and it meant the exact opposite. It was renamed, then
        /// fenced off behind a divider, and finally removed altogether: every
        /// preset now means Ice Cube is driving, so there is nothing left to
        /// misread. Turning fan control off lives in Settings, where an exit
        /// belongs.
        public var explanation: String {
            switch self {
            case .quiet:
                "Silent at idle. Fans only start climbing at 60 °C, full speed by 90 °C."
            case .balanced:
                "The all-rounder: airflow from 45 °C, full speed by 85 °C. "
                    + "Cooler than macOS, quieter than Cold."
            case .cold:
                "As cool as the hardware allows, with a steady hum rather than "
                    + "spikes — a strong constant speed at idle, full tilt above 80 °C."
            case .max:
                "Full speed, always. Loud, and only useful for sustained heavy work."
            case .custom:
                "Your own saved curve."
            }
        }
    }

    public let id: UUID
    public var name: String
    public var kind: Kind
    public var config: FanConfig

    public init(id: UUID = UUID(), name: String, kind: Kind, config: FanConfig) {
        self.id = id
        self.name = name
        self.kind = kind
        self.config = config
    }
}
