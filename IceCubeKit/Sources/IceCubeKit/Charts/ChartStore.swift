// ChartStore.swift — accumulates snapshot history into fixed chart rows, downsampled off the main actor.

import Foundation

/// Ingests one ``SMCSnapshot`` per second and serves the dashboard's chart
/// rows for any time window, already downsampled to the point budget.
///
/// Being an actor puts ring-buffer upkeep and downsampling **off the main
/// actor** (a PLAN.md §1.2 requirement) — the UI awaits ready-to-render rows.
///
/// Anti-jump rules: the row set is fixed after the first ingest (CPU row iff
/// any `Tp*` sensor exists, GPU row iff any `Tg*`, one row per fan), and each
/// row carries a **fixed y-axis domain** so axes never rescale mid-glance.
public actor ChartStore {
    /// 1 sample/s × 3600 = the 60-minute maximum window.
    public static let capacity = 3600
    /// Hard visible-point budget per series (PLAN.md §1.2).
    public static let pointBudget = 600
    /// A selectable chart time window: 1 / 5 / 15 / 60 minutes.
    ///
    /// One type rather than two parallel arrays kept in sync by a comment:
    /// the seconds used to live here and the human titles in the app target's
    /// `DashboardView`, indexed by a bare `Int` that three separate call sites
    /// each clamped differently. Adding a window is now a single-site change
    /// and the seconds/title pairing is a compiler-checked `switch`.
    ///
    /// Raw values are the old array indices, so a stored preference migrates
    /// with no shim.
    public enum Window: Int, CaseIterable, Sendable, Identifiable {
        case oneMinute = 0
        case fiveMinutes
        case fifteenMinutes
        case oneHour

        public var id: Int {
            rawValue
        }

        /// The window's span.
        public var seconds: TimeInterval {
            switch self {
            case .oneMinute: 60
            case .fiveMinutes: 300
            case .fifteenMinutes: 900
            case .oneHour: 3600
            }
        }

        /// Human label for the picker and the dashboard caption.
        public var title: String {
            switch self {
            case .oneMinute: "1 min"
            case .fiveMinutes: "5 min"
            case .fifteenMinutes: "15 min"
            case .oneHour: "1 hr"
            }
        }

        /// What a fresh install opens on.
        public static let firstRunDefault = Window.fiveMinutes

        /// Resolves a persisted raw value, where `nil` means "never set".
        ///
        /// This exists as a function — rather than a `Window(rawValue:) ?? …`
        /// at the call site — because that shorthand is a trap here and it
        /// already cost a regression once. `UserDefaults.integer(forKey:)`
        /// returns **0 for a missing key**, and 0 is a *valid* raw value
        /// (`.oneMinute`), so the `??` fallback never fires and every fresh
        /// install silently opens on a 1-minute window. Callers must pass
        /// `nil` for absent, which this signature forces them to think about.
        public static func stored(_ raw: Int?) -> Window {
            guard let raw else { return firstRunDefault }
            return Window(rawValue: raw) ?? firstRunDefault
        }
    }

    /// The unit a row's values are expressed in.
    ///
    /// An enum rather than a free-form `String`: this crosses the module
    /// boundary into the app target, where it gates the Fahrenheit conversion.
    /// A stray `"C"` or a Unicode normalization difference would silently
    /// disable that conversion while the axis still claimed °F.
    public enum Unit: String, Sendable, Equatable {
        case celsius = "°C"
        case rpm = "RPM"
        case watts = "W"
    }

    /// One renderable series: a band (bucket min…max) plus its average line.
    public struct Series: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        /// Secondary series (fan target) render thinner/grayer than primary.
        public let isSecondary: Bool
        public let buckets: [ChartBucket]
        public let stats: SeriesStats?
    }

    /// One chart row of the dashboard: title, unit, fixed y domain, series.
    public struct Row: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        /// Displayed unit.
        public let unit: Unit
        /// Fixed axis range — never rescales while you watch (anti-jump).
        public let yDomainMin: Double
        public let yDomainMax: Double
        public let series: [Series]
    }

    private var cpuMax = RingBuffer<ChartSample>(capacity: ChartStore.capacity)
    private var cpuAvg = RingBuffer<ChartSample>(capacity: ChartStore.capacity)
    private var gpuMax = RingBuffer<ChartSample>(capacity: ChartStore.capacity)
    private var power = RingBuffer<ChartSample>(capacity: ChartStore.capacity)
    private var fanActual: [Int: RingBuffer<ChartSample>] = [:]
    private var fanTarget: [Int: RingBuffer<ChartSample>] = [:]

    /// The anti-jump row contract. `fanMeta` is fixed after the first ingest;
    /// `hasCPU`/`hasGPU` latch **on** and never off, so a row can appear once
    /// and then never disappears.
    private var hasCPU = false
    private var hasGPU = false
    /// Latches on like `hasCPU`/`hasGPU`, and for the same anti-jump reason: a
    /// Mac either has a power key or it does not, but `power()` can return nil
    /// for a tick on one that does, and a row must not blink out.
    private var hasPower = false
    private var fanMeta: [(id: Int, name: String, maxRPM: Double)] = []
    private var didDiscoverRows = false
    private var lastIngest: Date?

    public init() {}

    // MARK: - Ingest (1 Hz)

    /// Records one poll into the per-series ring buffers.
    ///
    /// Called at the polling cadence (1 Hz by default) whatever the UI is
    /// doing: recording continues while the popover is closed and while the
    /// display is paused, because pause freezes the picture, not the history.
    /// Buffers are fixed at 3600 samples, so an hour is retained and the memory
    /// cost cannot grow with uptime.
    public func ingest(_ snapshot: SMCSnapshot) {
        // Classification lives in SMCKeyMaps so the chart and the popover's
        // compact readout cannot disagree about what counts as a CPU sensor.
        let cpuValues = snapshot.temperatures.filter { $0.sensorClass == .cpu }.map(\.celsius)
        let gpuValues = snapshot.temperatures.filter { $0.sensorClass == .gpu }.map(\.celsius)

        // Row discovery is MONOTONE for sensors, not a one-shot latch. The
        // published sensor list grows when a power-gated cluster first reports
        // (see `SensorAdmission`), so a launch that begins with the GPU block
        // asleep would otherwise have no GPU row for the life of the process —
        // no crash, no log line, just a chart silently missing a series.
        hasCPU = hasCPU || !cpuValues.isEmpty
        hasGPU = hasGPU || !gpuValues.isEmpty
        hasPower = hasPower || snapshot.power != nil
        // Fans still latch: `FNum` is answered on the first poll and a fan
        // never turns up late.
        if !didDiscoverRows {
            fanMeta = snapshot.fans.map { ($0.id, $0.name, $0.maxRPM) }
            didDiscoverRows = true
        }

        let t = snapshot.date
        if let top = cpuValues.max() {
            cpuMax.append(ChartSample(time: t, value: top))
            cpuAvg.append(ChartSample(time: t, value: cpuValues.reduce(0, +) / Double(cpuValues.count)))
        }
        if let top = gpuValues.max() {
            gpuMax.append(ChartSample(time: t, value: top))
        }
        if let watts = snapshot.power {
            power.append(ChartSample(time: t, value: watts))
        }
        for fan in snapshot.fans {
            fanActual[fan.id, default: RingBuffer(capacity: Self.capacity)]
                .append(ChartSample(time: t, value: fan.actualRPM))
            fanTarget[fan.id, default: RingBuffer(capacity: Self.capacity)]
                .append(ChartSample(time: t, value: fan.targetRPM))
        }
        lastIngest = t
    }

    // MARK: - Rows for rendering

    /// The dashboard rows for the trailing `window` seconds, downsampled to
    /// the point budget. The x range ends at the latest ingested sample.
    public func rows(window: TimeInterval, budget: Int = ChartStore.pointBudget) -> [Row] {
        guard let end = lastIngest else { return [] }
        let start = end.addingTimeInterval(-window)

        var rows: [Row] = []
        if hasCPU {
            rows.append(Row(
                id: "cpu", title: "CPU", unit: .celsius, yDomainMin: 20, yDomainMax: 110,
                series: [
                    series(id: "cpu.max", label: "Hottest", from: cpuMax, start: start, end: end, budget: budget),
                    series(
                        id: "cpu.avg",
                        label: "Average",
                        from: cpuAvg,
                        start: start,
                        end: end,
                        budget: budget,
                        secondary: true
                    ),
                ]
            ))
        }
        if hasGPU {
            rows.append(Row(
                id: "gpu", title: "GPU", unit: .celsius, yDomainMin: 20, yDomainMax: 110,
                series: [
                    series(id: "gpu.max", label: "Hottest", from: gpuMax, start: start, end: end, budget: budget),
                ]
            ))
        }
        if hasPower {
            // Y domain fixed at 0…120 W rather than scaled to the observed
            // maximum: the anti-jump rule forbids an axis that rescales while
            // you watch, and 120 W comfortably covers an M-series laptop SoC
            // (docs/SMC-KEYS.md measured ~52 W peak on Mac14,9).
            rows.append(Row(
                id: "power", title: "Power", unit: .watts, yDomainMin: 0, yDomainMax: 120,
                series: [
                    series(id: "power.watts", label: "Package", from: power, start: start, end: end, budget: budget),
                ]
            ))
        }
        for fan in fanMeta {
            rows.append(Row(
                id: "fan.\(fan.id)", title: "\(fan.name) Fan", unit: .rpm,
                yDomainMin: 0, yDomainMax: fan.maxRPM > 0 ? fan.maxRPM * 1.05 : 7000,
                series: [
                    series(
                        id: "fan.\(fan.id).actual",
                        label: "Actual",
                        from: fanActual[fan.id],
                        start: start,
                        end: end,
                        budget: budget
                    ),
                    series(
                        id: "fan.\(fan.id).target",
                        label: "Target",
                        from: fanTarget[fan.id],
                        start: start,
                        end: end,
                        budget: budget,
                        secondary: true
                    ),
                ]
            ))
        }
        return rows
    }

    // MARK: - CSV export

    /// The full raw history (up to 60 min per series) as CSV:
    /// `unixTime,series,value` — temperatures in °C, fan speeds in RPM.
    public func csv() -> String {
        var lines = ["unixTime,series,value"]
        func dump(_ name: String, _ buffer: RingBuffer<ChartSample>) {
            for sample in buffer.elements {
                lines.append("\(Int(sample.time.timeIntervalSince1970)),\(name),\(sample.value)")
            }
        }
        if hasCPU {
            dump("cpu.max.celsius", cpuMax)
            dump("cpu.avg.celsius", cpuAvg)
        }
        if hasGPU {
            dump("gpu.max.celsius", gpuMax)
        }
        for fan in fanMeta {
            if let actual = fanActual[fan.id] {
                dump("fan.\(fan.id).actual.rpm", actual)
            }
            if let target = fanTarget[fan.id] {
                dump("fan.\(fan.id).target.rpm", target)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func series(
        id: String, label: String, from buffer: RingBuffer<ChartSample>?,
        start: Date, end: Date, budget: Int, secondary: Bool = false
    ) -> Series {
        let samples = buffer?.elements ?? []
        return Series(
            id: id,
            label: label,
            isSecondary: secondary,
            buckets: ChartDownsampler.downsample(samples, from: start, to: end, budget: budget),
            stats: ChartDownsampler.stats(samples, from: start, to: end)
        )
    }
}
