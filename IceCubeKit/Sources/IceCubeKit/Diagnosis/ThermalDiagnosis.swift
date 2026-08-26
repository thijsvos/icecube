// ThermalDiagnosis.swift — the four questions behind "why is my Mac hot?", answered only where the evidence allows.

import Foundation

/// Turns everything Ice Cube measures into an answer rather than a dashboard.
///
/// The app already shows temperature, fan speed, watts and °C/W. It has never
/// **said** anything — the reader is handed five numbers and left to do the
/// reasoning. This type does that reasoning, and its whole design constraint is
/// that it may only make claims the evidence supports.
///
/// ## The four questions, in order
///
/// 1. **Is it hot?** — the die against the ceiling its own class is held to.
///    Always answerable; needs one sensor read.
/// 2. **Does the work explain it?** — watts in, degrees of rise out. Refuses
///    until ``CoolingEfficiency`` has settled.
/// 3. **What is producing it?** — which silicon leads, which processes draw,
///    and how much power is not attributable at all.
/// 4. **Is cooling doing all it can?** — what the curve asked for versus what
///    the fans achieved. The actionable one.
///
/// ## What it deliberately will not say
///
/// **"Your cooling is degrading."** Ice Cube can answer that now — settled
/// readings persist across launches and ``CoolingTrend`` turns them into a
/// verdict (question 5 of `docs/DIAGNOSIS.md`) — but it is a claim about months,
/// and this type is a claim about one moment: it is handed a snapshot, no
/// history at all, and could only ever fake it. The one load-versus-cooling
/// claim made here is ``Load/hotWithoutLoad(watts:celsius:)``, which needs no
/// baseline because a hot die at a near-idle wattage is anomalous on any Mac.
/// `R` itself stays not comparable between machines — the ambient reference is a
/// sensor inside the case — which is why nothing else in these four answers is a
/// verdict about cooling health. (This said "Ice Cube keeps no history across
/// launches" until 2026-08-16, which stopped being true when the history
/// shipped.)
///
/// Pure by construction: no I/O, no clock, no hardware. Every input arrives as
/// a parameter so the whole verdict is exercised against scripted values.
public enum ThermalDiagnosis {
    // MARK: - Constants, and what sets them

    /// Die headroom (°C below its ceiling) at or above which nothing is warm.
    ///
    /// `SafetyMonitor.Limits.dieCeiling` is 104 °C, so this puts "cool" below
    /// 74 °C — comfortably above the 38–50 °C an M2 Pro idles at and below the
    /// range real work reaches.
    public static let coolHeadroom: Double = 30

    /// Headroom below which the reading counts as hot but not yet urgent.
    ///
    /// Puts "hot" at 89–99 °C for a die sensor. CLAUDE.md records that die
    /// sensors *legitimately* run 95–105 °C under load, which is exactly why
    /// this band is "hot" and not "critical" — alarming at 95 °C would train
    /// the user to ignore the one band that matters.
    public static let warmHeadroom: Double = 15

    /// Headroom below which the daemon's ceiling rule is about to act.
    ///
    /// `SafetyMonitor` forces maximum cooling at the ceiling itself; this is
    /// the band just under it, where a user still has a choice to make.
    public static let hotHeadroom: Double = 5

    /// System watts below which a hot die has no load to explain it.
    ///
    /// Measured on Mac14,9: `docs/SMC-KEYS.md` recorded `PSTR` at 19.6 W with
    /// background work running, and `docs/THERMAL.md` measured 7.9 W at true
    /// idle. 15 W therefore sits above genuine idle and far below any real
    /// workload, so a die in the hot band while the machine draws less than
    /// this is not a machine that is working hard.
    ///
    /// Deliberately a **wattage** rather than a `R` threshold: `R` is not
    /// comparable between Macs, and this claim has to hold on hardware nobody
    /// here has measured.
    public static let idleWattsCeiling: Double = 15

    /// Curve output below which there is real cooling left to ask for.
    public static let curveHeadroomFraction: Double = 0.9

    // MARK: - Findings

    /// How hot, and how close to the limit the daemon enforces.
    public enum Heat: Sendable, Equatable {
        /// No die-class sensor reported — nothing to judge.
        case unknown
        case measured(celsius: Double, label: String, band: Band, headroom: Double)

        public enum Band: Sendable, Equatable {
            case cool, warm, hot, nearCeiling
        }
    }

