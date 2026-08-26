// DiagnosisCopyTests.swift — the window's words, and the four things they must never say.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("Diagnosis copy")
struct DiagnosisCopyTests {
    typealias Heat = ThermalDiagnosis.Heat
    typealias Load = ThermalDiagnosis.Load
    typealias Source = ThermalDiagnosis.Source
    typealias Cooling = ThermalDiagnosis.Cooling

    static func measured(_ celsius: Double, _ band: Heat.Band) -> Heat {
        .measured(celsius: celsius, label: "CPU P-core 1", band: band, headroom: 104 - celsius)
    }

    static func source(
        leading: SMCKeyMaps.SensorClass = .cpu,
        comparedBoth: Bool = true,
        top: [ProcessEnergySample] = [ProcessEnergySample(pid: 1, name: "compiler", watts: 6)],
        attributed: Double = 9.9,
        unattributed: Double? = 31.7,
        unreadable: Int = 205
    ) -> Source {
        .measured(
            leading: leading,
            comparedBoth: comparedBoth,
            top: top,
            attributedWatts: attributed,
            unattributedWatts: unattributed,
            unreadableCount: unreadable
        )
    }

    /// Every row the window can show, for the invariants below to sweep.
    static var everyRow: [DiagnosisCopy.Row] {
        var rows: [DiagnosisCopy.Row] = [DiagnosisCopy.waiting]
        let loads: [Load] = [
            .noPowerSignal, .measuring(watts: 25),
            .explained(watts: 38, riseCelsius: 44, resistance: 1.16),
            .hotWithoutLoad(watts: 9, celsius: 95),
        ]
        for load in loads {
            rows.append(DiagnosisCopy.load(load))
            rows.append(DiagnosisCopy.heat(.unknown, load: load))
            for band in [Heat.Band.cool, .warm, .hot, .nearCeiling] {
                rows.append(DiagnosisCopy.heat(measured(80, band), load: load))
            }
        }
        for comparedBoth in [true, false] {
            for leading in [SMCKeyMaps.SensorClass.cpu, .gpu] {
                let s = source(leading: leading, comparedBoth: comparedBoth)
                rows.append(DiagnosisCopy.source(s))
                if let a = DiagnosisCopy.accounting(s) {
                    rows.append(a)
                }
            }
        }
        rows.append(DiagnosisCopy.source(.measuring))
        let coolings: [Cooling] = [
            .notControlling, .stalled(fan: "Right"), .atMaximum(rpm: 6800),
            .headroom(commandedFraction: 0.45, currentRPM: 3400, maximumRPM: 6800),
        ]
        rows.append(contentsOf: coolings.map(DiagnosisCopy.cooling))
        return rows
    }

    // MARK: - Titles carry the verdict

    @Test("No section title is a question")
    func titlesAreNotQuestions() {
        for row in Self.everyRow where !row.title.isEmpty {
            #expect(!row.title.contains("?"), "title still asks rather than answers: \(row.title)")
        }
    }

    @Test(
        "The heat title states the band",
        arguments: [
            (Heat.Band.cool, "Running cool"),
            (.warm, "Normal temperature"),
            (.hot, "Hot, within design range"),
            (.nearCeiling, "Very hot"),
        ]
    )
    func heatTitles(band: Heat.Band, expected: String) {
        let row = DiagnosisCopy.heat(Self.measured(80, band), load: .measuring(watts: 25))
        #expect(row.title == expected)
    }

    /// The window must not argue with itself: "within design range" directly
    /// above "hot with no load to explain it" is two verdicts contradicting.
    @Test("A hot die with no load drops the reassuring qualifier")
    func heatAndLoadDoNotContradict() {
        let anomalous = Load.hotWithoutLoad(watts: 9, celsius: 95)
        #expect(DiagnosisCopy.heat(Self.measured(95, .hot), load: anomalous).title == "Hot")
        #expect(DiagnosisCopy.heat(Self.measured(101, .nearCeiling), load: anomalous).title == "Very hot")
        // …and keeps it when the load does explain the heat.
        let explained = Load.explained(watts: 38, riseCelsius: 44, resistance: 1.16)
        #expect(DiagnosisCopy.heat(Self.measured(95, .hot), load: explained).title == "Hot, within design range")
    }

