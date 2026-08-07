// ThermalDiagnosisTests.swift — every band boundary, and every case where the verdict must refuse to answer.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("Thermal diagnosis")
struct ThermalDiagnosisTests {
    // MARK: - Fixtures

    static func fan(
        id: Int = 0,
        name: String = "Left",
        actual: Double = 3000,
        target: Double = 3000,
        min: Double = 2317,
        max: Double = 6800
    ) -> Fan {
        Fan(id: id, name: name, mode: .forced, actualRPM: actual, targetRPM: target, minRPM: min, maxRPM: max)
    }

    static func snapshot(
        cpu: Double? = 60,
        gpu: Double? = nil,
        airflow: Double? = 40,
        watts: Double? = 25,
        fans: [Fan] = [fan()]
    ) -> SMCSnapshot {
        var temperatures: [SensorReading] = []
        if let cpu {
            temperatures.append(SensorReading(key: "Tp01", label: "CPU P-core 1", celsius: cpu))
        }
        if let gpu {
            temperatures.append(SensorReading(key: "Tg0f", label: "GPU 1", celsius: gpu))
        }
        if let airflow {
            temperatures.append(SensorReading(key: "TaLP", label: "Airflow Left", celsius: airflow))
        }
        return SMCSnapshot(date: Date(), fans: fans, temperatures: temperatures, power: watts)
    }

    static func processes(
        attributed: Double = 8,
        top: [ProcessEnergySample] = [ProcessEnergySample(pid: 42, name: "compiler", watts: 6)],
        unreadable: Int = 200
    ) -> ProcessEnergyReading {
        ProcessEnergyReading(
            date: Date(),
            interval: 1,
            processes: top,
            attributedWatts: attributed,
            unreadableCount: unreadable,
            totalCount: 600
        )
    }

    // MARK: - Question 1: is it hot?

    @Test("A Mac reporting no die sensor gets no verdict, not a guess from its battery")
    func noDieSensorIsUnknown() {
        let snapshot = SMCSnapshot(
            date: Date(),
            fans: [Self.fan()],
            temperatures: [SensorReading(key: "TB1T", label: "Battery 1", celsius: 36)],
            power: 20
        )
        #expect(ThermalDiagnosis.heat(in: snapshot) == .unknown)
    }

    /// The band edges are load-bearing: CLAUDE.md records that die sensors
    /// legitimately reach 95–105 °C under load, so 95 °C must land in `hot` and
    /// not in an alarm the user learns to ignore.
    @Test(
        "Bands follow headroom to the 104 °C die ceiling",
        arguments: [
            (60.0, ThermalDiagnosis.Heat.Band.cool),
            (74.0, .cool),
            (74.1, .warm),
            (85.0, .warm),
            (89.0, .warm),
            (89.1, .hot),
            (95.0, .hot),
            (99.0, .hot),
            (99.1, .nearCeiling),
            (103.0, .nearCeiling),
        ]
    )
    func bandsFollowHeadroom(celsius: Double, expected: ThermalDiagnosis.Heat.Band) {
        guard case let .measured(_, _, band, headroom) = ThermalDiagnosis.heat(in: Self.snapshot(cpu: celsius)) else {
            Issue.record("expected a measured verdict")
            return
        }
        #expect(band == expected)
        #expect(abs(headroom - (104 - celsius)) < 1e-9)
    }

    @Test("The hottest die sensor wins, whichever class it is")
    func hottestDieWins() {
        guard case let .measured(celsius, label, _, _) = ThermalDiagnosis.heat(in: Self.snapshot(cpu: 70, gpu: 92))
        else {
            Issue.record("expected a measured verdict")
            return
        }
        #expect(celsius == 92)
        #expect(label == "GPU 1")
    }

    // MARK: - Question 2: does the work explain it?

    @Test("No power key means the question cannot be put")
    func noPowerSignal() {
        #expect(ThermalDiagnosis.load(in: Self.snapshot(watts: nil), resistance: 0.9) == .noPowerSignal)
        #expect(ThermalDiagnosis.load(in: Self.snapshot(watts: .nan), resistance: 0.9) == .noPowerSignal)
    }

