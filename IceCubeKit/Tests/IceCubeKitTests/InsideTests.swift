// InsideTests.swift — what the cooling schematic may draw, and what it may say about it.

import Foundation
@testable import IceCubeKit
import Testing

/// The sensor set a Mac14,9 actually reports, so the fixtures are the shape of
/// the machine this is developed on rather than a convenient invention.
private enum Fixtures {
    static func sensors(
        cpu: Double = 72, gpu: Double = 61, ssd: Double = 44,
        battery: Double = 34, airLeft: Double = 39, airRight: Double = 41
    ) -> [SensorReading] {
        [
            SensorReading(key: "Tp01", label: "CPU P-cores", celsius: cpu),
            SensorReading(key: "Tp05", label: "CPU P-cores", celsius: cpu - 3),
            SensorReading(key: "Tp1h", label: "CPU E-cores", celsius: cpu - 8),
            SensorReading(key: "Tg0f", label: "GPU", celsius: gpu),
            SensorReading(key: "Tg0j", label: "GPU", celsius: gpu - 2),
            SensorReading(key: "TH0x", label: "SSD", celsius: ssd),
            SensorReading(key: "TB1T", label: "Battery", celsius: battery),
            SensorReading(key: "TaLP", label: "Airflow Left", celsius: airLeft),
            SensorReading(key: "TaRF", label: "Airflow Right", celsius: airRight),
        ]
    }

    static func fans(rpm: Double, max: Double = 6800) -> [Fan] {
        (0 ... 1).map {
            Fan(
                id: $0, name: $0 == 0 ? "Left" : "Right", mode: .forced,
                actualRPM: rpm, targetRPM: rpm, minRPM: 2317, maxRPM: max
            )
        }
    }

    /// `gpu` is a parameter and not a constant on purpose. The die input is the
    /// *hottest* die-class sensor, so a fixture that lowers only the CPU still
    /// has a 61 °C GPU deciding every answer — which is how the first draft of
    /// these tests managed to assert a cold machine while describing a warm one.
    static func snapshot(
        cpu: Double = 72, gpu: Double = 61, rpm: Double = 3400,
        fans: [Fan]? = nil, airLeft: Double = 39
    ) -> SMCSnapshot {
        SMCSnapshot(
            date: Date(timeIntervalSince1970: 1_753_000_000),
            fans: fans ?? Self.fans(rpm: rpm),
            temperatures: sensors(cpu: cpu, gpu: gpu, airLeft: airLeft),
            power: 22
        )
    }
}

@Suite("InsideLayout — which blocks the schematic draws")
struct InsideLayoutTests {
    /// A dozen die sensors must not become a dozen squares. Each silicon class
    /// collapses to its hottest member, which is the reduction the curve input
    /// and the safety ceiling already use.
    @Test("Silicon classes collapse to one block each, at their hottest member")
    func siliconGroups() throws {
        let blocks = InsideLayout.blocks(for: Fixtures.sensors(cpu: 88, gpu: 71))
        let cpu = try #require(blocks.first { $0.id == "CPU" })
        #expect(cpu.celsius == 88, "the CPU block must show the hottest core, not the first one")
        #expect(cpu.sensorCount == 3, "and say how many it reduced, so it cannot read as a single sensor")
        let gpu = try #require(blocks.first { $0.id == "GPU" })
        #expect(gpu.celsius == 71)
        #expect(blocks.filter { $0.role == .source }.count == 2, "Mac14,9 reports no Tf/Tc sensor")
    }

    /// A schematic that reorders itself while you look at it is unreadable, and
    /// the temptation — sort the blocks by temperature so the hottest leads —
    /// is exactly what would cause it. Order is by role and id, never by value.
    @Test("Block order does not change when the temperatures do")
    func orderIsStable() {
        let cool = InsideLayout.blocks(for: Fixtures.sensors(cpu: 45, gpu: 90, ssd: 80))
        let hot = InsideLayout.blocks(for: Fixtures.sensors(cpu: 99, gpu: 40, ssd: 35))
        #expect(cool.map(\.id) == hot.map(\.id), "got \(cool.map(\.id)) then \(hot.map(\.id))")
        #expect(cool.map(\.id) == ["CPU", "GPU", "TB1T", "TH0x", "TaLP", "TaRF"])
    }

