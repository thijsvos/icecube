// ForecastCopyTests.swift — a projection that reads like a measurement is the one failure that matters here.

import Foundation
@testable import IceCubeKit
import Testing

/// The forecast row sits among rows that report measurements. This suite is
/// mostly about keeping it distinguishable from them, and about a refusal never
/// reading as reassurance.
@Suite("ForecastCopy — words for a claim about the future")
struct ForecastCopyTests {
    private static let style = TemperatureStyle.celsius

    private static func projection(
        settlesAt: Double = 91,
        seconds: TimeInterval = 120,
        band: FanBand = .decile(6),
        rpm: Double? = 5150,
        counterfactual: ThermalForecast.Counterfactual? = nil
    ) -> ThermalForecast.Projection {
        ThermalForecast.Projection(
            settlesAtCelsius: settlesAt,
            secondsToSettle: seconds,
            settlingBand: band,
            fanRPMAtSettle: rpm,
            counterfactual: counterfactual
        )
    }

    private static let allGaps: [ThermalForecast.Gap] = [
        .noTimeConstantYet(estimates: 12, need: 20),
        .bandNotMeasured(.decile(4)),
        .bandNotMeasured(.fanless),
        .loadNotSteady,
        .fansUnreadable,
        .beyondHorizon,
    ]

    private static func row(_ verdict: ThermalForecast.Verdict) -> DiagnosisCopy.Row {
        ForecastCopy.row(verdict, style: style)
    }

    // MARK: - It must not read as a measurement

    /// Every state says where the machine is *heading*. The window's other rows
    /// say what it *is*, and a reader who cannot tell them apart will trust the
    /// projection as much as the thermometer.
    @Test("Every state is titled as a direction, never as a reading")
    func titleAlwaysReadsAsProjection() {
        var verdicts: [ThermalForecast.Verdict] = [
            .settling(Self.projection()),
            .reachesCeiling(Self.projection(settlesAt: 130), inSeconds: 180),
        ]
        verdicts += Self.allGaps.map { .unavailable($0) }
        for verdict in verdicts {
            #expect(Self.row(verdict).title == "Where this is heading", "\(verdict)")
        }
    }

    /// A model that fits one thermal pole to a two-pole machine must not print
    /// `2:04`. The formatting is where a reader looks for how much precision to
    /// grant a number, so it carries the approximation out loud.
    @Test("Durations are stated approximately, never to the second")
    func durationsAreVague() {
        #expect(ForecastCopy.duration(120) == "about 2 min")
        #expect(ForecastCopy.duration(150) == "about 3 min")
        #expect(ForecastCopy.duration(30) == "under a minute")
        #expect(ForecastCopy.duration(0) == "already there")
        for seconds in [61.0, 120.0, 300.0, 1500.0] {
            let text = ForecastCopy.duration(seconds)
            #expect(text.hasPrefix("about "), "\(seconds) s rendered as \(text)")
            #expect(!text.contains(":"), "a clock-style duration claims precision this has not got")
        }
    }

    /// The hover is the only place the two approximations appear, and they are
    /// the difference between a number worth acting on and one worth ignoring.
    @Test("The hover names both approximations and says it never moves the fans")
    func hoverCarriesTheCaveats() {
        let hover = ForecastCopy.hover
        #expect(hover.contains("projection, not a reading"))
        #expect(hover.contains("optimistic"), "the single-pole caveat must survive editing")
        #expect(hover.contains("airflow"), "the fixed-reference caveat must survive editing")
        #expect(hover.contains("never moves the fans"))
    }

    // MARK: - Answers

    @Test("A settling projection states the temperature and roughly when")
    func settlingStatesBoth() {
        let row = Self.row(.settling(Self.projection(settlesAt: 91, seconds: 120)))
        #expect(row.metric == "settles at 91 °C · about 2 min")
    }

    /// The sentence no other Mac fan tool can write, built from the user's own
    /// curve.
    @Test("A running curve is named with the fan speed it will command")
    func curveIsNamedWithItsFanSpeed() throws {
        let note = try #require(Self.row(.settling(Self.projection(rpm: 5150))).note)
        #expect(note.contains("5150 RPM"), "\(note)")
        #expect(!note.contains("5,150"), "RPM must not be grouped — see RPM, and the Dutch-locale bug")
    }

    @Test("Manual control says nothing about fan speed, because nothing will move them")
    func manualMentionsNoFanSpeed() {
        let row = Self.row(.settling(Self.projection(rpm: nil)))
        #expect(row.note == nil)
    }

    /// The comparison the feature exists for, in the units the noise is paid in.
    @Test("The counterfactual names both the temperature and the saving")
    func counterfactualNamesTheSaving() throws {
        let verdict = ThermalForecast.Verdict.settling(Self.projection(
            counterfactual: ThermalForecast.Counterfactual(
                band: .decile(9), settlesAtCelsius: 82, degreesSaved: 9
            )
        ))
        let note = try #require(Self.row(verdict).note)
        #expect(note.contains("82 °C"), "\(note)")
        #expect(note.contains("9 °C"), "\(note)")
    }

