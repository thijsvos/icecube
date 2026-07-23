// SMCKeyMaps.swift — curated per-generation temperature-key maps and the fallback plausibility filter.

import Foundation

/// Which temperature keys mean what, per Apple Silicon generation.
///
/// Apple changes sensor keys with nearly every SoC generation and never
/// documents them, so this map is **best-effort community knowledge** (seeded
/// from exelban/Stats' tables, cross-checked against narugit/smctemp — the two
/// disagree on some M2 P-core labels, which is exactly why the diagnostics
/// pipeline exists). Machines not in the map fall back to enumerating every
/// `T***` key of type `flt` and keeping plausible values — uglier labels,
/// same data — and their owners can contribute a mapping via a diagnostics
/// report (PLAN.md §3.3).
public enum SMCKeyMaps {
    /// A curated sensor: its SMC key and a human-readable label.
    public struct SensorDescriptor: Sendable, Equatable {
        public let key: String
        public let label: String

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    /// Model identifiers (`hw.model`) of the M2 generation, the only curated
    /// family so far — it is what the project's test hardware (Mac14,9) runs.
    /// Includes fanless machines (M2 Air): temperature reads work there too.
    private static let m2GenerationModels: Set<String> = [
        "Mac14,2", "Mac14,15", // MacBook Air 13"/15" M2 (fanless)
        "Mac14,7", // MacBook Pro 13" M2
        "Mac14,5", "Mac14,9", // MacBook Pro 14" M2 Pro / M2 Max
        "Mac14,6", "Mac14,10", // MacBook Pro 16" M2 Pro / M2 Max
        "Mac14,3", "Mac14,12", // Mac mini M2 / M2 Pro
        "Mac14,13", "Mac14,14", // Mac Studio M2 Max / M2 Ultra
    ]

    /// The M2-generation map. Core-count varies within the family (an M2 Pro
    /// has fewer P-cores than an M2 Max), so `SystemSMCProvider` intersects
    /// this list with the keys that actually exist on the machine.
    private static let m2GenerationSensors: [SensorDescriptor] = [
        SensorDescriptor(key: "Tp01", label: "CPU P-core 1"),
        SensorDescriptor(key: "Tp05", label: "CPU P-core 2"),
        SensorDescriptor(key: "Tp09", label: "CPU P-core 3"),
        SensorDescriptor(key: "Tp0D", label: "CPU P-core 4"),
        SensorDescriptor(key: "Tp0X", label: "CPU P-core 5"),
        SensorDescriptor(key: "Tp0b", label: "CPU P-core 6"),
        SensorDescriptor(key: "Tp0f", label: "CPU P-core 7"),
        SensorDescriptor(key: "Tp0j", label: "CPU P-core 8"),
        SensorDescriptor(key: "Tp1h", label: "CPU E-core 1"),
        SensorDescriptor(key: "Tp1t", label: "CPU E-core 2"),
        SensorDescriptor(key: "Tp1p", label: "CPU E-core 3"),
        SensorDescriptor(key: "Tp1l", label: "CPU E-core 4"),
        SensorDescriptor(key: "Tg0f", label: "GPU 1"),
        SensorDescriptor(key: "Tg0j", label: "GPU 2"),
        SensorDescriptor(key: "TaLP", label: "Airflow Left"),
        SensorDescriptor(key: "TaRF", label: "Airflow Right"),
        SensorDescriptor(key: "TH0x", label: "SSD"),
        SensorDescriptor(key: "TB1T", label: "Battery 1"),
        SensorDescriptor(key: "TB2T", label: "Battery 2"),
        SensorDescriptor(key: "TW0P", label: "Wireless"),
    ]

    /// The curated sensor list for `model` (a `hw.model` string like
    /// `"Mac14,9"`), or `nil` when the model isn't mapped yet and the caller
    /// should use the enumeration fallback.
    public static func curatedSensors(forModel model: String) -> [SensorDescriptor]? {
        m2GenerationModels.contains(model) ? m2GenerationSensors : nil
    }

    /// The sanity filter for the enumeration fallback (and for dropping
    /// glitched readings): a real Mac temperature is above 10 °C (a dead or
    /// unpopulated sensor reads 0) and below 120 °C (beyond silicon limits).
    /// Bounds follow narugit/smctemp's field-tested filter.
    public static func isPlausibleTemperature(_ celsius: Double) -> Bool {
        celsius > 10 && celsius < 120
    }

    /// Key prefixes for **die-class** silicon sensors (CPU/GPU cores) — they
    /// legitimately run hotter than proximity/airflow sensors, which is why
    /// the safety ceiling and the curve input treat them as a class.
    ///
    /// SINGLE SOURCE OF TRUTH: this classification is safety-relevant (it
    /// selects the higher temperature ceiling), so it must live in exactly
    /// one place. Do not re-inline the prefix list anywhere.
    public static let dieKeyPrefixes = ["Tp", "Tg", "Te", "Tf", "Tc"]

    /// Whether `key` names a die-class sensor.
    public static func isDieKey(_ key: String) -> Bool {
        dieKeyPrefixes.contains(where: key.hasPrefix)
    }
}