    /// An absent class is omitted rather than drawn empty — a blank square
    /// labelled GPU on a Mac with no GPU sensor is a missing reading presented
    /// as a cold one.
    @Test("A class this Mac does not report produces no block")
    func absentClassOmitted() {
        let noGPU = Fixtures.sensors().filter { !$0.key.hasPrefix("Tg") }
        let blocks = InsideLayout.blocks(for: noGPU)
        #expect(!blocks.contains { $0.id == "GPU" }, "no GPU sensor must mean no GPU block")
        #expect(blocks.contains { $0.id == "CPU" }, "and must not take the rest of the diagram with it")
    }

    /// The unmapped-Mac case, which is most of the compatibility table: raw
    /// keys, no curated labels. Grouping goes through `SMCKeyMaps.classify`, so
    /// every block still lands in the right place.
    @Test("An unmapped Mac's raw keys still group correctly")
    func unmappedMacStillGroups() throws {
        let raw = [
            SensorReading(key: "Tp0A", label: "Tp0A", celsius: 81),
            SensorReading(key: "Tg1B", label: "Tg1B", celsius: 64),
            SensorReading(key: "Tf0C", label: "Tf0C", celsius: 58),
            SensorReading(key: "TaLC", label: "TaLC", celsius: 37),
        ]
        let blocks = InsideLayout.blocks(for: raw)
        #expect(try #require(blocks.first { $0.id == "CPU" }).celsius == 81)
        #expect(try #require(blocks.first { $0.id == "GPU" }).celsius == 64)
        #expect(try #require(blocks.first { $0.id == "Silicon" }).celsius == 58, "Tf is other-die silicon")
    }

    /// Matched on key prefix, not on label — the label is only curated on the
    /// M2 generation and falls back to the raw key everywhere else, so matching
    /// on words would hand every M1, M3, M4 and M5 owner a thermometer for
    /// everything they own.
    @Test("Component icons are chosen by SMC key prefix, so an unmapped Mac gets them too")
    func componentIconsComeFromTheKey() {
        #expect(InsideLayout.componentSymbol(forKey: "TB1T") == "battery.100")
        #expect(InsideLayout.componentSymbol(forKey: "TB2T") == "battery.100", "both batteries, one icon")
        #expect(InsideLayout.componentSymbol(forKey: "TH0x") == "internaldrive")
        #expect(InsideLayout.componentSymbol(forKey: "TW0P") == "wifi")
        #expect(
            InsideLayout.componentSymbol(forKey: "TZ9q") == InsideLayout.fallbackSymbol,
            "a sensor nobody has mapped still gets something to draw"
        )
        // The label is deliberately not consulted: an unmapped Mac reports the
        // raw key as its label, and this must still work there.
        let unmapped = [SensorReading(key: "TH1a", label: "TH1a", celsius: 44)]
        #expect(InsideLayout.blocks(for: unmapped).first?.symbolName == "internaldrive")
    }

    /// Intake and outflow are assigned by temperature, not by position — Ice
    /// Cube cannot know which airflow sensor is nearer a vent. Coolest-is-intake
    /// is the same inference `CoolingEfficiency.ambient(from:)` documents.
    @Test("The coolest airflow sensor is the intake and the warmest is the outflow")
    func airRolesFollowTemperature() throws {
        let blocks = InsideLayout.blocks(for: Fixtures.sensors(airLeft: 44, airRight: 38))
        let intake = try #require(blocks.first { $0.role == .intake })
        let outflow = try #require(blocks.first { $0.role == .outflow })
        #expect(intake.celsius == 38, "the right sensor was cooler this time, so it is the intake")
        #expect(outflow.celsius == 44)
        #expect(intake.id == "TaRF", "and the block keeps the real key it came from")
    }

    /// One airflow sensor is one block. Splitting it into a labelled pair would
    /// imply a measurement of both ends of the airflow that was never taken.
    @Test("A Mac with one airflow sensor gets one air block, not an invented pair")
    func singleAirflowSensor() {
        let one = Fixtures.sensors().filter { $0.key != "TaRF" }
        let air = InsideLayout.blocks(for: one).filter { $0.role == .intake || $0.role == .outflow }
        #expect(air.count == 1)
        #expect(air.first?.label == "Airflow", "labelled for what it is, not for an end it may not be at")
    }
}