    // MARK: - Refusals stay refusals

    /// A refusal must never be mistakable for an answer. Checked on words
    /// rather than on a dash: an em dash alone reads as a broken sensor.
    @Test("Every refusal says so in words")
    func refusalsAreWorded() {
        let refusals: [DiagnosisCopy.Row] = [
            DiagnosisCopy.heat(.unknown, load: .noPowerSignal),
            DiagnosisCopy.load(.noPowerSignal),
            DiagnosisCopy.source(.measuring),
            DiagnosisCopy.cooling(.notControlling),
        ]
        for row in refusals {
            let text = "\(row.title) \(row.metric ?? "") \(row.note ?? "")".lowercased()
            let refuses = ["no ", "not ", "cannot", "nothing", "reading"].contains { text.contains($0) }
            #expect(refuses, "this reads like an answer: \(row.title) / \(row.note ?? "")")
        }
    }

    @Test("An unsettled reading never publishes a °C/W figure")
    func measuringPublishesNoQuotient() {
        let row = DiagnosisCopy.load(.measuring(watts: 25))
        #expect(row.title == "Drawing 25.0 W")
        #expect(row.metric?.contains("°C/W") == false)
        #expect(row.metric?.contains("measuring") == true)
    }

    // MARK: - The two power figures must never look like they sum

