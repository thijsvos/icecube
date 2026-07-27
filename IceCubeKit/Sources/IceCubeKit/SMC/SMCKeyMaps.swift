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

    /// Candidate keys to *probe* when the model has no curated map.
    ///
    /// The app can afford the real fallback — enumerate every `T***` key of
    /// type `flt` (`SystemSMCProvider.enumeratedTemperatureSensors`). The root
    /// daemon deliberately cannot: `SMCWritePort` is a minimal write surface
    /// with no key-enumeration API, and giving the daemon one is a larger
    /// change than a safety fix should smuggle in.
    ///
    /// So the daemon probes this superset with `hasKey` instead. It is not
    /// exhaustive and the labels are approximate — but the alternative is what
    /// shipped before: on any non-M2 Mac the daemon read **zero** sensors
    /// forever, which silently disabled the temperature ceiling AND the
    /// guardian while the app's UI showed correct temperatures. Probing a
    /// superset is strictly better than being blind.
    ///
    /// Keys beyond the M2 list are the P/E-core and GPU blocks that recur
    /// across M1/M3/M4 with shifted suffixes, plus the stable non-core sensors.
    public static let fallbackCandidateSensors: [SensorDescriptor] = {
        var candidates = m2GenerationSensors
        let extraCores = [
            "Tp02", "Tp06", "Tp0A", "Tp0E", "Tp0M", "Tp0T", "Tp0Y", "Tp0c",
            "Tp0g", "Tp0k", "Tp1a", "Tp1e", "Tp1i", "Tp1m", "Tp1q", "Tp1u",
        ]
        let extraGPU = ["Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg1f", "Tg1j"]
        let extraOther = ["TaLC", "TaRC", "Ts0S", "Ts1S", "TH0a", "TH0b", "Tm0P"]
        candidates += extraCores.map { SensorDescriptor(key: $0, label: "CPU core \($0)") }
        candidates += extraGPU.map { SensorDescriptor(key: $0, label: "GPU \($0)") }
        candidates += extraOther.map { SensorDescriptor(key: $0, label: $0) }
        return candidates
    }()

    /// The sanity filter for the enumeration fallback (and for dropping glitched
    /// readings): a real Mac temperature is above 10 °C (a dead or unpopulated
    /// sensor reads 0) and below 120 °C (beyond silicon limits).
    ///
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

    /// What kind of thing a sensor key measures.
    ///
    /// The die/ambient split selects the safety ceiling; the CPU/GPU split
    /// drives the compact readout and the chart rows. Both used to be
    /// hand-rolled at the call sites, and they had already drifted — the
    /// popover counted E-cores as CPU while the CPU chart did not.
    public enum SensorClass: Sendable, Equatable {
        /// CPU silicon: P-cores (`Tp*`) and E-cores (`Te*`).
        case cpu
        /// GPU silicon (`Tg*`).
        case gpu
        /// Other die-class silicon (`Tf*`, `Tc*`).
        case otherDie
        /// Everything else: airflow, proximity, SSD, battery…
        case ambient

        /// Die-class sensors legitimately run hotter, hence a higher ceiling.
        public var isDie: Bool {
            self != .ambient
        }
    }

    /// Classifies a sensor key. The one place prefixes are matched.
    public static func classify(_ key: String) -> SensorClass {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") {
            return .cpu
        }
        if key.hasPrefix("Tg") {
            return .gpu
        }
        if key.hasPrefix("Tf") || key.hasPrefix("Tc") {
            return .otherDie
        }
        return .ambient
    }

    /// Whether `key` names a die-class sensor.
    public static func isDieKey(_ key: String) -> Bool {
        classify(key).isDie
    }
}