@Suite("HeatFlow — what the schematic is allowed to say")
struct HeatFlowTests {
    @Test("The gradient is the hottest silicon above the coolest air")
    func gradientIsDieAboveAir() throws {
        let g = try #require(HeatFlow.gradient(for: Fixtures.sensors(cpu: 88, airLeft: 39, airRight: 41)))
        #expect(abs(g - 49) < 0.001, "88 − 39 = 49; the coolest airflow sensor is the reference")
    }

    /// A die below the air reference is the cold-boot case `CoolingEfficiency`
    /// already refuses. Drawing a negative bar would be worse than drawing none.
    @Test("A die at or below the air reference yields no gradient at all")
    func gradientRefusesNegative() {
        // Both silicon classes cold, not just the CPU — the reference is the
        // hottest die sensor of any class.
        #expect(HeatFlow.gradient(for: Fixtures.sensors(cpu: 30, gpu: 28, airLeft: 39, airRight: 41)) == nil)
        #expect(HeatFlow.gradient(for: []) == nil, "no sensors is also no answer")
        let airOnly = Fixtures.sensors().filter { SMCKeyMaps.isAirflowKey($0.key) }
        #expect(HeatFlow.gradient(for: airOnly) == nil, "air with no silicon is no answer either")
    }

    @Test("Flow is each fan against its own maximum, averaged")
    func flowIsPerFanFraction() throws {
        #expect(try #require(HeatFlow.flowFraction(Fixtures.fans(rpm: 3400))) == 0.5)
        #expect(HeatFlow.flowFraction([]) == nil, "a fanless Mac has no fraction, not a zero one")
        let unusable = [Fan(id: 0, name: "L", mode: .auto, actualRPM: 0, targetRPM: 0, minRPM: 0, maxRPM: 0)]
        #expect(HeatFlow.flowFraction(unusable) == nil, "a fan that reported no range cannot be drawn turning")
    }

    @Test("Each state comes from the snapshot that should produce it")
    func statesAreReachable() {
        #expect(HeatFlow.state(for: Fixtures.snapshot(cpu: 30, gpu: 28)) == .warmingUp, "silicon below the air")
        #expect(HeatFlow.state(for: Fixtures.snapshot(cpu: 52, gpu: 50)) == .coolAndQuiet)
        #expect(HeatFlow.state(for: Fixtures.snapshot(cpu: 88, rpm: 4800)) == .working)
        #expect(
            HeatFlow.state(for: Fixtures.snapshot(cpu: 88, rpm: 0)) == .hotAndUncooled,
            "hot with the fans stopped is the state this whole app exists for"
        )
    }

    /// The boundary is `FanGuardian`'s own engage floor, so the picture and the
    /// daemon agree about what "warm" means.
    @Test("The warm boundary sits exactly at the guardian's floor")
    func warmBoundary() {
        #expect(HeatFlow.warmCelsius == 68)
        #expect(HeatFlow.state(for: Fixtures.snapshot(cpu: 67.9, rpm: 0)) == .coolAndQuiet)
        #expect(HeatFlow.state(for: Fixtures.snapshot(cpu: 68.0, rpm: 0)) == .hotAndUncooled)
    }

    /// A fan parked at its firmware minimum is turning without cooling anything
    /// on purpose. Reporting that as "working" would hide the case the state
    /// exists to show.
    @Test("A fan idling near its floor still counts as nothing cooling")
    func minimumRPMIsNotWorking() {
        #expect(HeatFlow.state(for: Fixtures.snapshot(cpu: 88, rpm: 680)) == .hotAndUncooled, "10 % of range")
        #expect(HeatFlow.state(for: Fixtures.snapshot(cpu: 88, rpm: 1100)) == .working, "16 % of range")
    }

    /// A fanless Air has no fans by design and its thermal design assumes none.
    /// Telling its owner nothing is cooling their Mac would be alarming and
    /// wrong — the same distinction `FanBand.fanless` is a separate case for.
    @Test("A fanless Mac is never reported as uncooled")
    func fanlessIsNeverUncooled() {
        let fanless = Fixtures.snapshot(cpu: 92, fans: [])
        #expect(HeatFlow.state(for: fanless) == .working, "no fans is not the same as stopped fans")
    }
}

