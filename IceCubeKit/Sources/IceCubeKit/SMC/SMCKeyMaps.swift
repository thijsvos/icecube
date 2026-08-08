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
    ///
    /// ## The `Te`/`Tf` gap, and what it cost
    ///
    /// Until 2026-08-07 this list contained **no `Te`, `Tf` or `Tc` key at
    /// all** — while `docs/SMC-KEYS.md` recorded, one file away, that M3's die
    /// sensors are `Te0*`/`Tf*` and M4's are `Te0*`/`Tp0*`/`Tm*p`.
    ///
    /// On such a Mac the probe below could only ever find airflow, battery, SSD
    /// and wireless keys, so `SensorReader`'s `hasDie` guard was never
    /// satisfied. The daemon read as **blind on every tick**, `SafetyMonitor`
    /// reverted manual and curve control after three of them, and every curve
    /// the user applied came undone about six seconds later — while the app
    /// showed correct temperatures throughout, because the app enumerates keys
    /// and the daemon cannot. Silent, and the exact shape of the bug the note
    /// above says already shipped once.
    ///
    /// ## The suffixes are a sweep, not knowledge
    ///
    /// Nobody here has an M3. The suffix sets follow the shape the M2 map uses
    /// (`0` then a digit or letter) rather than any observed key list, and that
    /// is safe because of how they are consumed: candidates are **existence
    /// probed**, so a wrong guess costs one read and produces nothing, and
    /// `SensorReader` refuses to cache a set that contains no die key — so a
    /// sweep that finds nothing leaves the daemon exactly where it was rather
    /// than worse. A diagnostics report from a real M3 should replace this
    /// guesswork with a curated map, which is what `curatedSensors(forModel:)`
    /// is for.
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

        // M3/M4 die blocks. Generated rather than listed: 36 suffixes per prefix
        // is a wide enough sweep to land on whatever the shipping keys are, and
        // spelling them out would be 100 lines of invented constants that read
        // as though someone had measured them.
        let sweep = (0 ... 9).map(String.init) + (UnicodeScalar("A").value ... UnicodeScalar("Z").value)
            .compactMap { UnicodeScalar($0).map { String(Character($0)) } }
        candidates += sweep.map { SensorDescriptor(key: "Te0\($0)", label: "CPU E-core Te0\($0)") }
        candidates += sweep.map { SensorDescriptor(key: "Tf0\($0)", label: "Die Tf0\($0)") }
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
    /// SINGLE SOURCE OF TRUTH for the die/ambient split, which is
    /// safety-relevant: it selects the higher temperature ceiling. Do not
    /// re-inline these prefixes anywhere.
    ///
    /// That note used to sit on a `dieKeyPrefixes` array declared beside this
    /// function — and **nothing referenced it**, while this function inlined
    /// the same five prefixes. Adding a die prefix there, exactly as its
    /// comment instructed, would have changed no ceiling and no curve input.
    /// A flat array could not have worked anyway: these five prefixes map to
    /// three different classes, which is the shape the array could not carry.
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

    /// Whether `key` names an **airflow** sensor — `TaLP`, `TaRF` and the
    /// `TaLC`/`TaRC` variants in ``fallbackCandidateSensors``.
    ///
    /// Its own predicate rather than a use of ``classify(_:)`` because
    /// `.ambient` is that function's catch-all: it collects airflow *and* SSD,
    /// battery, wireless and proximity, which are attached to warm components
    /// and are not intake air. ``CoolingEfficiency`` needs the narrow set —
    /// picking the coolest `.ambient` sensor would silently start measuring
    /// against a battery on a Mac whose airflow keys are missing, and produce a
    /// plausible-looking number describing nothing.
    public static func isAirflowKey(_ key: String) -> Bool {
        key.hasPrefix("Ta")
    }

    // MARK: - SoC power (the feedforward signal)

    /// Candidate keys for **total system power in watts**, best first.
    ///
    /// Named carefully: `PSTR` is the whole machine, not the SoC package. The
    /// doc below records the measurement; several places once called this "SoC
    /// power" and were wrong.
    ///
    /// Reported for diagnostics: when someone says "my Mac is hot", watts are
    /// what distinguish *"you are running something heavy"* from *"cooling is
    /// broken"*, and neither temperature nor RPM can tell those apart.
    ///
    /// Ordered, not merged: the first key that exists **and** reads plausibly
    /// wins, so a Mac exposing several power rails gets the one that means
    /// "the whole SoC" rather than a single rail that would under-report.
    ///
    /// - `PSTR` — system total power. Present and live on Mac14,9 (measured
    ///   2026-07-28: 19.6 W idle, ~52 W peak under a Release build).
    /// - `PDTR` — DC-in / adapter power. Includes charging, so it is a worse
    ///   proxy for SoC heat, but it is a signal where `PSTR` is absent.
    ///
    /// Deliberately short. This list is a guess about *other people's* Macs,
    /// and the honest fallback is `nil` — no reading — rather than a wrong key
    /// confidently read. `icecube-diag --json` dumps every key, so a model
    /// report can extend this from evidence rather than from hope.
    ///
    /// **Do not build fan control on this signal without re-reading
    /// docs/SMC-KEYS.md first.** Driving the curve from power was tried on
    /// 2026-07-28 and measured as unusable on this hardware; the finding and
    /// its numbers are recorded there so the idea is not re-derived from
    /// first principles a third time.
    public static let powerKeyCandidates = ["PSTR", "PDTR"]

    /// The sanity filter for a power reading, in watts.
    ///
    /// An unpopulated rail reads 0; a misdecoded key reads nonsense. A laptop
    /// SoC that is genuinely drawing power sits between these bounds — and the
    /// upper bound is deliberately generous (a Mac Pro pulls far more than any
    /// laptop) because the cost of rejecting a real reading is losing the
    /// reading, while a wrong one is only ever displayed, never acted on.
    public static func isPlausiblePower(_ watts: Double) -> Bool {
        watts > 0.5 && watts < 400
    }
}