    /// The remainder is what is left after subtracting an independently-sourced
    /// figure — not a measurement, and not a slice of a pie. Words implying a
    /// partition invite exactly the arithmetic the numbers cannot support.
    ///
    /// Scoped to the **visible** line. The hover is where the relationship is
    /// spelled out, so it necessarily discusses summing and subtracting — the
    /// first version of this test banned "sum" there too and fired on "summed
    /// across every readable process", which is the sentence that makes the
    /// figure honest rather than one that misleads.
    @Test("The visible accounting line never implies a total or a partition")
    func accountingImpliesNoPartition() throws {
        let banned = ["total", "sum", "of which", "%", "altogether", "adds up to", "out of"]
        for comparedBoth in [true, false] {
            for unattributed in [Double?.some(31.7), nil] {
                let row = try #require(
                    DiagnosisCopy.accounting(Self.source(comparedBoth: comparedBoth, unattributed: unattributed))
                )
                let visible = (row.metric ?? "").lowercased()
                for word in banned {
                    #expect(!visible.contains(word), "'\(word)' invites the subtraction: \(row.metric ?? "")")
                }
            }
        }
    }

    /// …and the hover must actively deny the partition rather than merely avoid
    /// implying one. This is the sentence the whole feature's honesty rests on.
    @Test("The hover says outright that the two figures are not slices of one pie")
    func accountingHoverDeniesThePartition() throws {
        let row = try #require(DiagnosisCopy.accounting(Self.source(unattributed: 31.7)))
        let hover = try #require(row.hover)
        #expect(hover.contains("not"))
        #expect(hover.contains("two slices of one pie"))
        #expect(hover.contains("kernel") && hover.contains("SMC"), "it must name both sources")
    }

    @Test("The privacy fact stays on screen whenever there is something unreadable")
    func unreadableCountIsVisible() throws {
        let withRoot = try #require(DiagnosisCopy.accounting(Self.source(unreadable: 205)))
        #expect(withRoot.metric?.contains("205") == true)
        #expect(withRoot.metric?.contains("root") == true)

        let withoutRoot = try #require(DiagnosisCopy.accounting(Self.source(unreadable: 0)))
        #expect(withoutRoot.metric?.contains("root") == false)
    }

    /// The constraint a standing footer used to carry redundantly.
    ///
    /// "These numbers never add up to the whole machine" was cut for saying
    /// nothing — it editorialised about a fact this line already states as
    /// data. That only holds while the remainder is genuinely on screen, so
    /// that is what is pinned here rather than a sentence about it.
    @Test("The remainder is visible whenever there is one, without a disclaimer to explain it")
    func remainderIsVisibleAsData() throws {
        let row = try #require(DiagnosisCopy.accounting(Self.source(attributed: 9.9, unattributed: 31.7)))
        let metric = try #require(row.metric)
        #expect(metric.contains("9.9 W"), "what Ice Cube can attribute")
        #expect(metric.contains("31.7 W"), "and what it cannot — the two shown side by side is the point")
    }

    @Test("With no system power figure there is no remainder claimed")
    func noRemainderWithoutSystemPower() throws {
        let row = try #require(DiagnosisCopy.accounting(Self.source(unattributed: nil)))
        #expect(row.metric?.contains("rest of machine") == false)
    }

    // MARK: - The curve percentage never reaches the screen

    /// `commandedFraction` is a fraction of the *curve*; the RPM range starts at
    /// the fan's own minimum, not zero. 45 % of 2317–6800 is 4334 RPM, so
    /// printing "45 %" beside "3400 of 6800" (50 %) invites a check that cannot
    /// pass. It belongs on hover, with the reason.
    @Test("The fans row shows no percentage")
    func fansRowHasNoPercentage() {
        let row = DiagnosisCopy.cooling(.headroom(commandedFraction: 0.45, currentRPM: 3400, maximumRPM: 6800))
        #expect(row.title.contains("%") == false)
        #expect(row.metric?.contains("%") == false)
        #expect(row.note?.contains("%") != true)
        // …and the hover both gives it and explains why it will not reconcile.
        #expect(row.hover?.contains("45 %") == true)
        #expect(row.hover?.contains("not of the RPM range") == true)
    }

    // MARK: - "leading" is only claimed when both classes were read

    @Test("Without both sensor classes, no side is called the leader")
    func noLeaderWithoutBothClasses() {
        let row = DiagnosisCopy.source(Self.source(leading: .cpu, comparedBoth: false))
        #expect(row.title == "CPU energy by process")
        #expect(!row.title.contains("hotter"))
    }

    @Test("With both classes read, the title names the leader")
    func leaderNamedWhenComparable() {
        #expect(DiagnosisCopy.source(Self.source(leading: .cpu)).title == "CPU hotter than GPU")
        #expect(DiagnosisCopy.source(Self.source(leading: .gpu)).title == "GPU hotter than CPU")
    }

    /// When the GPU leads, the process list is measuring the wrong thing. That
    /// caveat is visible, not hover — a reader who misses it draws exactly the
    /// wrong conclusion from small process figures.
    @Test("A GPU-led machine says on screen that the list cannot see the GPU")
    func gpuLedCarriesAVisibleCaveat() throws {
        let note = try #require(DiagnosisCopy.source(Self.source(leading: .gpu)).note)
        #expect(note.contains("cannot see"))
        #expect(DiagnosisCopy.source(Self.source(leading: .cpu)).note?.contains("cannot see") != true)
    }

    // MARK: - The owner's rule: don't explain the domain to a domain user

    /// Anyone who installs a fan controller knows noise buys degrees and that
    /// dust blocks vents. Those sentences were the bulk of the old window.
    @Test("No visible text restates what installing the app already implies")
    func noObviousAdvice() {
        let banned = [
            "would trade noise",
            "nothing left to give",
            "worth checking",
            "blocked vents",
            "dust on the heatsink",
        ]
        for row in Self.everyRow {
            let visible = "\(row.title) \(row.metric ?? "") \(row.note ?? "")".lowercased()
            for phrase in banned {
                #expect(!visible.contains(phrase), "on-screen text restates the obvious: \(phrase)")
            }
        }
    }

    /// The corrections a reasonable person would otherwise get wrong stay
    /// reachable — they are the opposite of obvious.
    @Test("The two non-obvious corrections survive on hover")
    func nonObviousCorrectionsSurvive() throws {
        let hot = try #require(DiagnosisCopy.heat(Self.measured(95, .hot), load: .measuring(watts: 40)).hover)
        #expect(hot.contains("95–105 °C"), "that Apple Silicon runs this hot is not obvious")

        let explained = try #require(
            DiagnosisCopy.load(.explained(watts: 38, riseCelsius: 44, resistance: 1.16)).hover
        )
        #expect(explained.contains("not with another Mac"), "°C/W looks like a benchmark and is not")
    }

    // MARK: - Formatting

    /// Rendered through `String(format:)` rather than interpolated into a
    /// `Text`, so a locale that groups thousands cannot show 6800 RPM as
    /// "6.800 RPM" on the owner's Dutch-locale machine.
    @Test("Fan figures carry no grouping separator")
    func fanFiguresAreUngrouped() throws {
        let row = DiagnosisCopy.cooling(.atMaximum(rpm: 6800))
        let metric = try #require(row.metric)
        #expect(metric.contains("6800"))
        #expect(!metric.contains("6,800") && !metric.contains("6.800"))
    }

    @Test("The ceiling quoted to the user is the one the daemon enforces")
    func ceilingMatchesTheSafetyRule() throws {
        let hover = try #require(DiagnosisCopy.heat(Self.measured(71, .warm), load: .measuring(watts: 25)).hover)
        #expect(hover.contains("\(Int(SafetyMonitor.Limits().dieCeiling)) °C"))
    }
}

