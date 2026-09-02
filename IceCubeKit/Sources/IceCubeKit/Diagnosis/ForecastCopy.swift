// ForecastCopy.swift — the words for a claim about the future, which must never read like a measurement.

import Foundation

/// Every word the forecast row says, as a pure function of the verdict.
///
/// Separated from layout for the reasons ``DiagnosisCopy`` already gives — it
/// is testable here and not inside a `View` body — plus one this row has on its
/// own.
///
/// ## The obligation this copy carries
///
/// Every other row in that window reports something **measured**: the die is
/// 79 °C, the fans are at 5,150 RPM, this process drew 4.2 W. This row reports
/// something **projected**, from a model that fits one thermal pole to a
/// machine that has two and treats the airflow reference as fixed while it
/// climbs.
///
/// A reader who cannot tell those apart will trust the projection exactly as
/// much as the thermometer, and the app will have earned that trust on the
/// thermometer's behalf. So the wording is built to be unmistakable:
///
/// - The title is **"Where this is heading"** — a direction, not a reading.
/// - Numbers are stated with their approximation out loud: *"about 2 min"*,
///   never *"2:04"*. Precision the model has not got must not appear in the
///   formatting.
/// - Refusals name the missing input, so a silent row is legibly *waiting*
///   rather than reporting calm.
///
/// `docs/DIAGNOSIS.md` records this as the rule for question 6.
public enum ForecastCopy {
    /// Whether this row should be drawn as a warning.
    ///
    /// Only for a projection that crosses the ceiling the daemon enforces —
    /// the one state here with an action attached and a clock on it. A hot
    /// machine that is *settling* is not a warning; that is what the heat row
    /// above already says, and colouring both would teach the eye to skip them.
    public static func isWarning(_ verdict: ThermalForecast.Verdict) -> Bool {
        if case .reachesCeiling = verdict {
            true
        } else {
            false
        }
    }

    /// The row for this verdict — an answer, a ceiling warning, or a named
    /// refusal. Always returns a row; whether it is *shown* is the caller's
    /// switch (`AppState.isForecastEnabled` leaves `forecast` nil when off).
    public static func row(
        _ verdict: ThermalForecast.Verdict,
        style: TemperatureStyle
    ) -> DiagnosisCopy.Row {
        switch verdict {
        case let .settling(projection):
            settlingRow(projection, style: style)
        case let .reachesCeiling(projection, seconds):
            ceilingRow(projection, inSeconds: seconds, style: style)
        case let .unavailable(gap):
            unavailableRow(gap)
        }
    }

    // MARK: - Answers

    private static func settlingRow(
        _ projection: ThermalForecast.Projection,
        style: TemperatureStyle
    ) -> DiagnosisCopy.Row {
        DiagnosisCopy.Row(
            title: "Where this is heading",
            metric: "settles at \(style.reading(projection.settlesAtCelsius)) · \(duration(projection.secondsToSettle))",
            note: note(for: projection, style: style),
            hover: hover
        )
    }

    private static func ceilingRow(
        _ projection: ThermalForecast.Projection,
        inSeconds seconds: TimeInterval,
        style: TemperatureStyle
    ) -> DiagnosisCopy.Row {
        let ceiling = SafetyMonitor.Limits().dieCeiling
        var lines = [
            "At this load the projection passes \(style.reading(ceiling)), so the safety rule "
                + "will force the fans to maximum before you get there.",
        ]
        if let counterfactual = projection.counterfactual {
            lines.append(counterfactualSentence(counterfactual, style: style))
        }
        return DiagnosisCopy.Row(
            title: "Where this is heading",
            metric: "reaches \(style.reading(ceiling)) \(duration(seconds))",
            note: lines.joined(separator: " "),
            hover: hover
        )
    }

    /// The prose under an answer, or `nil` when there is nothing worth adding.
    ///
    /// Two sentences at most, and both earn their place: what the user's own
    /// curve is about to do, and what a different fan speed would buy. Neither
    /// is inferable from the metric line, which is the bar `DiagnosisCopy` sets
    /// for showing prose at all.
    private static func note(
        for projection: ThermalForecast.Projection,
        style: TemperatureStyle
    ) -> String? {
        var lines: [String] = []
        if let rpm = projection.fanRPMAtSettle {
            lines.append("Your curve will take the fans to \(RPM.labeled(rpm)) as it climbs.")
        }
        if let counterfactual = projection.counterfactual {
            lines.append(counterfactualSentence(counterfactual, style: style))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The comparison the whole feature exists for, in the units the user pays
    /// the noise in.
    private static func counterfactualSentence(
        _ counterfactual: ThermalForecast.Counterfactual,
        style: TemperatureStyle
    ) -> String {
        "Running the fans harder — where this Mac has been measured before — would settle it at "
            + "\(style.reading(counterfactual.settlesAtCelsius)) instead, "
            + "\(style.difference(counterfactual.degreesSaved)) cooler."
    }

    // MARK: - Refusals

    /// A refusal names what is missing.
    ///
    /// The alternative — a dash and nothing else — is indistinguishable from a
    /// machine the app has decided is fine, which is the one reading this row
    /// must never produce by accident. Same discipline as
    /// ``CoolingTrendCopy``'s gap states.
    private static func unavailableRow(_ gap: ThermalForecast.Gap) -> DiagnosisCopy.Row {
        let note: String = switch gap {
        case let .noTimeConstantYet(estimates, need):
            "Still learning how fast this Mac heats: \(estimates) of \(need) measurements. "
                + "Each one needs three minutes of steady machine, so this takes a while."
        case let .bandNotMeasured(band):
            bandNote(band)
        case .loadNotSteady:
            "The load is still changing. A forecast needs a steady draw to head toward."
        case .fansUnreadable:
            "The fans cannot be read well enough to say which speed this is."
        case .beyondHorizon:
            "Further out than half an hour, which is further than this is willing to claim."
        }
        return DiagnosisCopy.Row(
            title: "Where this is heading",
            metric: "—",
            note: note,
            hover: hover
        )
    }

    private static func bandNote(_ band: FanBand) -> String {
        switch band {
        case .fanless:
            "This Mac has no fans, so there is no fan speed to compare against."
        case let .decile(decile):
            "No settled readings yet at this fan speed (\(decile * 10)–\(decile * 10 + 10) % of "
                + "maximum), so there is nothing to project from. It fills in as you use the machine."
        }
    }

    // MARK: - Formatting

    /// Durations, deliberately vague.
    ///
    /// A model this approximate must not print `2:04`. Rounding to the nearest
    /// half minute and prefixing "about" is the formatting carrying the
    /// model's honesty, which is the only place a reader will look for it.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "already there" }
        if seconds < 45 {
            return "under a minute"
        }
        let minutes = (seconds / 60).rounded()
        return "about \(Int(minutes)) min"
    }

    /// The explanation, on hover and mirrored into the accessibility hint.
    ///
    /// Carries the two approximations, because they are the difference between
    /// a number worth acting on and one worth ignoring, and a reader cannot
    /// infer either from the row.
    static let hover = """
    A projection, not a reading. Ice Cube learns how fast this Mac's die \
    approaches the temperature a given load settles at, and how much heat each \
    fan speed removes, from its own recorded history — so these are your \
    machine's numbers, not a generic model of a MacBook.

    Two things it is approximate about. Silicon responds in seconds and the \
    chassis in minutes; this fits the slower of the two, so it is optimistic \
    about the first few seconds after a load starts. And it treats the airflow \
    reading as fixed while it is in fact climbing, which costs a degree or two \
    over a couple of minutes.

    It never moves the fans. It is a description of where the machine is \
    already going.
    """
}