@Suite("FanRotation — the drawn blade speed, which is not the real one")
struct FanRotationTests {
    /// The test that stops the backwards-spinning lie. Above the Nyquist limit
    /// on blade passes a drawn fan reverses direction, and it would do so
    /// exactly when the machine is loudest and the picture most needs trusting.
    @Test("The drawn speed never crosses the alias ceiling, at any real RPM")
    func neverAliases() {
        // Derived, not hardcoded: the point is the relationship, and pinning
        // the number instead is what let the rate sit exactly on Nyquist.
        let passesPerSecond = FanRotation.maximumDisplayRPM / 60 * Double(FanRotation.bladeCount)
        #expect(
            passesPerSecond <= FanRotation.frameRate / FanRotation.aliasSafetyFactor + 0.001,
            "\(passesPerSecond) blade passes/s against a \(FanRotation.frameRate) fps canvas"
        )
        #expect(
            passesPerSecond < FanRotation.frameRate / 2,
            "and it must be safely UNDER Nyquist, not sitting on it — that is where motion looks frozen"
        )
        for rpm in stride(from: 0.0, through: 10000, by: 50) {
            let shown = FanRotation.displayRPM(rpm: rpm, maxRPM: 6800)
            #expect(shown <= FanRotation.maximumDisplayRPM, "\(rpm) RPM drew at \(shown)")
            #expect(shown >= 0)
        }
    }

    @Test("A faster fan always draws faster, and a stopped fan is exactly stopped")
    func monotonicAndZero() {
        #expect(FanRotation.displayRPM(rpm: 0, maxRPM: 6800) == 0, "stopped must be stopped")
        var last = -1.0
        for rpm in stride(from: 0.0, through: 6800, by: 100) {
            let shown = FanRotation.displayRPM(rpm: rpm, maxRPM: 6800)
            #expect(shown >= last, "drawn speed fell from \(last) to \(shown) at \(rpm) RPM")
            last = shown
        }
        #expect(last == FanRotation.maximumDisplayRPM, "the top of the range reaches the ceiling")
    }

    @Test("A fan with no usable maximum is drawn stopped rather than guessed at")
    func degenerateRange() {
        #expect(FanRotation.displayRPM(rpm: 3000, maxRPM: 0) == 0)
        #expect(FanRotation.displayRPM(rpm: .nan, maxRPM: 6800) == 0)
        #expect(FanRotation.turnsPerSecond(rpm: 3000, maxRPM: 0) == 0)
    }

    @Test("The rate is the drawn speed expressed per second")
    func rateMatchesDisplaySpeed() {
        #expect(
            abs(FanRotation.turnsPerSecond(rpm: 6800, maxRPM: 6800)
                - FanRotation.maximumDisplayRPM / 60) < 1e-12
        )
        #expect(FanRotation.turnsPerSecond(rpm: 0, maxRPM: 6800) == 0, "a stopped fan does not turn")
    }

    /// Blur is a cue layered over visible motion, never a replacement for it.
    /// It used to reach full opacity at 70 % of range, which erased the blades
    /// exactly when the fan was spinning fastest — the drawing went stiller as
    /// the machine got busier.
    @Test("Blur never hides the blades completely, however fast the fan")
    func blurNeverErasesTheBlades() {
        #expect(FanRotation.blur(rpm: 0, maxRPM: 6800) == 0, "a stopped fan is not blurred")
        #expect(FanRotation.maximumBlur < 1, "full blur would mean no visible rotation at all")
        for rpm in stride(from: 0.0, through: 10000, by: 100) {
            #expect(FanRotation.blur(rpm: rpm, maxRPM: 6800) <= FanRotation.maximumBlur)
        }
        #expect(
            FanRotation.blur(rpm: 6800, maxRPM: 6800) > FanRotation.blur(rpm: 2300, maxRPM: 6800),
            "but it must still rise with speed, or it is not a speed cue"
        )
    }
}