    // MARK: - The ceiling

    /// The one state with an action attached and a clock on it.
    @Test("Only a ceiling crossing is drawn as a warning")
    func onlyTheCeilingIsAWarning() {
        #expect(ForecastCopy.isWarning(.reachesCeiling(Self.projection(), inSeconds: 90)))
        #expect(!ForecastCopy.isWarning(.settling(Self.projection())))
        for gap in Self.allGaps {
            #expect(!ForecastCopy.isWarning(.unavailable(gap)), "a refusal is not a warning: \(gap)")
        }
    }

    /// The temperature quoted has to be the one the daemon actually enforces,
    /// or the window promises a deadline the machine does not keep.
    @Test("The ceiling row quotes the limit the daemon enforces")
    func ceilingRowQuotesTheRealLimit() throws {
        let row = Self.row(.reachesCeiling(Self.projection(settlesAt: 130), inSeconds: 180))
        let ceiling = SafetyMonitor.Limits().dieCeiling
        let metric = try #require(row.metric)
        #expect(metric.contains(Self.style.reading(ceiling)), "\(metric)")
        #expect(metric.contains("about 3 min"), "\(metric)")
    }

    @Test("The ceiling row says the safety rule will act first")
    func ceilingRowNamesTheSafetyRule() throws {
        let note = try #require(Self.row(.reachesCeiling(Self.projection(), inSeconds: 90)).note)
        #expect(note.contains("safety rule"), "\(note)")
        #expect(note.contains("maximum"), "\(note)")
    }

    // MARK: - Refusals

    /// A dash and nothing else is indistinguishable from a machine the app has
    /// decided is fine, which is the one reading this row must never produce by
    /// accident.
    @Test("Every refusal names what is missing", arguments: ForecastCopyTests.allGaps)
    func everyRefusalExplainsItself(gap: ThermalForecast.Gap) throws {
        let row = Self.row(.unavailable(gap))
        #expect(row.metric == "—")
        let note = try #require(row.note, "a bare dash reads as reassurance")
        #expect(note.count > 30, "too terse to explain anything: \(note)")
    }

    /// Distinguishable from each other, not merely present: two refusals with
    /// the same words would make the row useless for telling *why* it is quiet.
    @Test("No two refusals say the same thing")
    func refusalsAreDistinct() {
        let notes = Self.allGaps.compactMap { Self.row(.unavailable($0)).note }
        #expect(Set(notes).count == Self.allGaps.count, "duplicate refusal wording")
    }

    /// The collecting state shows progress, because the honest answer to "why
    /// is it blank" is "it is still working, and here is how far along".
    @Test("The collecting refusal shows how far along it is")
    func collectingShowsProgress() throws {
        let note = try #require(
            Self.row(.unavailable(.noTimeConstantYet(estimates: 12, need: 20))).note
        )
        #expect(note.contains("12 of 20"), "\(note)")
    }

    /// A fanless Mac is a supported configuration, not a fault.
    @Test("A fanless Mac is told that, not shown a band number")
    func fanlessIsExplained() throws {
        let note = try #require(Self.row(.unavailable(.bandNotMeasured(.fanless))).note)
        #expect(note.contains("no fans"), "\(note)")
        #expect(!note.contains("%"), "a fanless Mac has no fan-speed range to quote")
    }

    /// An unmeasured band should read as "not yet", not as a failure — it fills
    /// in on its own.
    @Test("An unmeasured fan speed reads as not-yet rather than broken")
    func unmeasuredBandReadsAsNotYet() throws {
        let note = try #require(Self.row(.unavailable(.bandNotMeasured(.decile(4)))).note)
        #expect(note.contains("40–50 %"), "\(note)")
        #expect(note.lowercased().contains("fills in"), "\(note)")
    }

    /// Fahrenheit reaches the words, and a *difference* must not take the
    /// 32-degree offset — the trap `TemperatureStyle.difference` exists for.
    @Test("Fahrenheit converts the reading and the saving correctly")
    func fahrenheitReachesTheWords() throws {
        let verdict = ThermalForecast.Verdict.settling(Self.projection(
            settlesAt: 100,
            counterfactual: ThermalForecast.Counterfactual(
                band: .decile(9), settlesAtCelsius: 90, degreesSaved: 10
            )
        ))
        let row = ForecastCopy.row(verdict, style: .fahrenheit)
        #expect(try #require(row.metric).contains("212 °F"), "100 °C is 212 °F")
        let note = try #require(row.note)
        #expect(note.contains("194 °F"), "90 °C is 194 °F")
        #expect(note.contains("18 °F"), "a 10 °C saving is 18 °F, not 50 °F")
    }
}

extension ThermalForecast.Gap: CustomTestStringConvertible {
    public var testDescription: String {
        "\(self)"
    }
}