    /// Whether the work being done accounts for the temperature.
    public enum Load: Sendable, Equatable {
        /// This Mac exposes no usable power key, so the question cannot be put.
        case noPowerSignal
        /// Power is readable but the machine has not held steady long enough
        /// for `R` to mean anything. See ``CoolingEfficiency/isSettled(_:)``.
        case measuring(watts: Double)
        /// The decomposition: this many watts produced this much rise, at this
        /// efficiency. A statement of fact, not a verdict.
        case explained(watts: Double, riseCelsius: Double, resistance: Double)
        /// The one anomaly this type will assert without a baseline: the die is
        /// hot while the machine draws near-idle power.
        case hotWithoutLoad(watts: Double, celsius: Double)
    }

    /// Where the heat is coming from.
    public enum Source: Sendable, Equatable {
        /// No process sample yet — the first reading only sets a baseline.
        case measuring
        case measured(
            leading: SMCKeyMaps.SensorClass,
            // Whether **both** a CPU-class and a GPU-class sensor were read.
            //
            // Without it, `leading` is not a claim this type can support. The
            // comparison used to substitute `-.infinity` for a missing class,
            // and `-.infinity > -.infinity` is `false` — so a Mac reporting
            // neither sensor was told "the CPU is leading the GPU", a verdict
            // derived from no data at all.
            comparedBoth: Bool,
            top: [ProcessEnergySample],
            attributedWatts: Double,
            // System watts minus attributed, when a system figure exists.
            unattributedWatts: Double?,
            unreadableCount: Int
        )
    }

    /// Whether cooling has anything left to give.
    public enum Cooling: Sendable, Equatable {
        /// Ice Cube is not driving the fans.
        case notControlling
        /// A fan is commanded well above its floor but reads below it — a
        /// stopped or failing fan, which needs no baseline to call.
        case stalled(fan: String)
        /// The curve is asking for everything already.
        case atMaximum(rpm: Double)
        /// The curve is asking for less than it could at this temperature.
        case headroom(commandedFraction: Double, currentRPM: Double, maximumRPM: Double)
    }

    /// The whole answer.
    public struct Verdict: Sendable, Equatable {
        public let heat: Heat
        public let load: Load
        public let source: Source
        public let cooling: Cooling
        /// The one cause this window may name rather than rank. See
        /// ``ChargingWarmth``.
        public let charging: ChargingWarmth

        public init(
            heat: Heat,
            load: Load,
            source: Source,
            cooling: Cooling,
            charging: ChargingWarmth
        ) {
            self.heat = heat
            self.load = load
            self.source = source
            self.cooling = cooling
            self.charging = charging
        }
    }

    // MARK: - The verdict

    /// Diagnoses one moment.
    ///
    /// - Parameters:
    ///   - snapshot: the current sensors, fans and system watts.
    ///   - resistance: settled °C/W, or `nil` while unsettled. The caller owns
    ///     the settle window (``CoolingEfficiency/Tracker``) because it spans
    ///     ticks and this function is pure.
    ///   - processes: the latest per-process sample, or `nil` before one exists.
    ///   - curve: the curve currently driving the fans, or `nil` when Ice Cube
    ///     is not in curve control.
    ///   - isCharging: whether the battery is taking charge, read fresh from
    ///     IOKit. Deliberately **not** defaulted: a default of `false` would
    ///     let a caller forget it and silently disable ``ChargingWarmth``
    ///     forever, with every test still green.
    ///   - wasWarmFromCharging: what ``ChargingWarmth`` said last time, which
    ///     is the whole of its hysteresis state. The caller owns it for the
    ///     same reason it owns the settle window: this function is pure.
    public static func diagnose(
        snapshot: SMCSnapshot,
        resistance: Double?,
        processes: ProcessEnergyReading?,
        curve: FanCurve?,
        isCharging: Bool,
        wasWarmFromCharging: Bool
    ) -> Verdict {
        let heatVerdict = heat(in: snapshot)
        return Verdict(
            heat: heatVerdict,
            load: load(in: snapshot, resistance: resistance),
            source: source(in: snapshot, processes: processes),
            cooling: cooling(in: snapshot, curve: curve),
            charging: ChargingWarmth.assess(
                isCharging: isCharging,
                batteryCelsius: snapshot.temperatures.batteryCelsius,
                heat: heatVerdict,
                wasWarm: wasWarmFromCharging
            )
        )
    }

    // MARK: - Question 1: is it hot?