/// CLAUDE.md rule 3 asserted rather than assumed: the window has to be
/// *demonstrable* with no root, no helper and no real SMC, and the only input
/// it takes is a snapshot. Feeding it the simulation's real output is the whole
/// check — if the mock ever stops producing a complete machine, this fails here
/// rather than as an empty window nobody opened.
@Suite("Inside — demonstrable against the simulation, with no hardware")
struct InsideSimulatedTests {
    @Test("The simulated Mac draws a complete diagram")
    func simulatedSnapshotDrawsEverything() async throws {
        let provider = MockSMCProvider(now: { Date(timeIntervalSince1970: 1_753_000_000) })
        let snapshot = try await provider.snapshot()
        let blocks = InsideLayout.blocks(for: snapshot.temperatures)

        #expect(blocks.contains { $0.id == "CPU" }, "the simulation must produce silicon to draw")
        #expect(blocks.contains { $0.id == "GPU" })
        #expect(blocks.contains { $0.role == .intake }, "and air, or there is no heat path")
        #expect(blocks.contains { $0.role == .component }, "and a component or two on the board")
        #expect(snapshot.fans.count == 2, "and two blowers to turn")

        #expect(HeatFlow.gradient(for: snapshot.temperatures) != nil, "a gradient to state")
        #expect(HeatFlow.flowFraction(snapshot.fans) != nil, "and a flow rate to move the air at")
    }

    /// Every state has to be reachable on the simulated timeline, or the
    /// simulated build cannot demonstrate — or screenshot — what the window
    /// says when something is wrong.
    @Test("Both a busy and a quiet moment exist in the first simulated hour")
    func simulatedTimelineReachesMoreThanOneState() async throws {
        var seen: Set<HeatFlow.State> = []
        for second in stride(from: 0.0, through: 3600, by: 20) {
            let provider = MockSMCProvider(now: { Date(timeIntervalSince1970: 1_753_000_000 + second) })
            try await seen.insert(HeatFlow.state(for: provider.snapshot()))
        }
        #expect(seen.contains(.working), "the simulation's spikes must reach a working machine")
        #expect(seen.count > 1, "and must not sit in one state all hour, got \(seen)")
    }
}

@Suite("PhaseIntegrator — motion that survives a change of speed")
struct PhaseIntegratorTests {
    /// The headline, and the bug this type was written for: changing the rate
    /// must move the phase by *nothing*. The old code multiplied an 8.3e8
    /// clock by the rate, so a one-part-in-ten-thousand change jumped the
    /// drawing by tens of thousands of cycles, once per poll.
    @Test("Changing the speed does not move the phase")
    func speedChangesAreContinuous() {
        var slow = PhaseIntegrator()
        var jumpy = PhaseIntegrator()
        // The real numbers: an absolute clock, and a rate wobbling the way a
        // fan reading wobbles between polls.
        // Real RPM readings and the real rate formula. The first draft of this
        // test wobbled the rate in steps of 0.0001, which against a 8.3e8 clock
        // lands on *exact integers* — the fractional part never moved, so it
        // could not see the very bug it was written for. Ratios of real fan
        // readings are not so obliging.
        let readings = [5523.0, 5531.0, 5518.0, 5540.0, 5527.0]
        func rate(_ rpm: Double) -> Double {
            0.035 + (rpm / 6800) * 0.22
        }
        var t = 830_000_000.0
        for step in 0 ..< 400 {
            t += 1.0 / 60
            let steady = rate(readings[0])
            let wobbling = rate(readings[(step / 60) % readings.count])
            slow.advance(to: t, turnsPerSecond: steady)
            let before = jumpy.phase
            let after = jumpy.advance(to: t, turnsPerSecond: wobbling)
            // One frame at ~0.21 turns/s moves ~0.0036 turns. Anything near a
            // tenth of a turn is a teleport.
            let moved = min(abs(after - before), 1 - abs(after - before))
            #expect(moved < 0.1, "step \(step) jumped \(moved) turns on a speed change")
        }
    }