    /// The only load-versus-cooling claim made without a baseline. It is keyed
    /// on **watts**, not on `R`, precisely because `R` is not comparable between
    /// Macs and this has to hold on hardware nobody here has measured.
    @Test("A hot die at idle power is called out even before anything settles")
    func hotWithoutLoad() {
        let verdict = ThermalDiagnosis.load(in: Self.snapshot(cpu: 95, watts: 9), resistance: nil)
        #expect(verdict == .hotWithoutLoad(watts: 9, celsius: 95))
    }

    @Test("A hot die with a real load is not an anomaly")
    func hotWithLoadIsNotAnomalous() {
        let verdict = ThermalDiagnosis.load(in: Self.snapshot(cpu: 95, watts: 40), resistance: nil)
        #expect(verdict == .measuring(watts: 40))
    }

    @Test("A cool die at idle power is not an anomaly")
    func coolAtIdleIsNotAnomalous() {
        let verdict = ThermalDiagnosis.load(in: Self.snapshot(cpu: 45, watts: 8), resistance: nil)
        #expect(verdict == .measuring(watts: 8))
    }

    @Test("Without a settled reading it says it is measuring, never an estimate")
    func unsettledRefuses() {
        #expect(ThermalDiagnosis.load(in: Self.snapshot(), resistance: nil) == .measuring(watts: 25))
        #expect(ThermalDiagnosis.load(in: Self.snapshot(), resistance: .nan) == .measuring(watts: 25))
    }

    @Test("Settled, it reports the decomposition with the rise above airflow")
    func settledExplains() {
        let verdict = ThermalDiagnosis.load(in: Self.snapshot(cpu: 70, airflow: 45, watts: 25), resistance: 1.0)
        #expect(verdict == .explained(watts: 25, riseCelsius: 25, resistance: 1.0))
    }

    @Test("With no airflow reference there is no rise to report")
    func noAmbientRefuses() {
        let verdict = ThermalDiagnosis.load(in: Self.snapshot(airflow: nil, watts: 25), resistance: 0.9)
        #expect(verdict == .measuring(watts: 25))
    }

    // MARK: - Question 3: what is producing it?

    @Test("Before the first differenced sample there is nothing to attribute")
    func noProcessSampleYet() {
        #expect(ThermalDiagnosis.source(in: Self.snapshot(), processes: nil) == .measuring)
    }

    /// `ri_energy_nj` is CPU energy only, so a graphics load shows small process
    /// figures and a large remainder. This row is the half of the answer the
    /// process list cannot give.
    @Test("The leading silicon comes from the SMC, not from the process list")
    func leadingSiliconFromSensors() {
        guard case let .measured(gpuLed, _, _, _, _, _) = ThermalDiagnosis
            .source(in: Self.snapshot(cpu: 60, gpu: 88), processes: Self.processes())
        else {
            Issue.record("expected a measured source")
            return
        }
        #expect(gpuLed == .gpu)

        guard case let .measured(cpuLed, _, _, _, _, _) = ThermalDiagnosis
            .source(in: Self.snapshot(cpu: 88, gpu: 60), processes: Self.processes())
        else {
            Issue.record("expected a measured source")
            return
        }
        #expect(cpuLed == .cpu)
    }

    @Test("The unattributed remainder is system power minus everything readable")
    func unattributedRemainder() {
        guard case let .measured(_, _, _, attributed, unattributed, unreadable) = ThermalDiagnosis
            .source(in: Self.snapshot(watts: 30), processes: Self.processes(attributed: 8))
        else {
            Issue.record("expected a measured source")
            return
        }
        #expect(attributed == 8)
        #expect(unattributed == 22)
        #expect(unreadable == 200)
    }

    /// Attribution can exceed the SMC figure transiently — different clocks,
    /// different sample windows. A negative "unattributed" would read as the
    /// machine producing power, so it is floored rather than shown.
    @Test("Attribution above system power floors at zero rather than going negative")
    func remainderNeverNegative() {
        guard case let .measured(_, _, _, _, unattributed, _) = ThermalDiagnosis
            .source(in: Self.snapshot(watts: 5), processes: Self.processes(attributed: 8))
        else {
            Issue.record("expected a measured source")
            return
        }
        #expect(unattributed == 0)
    }