    static func heat(in snapshot: SMCSnapshot) -> Heat {
        let dieSensors = snapshot.temperatures.filter(\.isDieSensor)
        guard let hottest = dieSensors.max(by: { $0.celsius < $1.celsius }) else { return .unknown }

        // Die-class only, and therefore always the die ceiling. Ambient-class
        // sensors have their own (95 °C) limit, but they are not what this
        // question is about: the curve follows the hottest die, the user asks
        // about the chip, and `SafetyMonitor` polices the rest independently.
        // A Mac reporting no die sensor gets `.unknown` above rather than a
        // verdict derived from its battery.
        let headroom = SafetyMonitor.Limits().dieCeiling - hottest.celsius

        let band: Heat.Band = switch headroom {
        case ..<hotHeadroom: .nearCeiling
        case ..<warmHeadroom: .hot
        case ..<coolHeadroom: .warm
        default: .cool
        }

        return .measured(celsius: hottest.celsius, label: hottest.label, band: band, headroom: headroom)
    }

    // MARK: - Question 2: does the work explain it?

    static func load(in snapshot: SMCSnapshot, resistance: Double?) -> Load {
        guard let watts = snapshot.power, watts.isFinite else { return .noPowerSignal }

        // The anomaly check runs before the settle gate on purpose. A hot die at
        // idle power is worth saying immediately, and waiting 20 s for a settled
        // quotient to say it would be the wrong trade — the quotient is not what
        // establishes it.
        if case let .measured(celsius, _, band, _) = heat(in: snapshot),
           band == .hot || band == .nearCeiling,
           watts < idleWattsCeiling
        {
            return .hotWithoutLoad(watts: watts, celsius: celsius)
        }

        guard let resistance, resistance.isFinite else { return .measuring(watts: watts) }
        guard
            let ambient = CoolingEfficiency.ambient(from: snapshot.temperatures),
            let die = snapshot.temperatures.hottestDieCelsius
        else {
            return .measuring(watts: watts)
        }
        return .explained(watts: watts, riseCelsius: die - ambient, resistance: resistance)
    }

    // MARK: - Question 3: what is producing it?

    static func source(in snapshot: SMCSnapshot, processes: ProcessEnergyReading?) -> Source {
        guard let processes else { return .measuring }

        // Which silicon is leading, from the SMC — the half of the answer the
        // process list cannot give. `ri_energy_nj` is CPU energy only, so a
        // graphics load shows small process figures and a large remainder, and
        // this row is what names it.
        //
        // Both classes must have been read for the comparison to mean anything.
        // Substituting `-.infinity` for a missing one silently answered ".cpu"
        // on a Mac reporting neither, which is a verdict from no evidence.
        let cpu = snapshot.temperatures.hottestCelsius(in: .cpu)
        let gpu = snapshot.temperatures.hottestCelsius(in: .gpu)
        let comparedBoth = cpu != nil && gpu != nil
        let leading: SMCKeyMaps.SensorClass = (gpu ?? -.infinity) > (cpu ?? -.infinity) ? .gpu : .cpu

        let unattributed = snapshot.power.map { max(0, $0 - processes.attributedWatts) }

        return .measured(
            leading: leading,
            comparedBoth: comparedBoth,
            top: processes.processes,
            attributedWatts: processes.attributedWatts,
            unattributedWatts: unattributed,
            unreadableCount: processes.unreadableCount
        )
    }

    // MARK: - Question 4: is cooling doing all it can?

    static func cooling(in snapshot: SMCSnapshot, curve: FanCurve?) -> Cooling {
        let drivable = snapshot.fans.filter(\.hasUsableRange)
        guard !drivable.isEmpty else { return .notControlling }

        // A fan commanded above its floor but reading below it is stopped or
        // failing. Stated as an absolute because it needs no baseline — and
        // scoped tightly, because a fan *ramping up* legitimately reads far
        // below target and must never be called stalled for it.
        if let stalled = drivable.first(where: { $0.targetRPM > $0.minRPM && $0.actualRPM < $0.minRPM }) {
            return .stalled(fan: stalled.name)
        }

        guard let curve, curve.isUsable, let die = snapshot.temperatures.hottestDieCelsius else {
            return .notControlling
        }

        let fraction = curve.fraction(at: die)
        let current = drivable.map(\.actualRPM).max() ?? 0
        let maximum = drivable.map(\.maxRPM).max() ?? 0

        guard fraction < curveHeadroomFraction else {
            return .atMaximum(rpm: current)
        }
        return .headroom(commandedFraction: fraction, currentRPM: current, maximumRPM: maximum)
    }
}