    @Test("At a constant rate the phase advances linearly and wraps inside one turn")
    func constantRateIsLinear() {
        var integrator = PhaseIntegrator()
        var t = 1000.0
        integrator.advance(to: t, turnsPerSecond: 1)
        for _ in 0 ..< 40 {
            t += 0.1
            let phase = integrator.advance(to: t, turnsPerSecond: 1)
            #expect(phase >= 0 && phase < 1, "phase \(phase) left the unit turn")
        }
        // 4.0 s at one turn/s is four whole turns — back where it started.
        #expect(abs(integrator.phase) < 1e-9, "got \(integrator.phase)")
    }

    /// SwiftUI may evaluate a body more than once for the same frame. A draw
    /// that advanced on every evaluation would run fast and unevenly — the
    /// same symptom, arriving by a different route.
    ///
    /// **A characterization test, not a guard test, and worth labelling as
    /// one.** No mutation of the guards can make this fail: idempotence falls
    /// out of the arithmetic, because a repeated instant gives `delta == 0` and
    /// `rate × 0` is `0`. It stays because callers depend on the property and a
    /// future rewrite could lose it — not because it is defending a branch.
    @Test("Asking for the same instant twice gives the same phase")
    func repeatedInstantsAreIdempotent() {
        var integrator = PhaseIntegrator()
        integrator.advance(to: 100, turnsPerSecond: 1)
        let first = integrator.advance(to: 100.5, turnsPerSecond: 1)
        let second = integrator.advance(to: 100.5, turnsPerSecond: 1)
        let third = integrator.advance(to: 100.5, turnsPerSecond: 1)
        #expect(first == second && second == third, "\(first) then \(second) then \(third)")
    }

    /// A hidden window or a sleeping Mac resumes with a `dt` of minutes.
    /// Integrating it would spin through thousands of turns in one frame.
    @Test("A long gap re-anchors instead of spinning through it")
    func longGapsDoNotSpin() {
        var integrator = PhaseIntegrator()
        integrator.advance(to: 0, turnsPerSecond: 3)
        integrator.advance(to: 0.1, turnsPerSecond: 3)
        let beforeSleep = integrator.phase
        integrator.advance(to: 3600, turnsPerSecond: 3) // an hour asleep
        #expect(integrator.phase == beforeSleep, "an hour must not be integrated in one frame")
        // …and it keeps running normally afterwards, from where it was.
        let resumed = integrator.advance(to: 3600.1, turnsPerSecond: 3)
        #expect(resumed != beforeSleep, "but it must resume, not freeze")
    }