/// The charging row is the only copy in this window that names a cause, so what
/// it says and — more importantly — when it says nothing at all are both pinned.
@Suite("DiagnosisCopy — the charging row")
struct DiagnosisChargingCopyTests {
    @Test("Silence produces no row at all, not an empty one")
    func silenceIsNoRow() {
        #expect(DiagnosisCopy.charging(.silent, style: .celsius) == nil)
    }

    @Test("The row cites the reading and its limit, so the verdict stays checkable")
    func rowCitesItsEvidence() throws {
        let row = try #require(DiagnosisCopy.charging(.warm(batteryCelsius: 34.8), style: .celsius))
        #expect(row.title == "Warm from charging")
        let metric = try #require(row.metric)
        #expect(metric.contains("35 °C"), "the battery reading, got \(metric)")
        #expect(metric.contains("95 °C"), "and the limit it is nowhere near, got \(metric)")
    }

    /// The most useful sentence the window can produce here, and the one a
    /// fan-control app is uniquely placed to write: a worried user's instinct is
    /// to force the fans to maximum, which buys noise and nothing else.
    @Test("It says the fans cannot help")
    func itSaysTheFansCannotHelp() throws {
        let row = try #require(DiagnosisCopy.charging(.warm(batteryCelsius: 35), style: .celsius))
        let note = try #require(row.note)
        #expect(note.lowercased().contains("fans cannot reach it"))
    }

    /// Every temperature in this row is an absolute, so all of them convert.
    /// A stray hardcoded "33 °C" in the hover would leave a Fahrenheit user
    /// reading one Celsius number in a sentence of Fahrenheit ones.
    @Test("Nothing in the row is hardcoded Celsius")
    func fahrenheitConvertsThroughout() throws {
        let row = try #require(DiagnosisCopy.charging(.warm(batteryCelsius: 35), style: .fahrenheit))
        let text = [row.title, row.metric, row.note, row.hover].compactMap(\.self).joined(separator: " ")
        #expect(!text.contains("°C"), "a Celsius reading survived into Fahrenheit copy: \(text)")
        #expect(text.contains("95 °F"), "the 35 °C battery reads as 95 °F")
        #expect(text.contains("203 °F"), "the 95 °C limit reads as 203 °F")
        #expect(text.contains("91 °F"), "skin at 33 °C reads as 91 °F")
    }
}