    @Test("With no system power there is no remainder to claim")
    func noRemainderWithoutSystemPower() {
        guard case let .measured(_, _, _, _, unattributed, _) = ThermalDiagnosis
            .source(in: Self.snapshot(watts: nil), processes: Self.processes())
        else {
            Issue.record("expected a measured source")
            return
        }
        #expect(unattributed == nil)
    }

    // MARK: - Question 4: is cooling doing all it can?

    @Test("A Mac with no drivable fan is not being cooled by us")
    func noDrivableFans() {
        let broken = Self.fan(actual: 0, target: 0, min: 0, max: 0)
        #expect(ThermalDiagnosis.cooling(in: Self.snapshot(fans: [broken]), curve: .balanced) == .notControlling)
    }

    @Test("A fan commanded above its floor but reading below it is stalled")
    func stalledFan() {
        let dead = Self.fan(name: "Right", actual: 400, target: 5000)
        #expect(ThermalDiagnosis.cooling(in: Self.snapshot(fans: [dead]), curve: .balanced) == .stalled(fan: "Right"))
    }

    /// The false positive this case exists to avoid. A fan ramping from rest to
    /// 6800 legitimately reads far below target for seconds — `FanActivity`
    /// documents the measured ~1.5 s firmware dead time — and calling that a
    /// failure would fire on every preset change.
    @Test("A fan mid-ramp is not stalled, however far below target it reads")
    func rampingFanIsNotStalled() {
        let ramping = Self.fan(actual: 2400, target: 6800)
        let verdict = ThermalDiagnosis.cooling(in: Self.snapshot(cpu: 95, fans: [ramping]), curve: .cold)
        #expect(verdict != .stalled(fan: "Left"))
    }

    @Test("With no curve, Ice Cube is not the one deciding")
    func noCurveIsNotControlling() {
        #expect(ThermalDiagnosis.cooling(in: Self.snapshot(), curve: nil) == .notControlling)
        #expect(ThermalDiagnosis.cooling(in: Self.snapshot(), curve: FanCurve(points: [])) == .notControlling)
    }

    @Test("A curve already asking for everything has nothing left to give")
    func atMaximum() {
        // Balanced reaches fraction 1.0 at 85 °C.
        let verdict = ThermalDiagnosis.cooling(
            in: Self.snapshot(cpu: 95, fans: [Self.fan(actual: 6700)]),
            curve: .balanced
        )
        #expect(verdict == .atMaximum(rpm: 6700))
    }

    @Test("A curve asking for less than it could reports the headroom")
    func headroomReported() {
        // Balanced at 55 °C asks for 0.25.
        let verdict = ThermalDiagnosis.cooling(
            in: Self.snapshot(cpu: 55, fans: [Self.fan(actual: 3400)]),
            curve: .balanced
        )
        guard case let .headroom(fraction, current, maximum) = verdict else {
            Issue.record("expected headroom, got \(verdict)")
            return
        }
        #expect(abs(fraction - 0.25) < 1e-9)
        #expect(current == 3400)
        #expect(maximum == 6800)
    }

    // MARK: - The whole verdict

    @Test("diagnose() answers all four questions from one snapshot")
    func fullVerdict() {
        let verdict = ThermalDiagnosis.diagnose(
            snapshot: Self.snapshot(cpu: 92, gpu: 70, airflow: 48, watts: 38, fans: [Self.fan(actual: 6700)]),
            resistance: 1.16,
            processes: Self.processes(attributed: 12),
            curve: .balanced
        )
        #expect(verdict.heat == .measured(celsius: 92, label: "CPU P-core 1", band: .hot, headroom: 12))
        #expect(verdict.load == .explained(watts: 38, riseCelsius: 44, resistance: 1.16))
        #expect(verdict.cooling == .atMaximum(rpm: 6700))
        guard case let .measured(leading, _, top, attributed, unattributed, _) = verdict.source else {
            Issue.record("expected a measured source")
            return
        }
        #expect(leading == .cpu)
        #expect(top.first?.name == "compiler")
        #expect(attributed == 12)
        #expect(unattributed == 26)
    }
}