    /// A NaN phase makes every later frame NaN, and a fan drawn at NaN vanishes
    /// permanently — so the property pinned here is the outcome (the phase
    /// stays finite and the motion resumes) rather than any particular guard.
    /// The explicit `seconds.isFinite` check was removed for exactly that
    /// reason: it changed nothing this test could see.
    @Test("Non-finite input is ignored rather than poisoning every later frame")
    func nonFiniteInputIsIgnored() {
        var integrator = PhaseIntegrator()
        integrator.advance(to: 10, turnsPerSecond: 2)
        integrator.advance(to: 10.1, turnsPerSecond: 2)
        let good = integrator.phase
        integrator.advance(to: .nan, turnsPerSecond: 2)
        #expect(integrator.phase == good)

        // The property that matters is not "the phase stayed finite" — it is
        // that the integrator still WORKS. A NaN stored as the last instant
        // makes every later delta NaN, so the phase would stay perfectly finite
        // and perfectly frozen, for as long as the window stayed open.
        integrator.advance(to: 10.2, turnsPerSecond: 2)
        let afterRecovery = integrator.advance(to: 10.3, turnsPerSecond: 2)
        #expect(afterRecovery != good, "a NaN instant must not freeze the motion permanently")
        #expect(afterRecovery.isFinite)

        integrator.advance(to: 10.4, turnsPerSecond: .nan)
        #expect(integrator.phase.isFinite, "a NaN rate must not poison the phase either")
        // Time going backwards (a clock adjustment) re-anchors without moving.
        let beforeBackwards = integrator.phase
        integrator.advance(to: 5, turnsPerSecond: 2)
        #expect(integrator.phase == beforeBackwards)
        #expect(integrator.advance(to: 5.1, turnsPerSecond: 2) != beforeBackwards, "and resumes after")
    }
}

@Suite("InsideCopy — the words under the picture")
struct InsideCopyTests {
    @Test("Every state produces its own headline", arguments: HeatFlow.State.allCases)
    func headlinesAreDistinct(_ state: HeatFlow.State) {
        #expect(!InsideCopy.headline(state).isEmpty)
        let all = HeatFlow.State.allCases.map(InsideCopy.headline)
        #expect(Set(all).count == all.count, "two states share a sentence: \(all)")
    }

    @Test("The detail line states the gradient in the unit the user chose")
    func detailCarriesTheNumber() {
        let text = InsideCopy.detail(.working, gradient: 49, flow: 0.5, style: .celsius)
        #expect(text.contains("49 °C"))
        #expect(text.contains("50%"), "and what the fans are doing about it")
    }

    /// The mistake `TemperatureStyle` exists to prevent, in the one line of this
    /// feature shaped to make it.
    ///
    /// The gradient is a **difference** — how far the silicon sits above the
    /// incoming air — so it scales by 9/5 and takes no `+32`. A 49 °C rise is a
    /// 88 °F rise. Rendering it as an absolute gives 120 °F, which is wrong by
    /// exactly the offset and looks entirely plausible on screen.
    @Test("The gradient converts as a difference, never as an absolute")
    func gradientIsADifferenceNotAReading() {
        let text = InsideCopy.detail(.working, gradient: 49, flow: 0.5, style: .fahrenheit)
        #expect(text.contains("88 °F"), "49 × 9/5 = 88.2, got: \(text)")
        #expect(!text.contains("120"), "120 °F is the +32 offset applied to a gap between two points")
    }

    @Test("Every state's detail line honours the unit, with no stray degree signs")
    func everyStateConvertsConsistently() {
        for state in HeatFlow.State.allCases {
            let fahrenheit = InsideCopy.detail(state, gradient: 40, flow: 0.4, style: .fahrenheit)
            #expect(!fahrenheit.contains("°C"), "\(state) leaked Celsius: \(fahrenheit)")
            let celsius = InsideCopy.detail(state, gradient: 40, flow: 0.4, style: .celsius)
            #expect(!celsius.contains("°F"), "\(state) leaked Fahrenheit: \(celsius)")
        }
    }

    /// Every state must still say something when this Mac reports no airflow
    /// sensor, rather than printing a sentence with a hole in it.
    @Test("A Mac with no gradient still gets a complete sentence in every state")
    func detailSurvivesMissingInputs() {
        for state in HeatFlow.State.allCases {
            let text = InsideCopy.detail(state, gradient: nil, flow: nil, style: .celsius)
            #expect(!text.isEmpty, "\(state) said nothing")
            #expect(!text.contains("nil") && !text.contains("Optional"), "\(state) leaked: \(text)")
        }
    }
}
