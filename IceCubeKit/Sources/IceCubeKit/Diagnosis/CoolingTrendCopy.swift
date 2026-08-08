// CoolingTrendCopy.swift — every word the cooling trend says, as a pure function of the verdict.

import Foundation

/// The trend's copy, separated from its layout for `DiagnosisCopy`'s two
/// reasons: it is testable here and not inside a `View` body, and the wording
/// carries obligations — a refusal must stay distinguishable from an answer,
/// the percent is never signed (the words *worse* and *better* carry the
/// direction; "+18 %" on a lower-is-better metric is genuinely ambiguous),
/// and a claim never outruns `docs/THERMAL.md`'s caveats.
public enum CoolingTrendCopy {
    /// What the live snapshot says about whether history is possible at all —
    /// so a Mac that can never record is told *why* instead of collecting a
    /// baseline forever.
    public struct Capabilities: Sendable, Equatable {
        public let hasPowerReading: Bool
        public let hasAirflowSensor: Bool

        public init(hasPowerReading: Bool, hasAirflowSensor: Bool) {
            self.hasPowerReading = hasPowerReading
            self.hasAirflowSensor = hasAirflowSensor
        }

        /// From a live snapshot; a `nil` snapshot assumes capable — the app
        /// must not claim impossibility without evidence.
        public init(snapshot: SMCSnapshot?) {
            hasPowerReading = snapshot == nil || snapshot?.power != nil
            hasAirflowSensor = snapshot.map { reading in
                reading.temperatures.contains { SMCKeyMaps.isAirflowKey($0.key) }
            } ?? true
        }
    }

    /// Whether this verdict earns the warning triangle. Only the jump: a
    /// months-long drift has no moment that deserves orange, and colouring it
    /// would train the eye to ignore the one state that means *now* — the
    /// same reasoning that keeps 95 °C out of the warning band.
    public static func isWarning(_ verdict: CoolingTrend.Verdict) -> Bool {
        if case .suddenJump = verdict {
            return true
        }
        return false
    }

    /// The one row every surface renders. `readings` is the store's total
    /// count, for the progress denominators that make weeks of collecting
    /// look intentional rather than broken.
    public static func row(
        _ verdict: CoolingTrend.Verdict,
        capabilities: Capabilities,
        readings: Int,
        style: TemperatureStyle = .celsius,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian),
        locale: Locale = .current
    ) -> DiagnosisCopy.Row {
        switch verdict {
        case .noHistory:
            return noHistoryRow(capabilities)

        case let .collectingBaseline(since, readyAfter):
            return DiagnosisCopy.Row(
                title: "Building a baseline",
                metric: "\(readings) readings since \(day(since, calendar: calendar, locale: locale))",
                note: "Comparisons begin \(day(readyAfter, calendar: calendar, locale: locale)) — "
                    + "a baseline needs a month of distance before \u{201C}worse than last "
                    + "month\u{201D} means anything.",
                hover: "A reading is taken when power and die temperature hold steady for "
                    + "\(whole(CoolingEfficiency.settleWindow)) seconds — the same rule the live "
                    + "figure uses — and is filed under the fan speed it was taken at, because "
                    + "\(style.symbol)/W is only comparable at comparable fan speeds. Whole days "
                    + "can pass without one; that is the rule working, not a fault."
            )

        case let .insufficientComparableReadings(reason, _):
            return insufficientRow(reason, readings: readings, style: style)

        case let .stable(comparison):
            return stableRow(comparison, style: style, now: now, calendar: calendar, locale: locale)

        case let .slowRise(comparison):
            let era = era(of: comparison.since, now: now, calendar: calendar, locale: locale)
            return DiagnosisCopy.Row(
                title: "Cooling is \(percent(comparison.resistanceChangeFraction)) worse than \(era)",
                metric: metricLine(comparison, era: era, style: style),
                note: "Dust in the vents or on the fins is the usual cause at this pace, dried "
                    + "paste the next. Clearing the vents costs nothing, and this number is what "
                    + "tells you whether it worked.",
                hover: methodology(comparison, era: era)
                    + " Two other things move it the same way: a warmer room across the same "
                    + "months moves it a little, and anything that lowered the machine's power "
                    + "draw without changing what the chip does — a display unplugged since then — "
                    + "moves it more."
            )

        case let .improved(comparison):
            let era = era(of: comparison.since, now: now, calendar: calendar, locale: locale)
            return DiagnosisCopy.Row(
                title: "Cooling is \(percent(comparison.resistanceChangeFraction)) better than \(era)",
                metric: metricLine(comparison, era: era, style: style),
                note: "If you cleared the vents or repasted it, this is what that looks like.",
                hover: methodology(comparison, era: era)
                    + " One caution: anything that raised the machine's power draw without "
                    + "heating the chip — a display plugged in since then — reads the same way."
            )

        case let .suddenJump(_, change, referenceDays, jumpReadings):
            return DiagnosisCopy.Row(
                title: "Cooling changed abruptly",
                metric: "\(percent(change)) above the last \(referenceDays) days "
                    + "· \(jumpReadings) readings today",
                note: "A step this fast is a stopped fan or something blocking the vents right "
                    + "now, not dust building up. Ice Cube reports a stopped fan on its own — if "
                    + "nothing else says so, look for what is covering the vents.",
                hover: "Today's \(jumpReadings) settled readings sit \(percent(change)) above the "
                    + "same fan speed's own last \(referenceDays) days. Dust does not do that in a "
                    + "day. Ice Cube states the numbers and stops there — it cannot see inside "
                    + "the machine."
            )
        }
    }

    // MARK: - The states without a comparison

    private static func noHistoryRow(_ capabilities: Capabilities) -> DiagnosisCopy.Row {
        if !capabilities.hasPowerReading {
            return DiagnosisCopy.Row(
                title: "No cooling history on this Mac",
                note: "Cooling efficiency needs a system power figure, and this Mac reports "
                    + "none — so there is nothing to record.",
                hover: "°C/W is degrees of die rise per watt the machine draws. Without the "
                    + "watts there is no quotient, so Ice Cube records nothing rather than a "
                    + "history of one number."
            )
        }
        if !capabilities.hasAirflowSensor {
            return DiagnosisCopy.Row(
                title: "No cooling history on this Mac",
                note: "Cooling efficiency needs an airflow sensor for its reference, and this "
                    + "Mac reports none — so there is nothing to record.",
                hover: "°C/W measures the die's rise above intake air. Without an airflow "
                    + "sensor there is no reference, so Ice Cube records nothing rather than "
                    + "measuring against a guess."
            )
        }
        return DiagnosisCopy.Row(
            title: "No readings yet",
            note: "A reading is taken when the machine holds steady for "
                + "\(whole(CoolingEfficiency.settleWindow)) seconds; the first usually lands "
                + "within minutes of ordinary use.",
            hover: "Each settled reading stores the °C/W figure, the watts and temperatures it "
                + "came from, and the fan speed it was taken at. Everything stays on this Mac "
                + "and never enters the diagnostics export."
        )
    }

    private static func insufficientRow(
        _ reason: CoolingTrend.Gap, readings: Int, style: TemperatureStyle
    ) -> DiagnosisCopy.Row {
        let note = switch reason {
        case .fanSpeedDrifted:
            "The fans have been running at a different speed than during the baseline, and "
                + "\(style.symbol)/W is only comparable at matching speeds."
        case .noBandHasBothEpochs, .tooFewRecentDays, .tooFewBaselineDays:
            "These readings are spread across fan speeds, and \(style.symbol)/W is only "
                + "comparable within one speed band. No band has enough on both sides of the "
                + "comparison yet."
        }
        return DiagnosisCopy.Row(
            title: "Not enough comparable readings",
            metric: "\(readings) readings",
            note: note,
            hover: "Ice Cube will not average across fan speeds to fill this in. On the machine "
                + "this was measured on, \(style.symbol)/W read 1.04–1.13 at 3550 RPM and "
                + "0.89–0.93 at 5950 — a spread from fan speed alone larger than the degradation "
                + "this is looking for. A number built by mixing the two would describe the "
                + "presets, not the hardware."
        )
    }

    private static func stableRow(
        _ comparison: CoolingTrend.Comparison,
        style: TemperatureStyle, now: Date, calendar: Calendar, locale: Locale
    ) -> DiagnosisCopy.Row {
        let era = era(of: comparison.since, now: now, calendar: calendar, locale: locale)
        let change = comparison.resistanceChangeFraction
        // Half the threshold: below it the number is noise and saying so is
        // itself noise; above it, honesty requires admitting the drift the
        // verdict declines to call.
        let visible = abs(change) >= CoolingTrend.slowRiseThreshold / 2
        return DiagnosisCopy.Row(
            title: "Cooling is steady",
            metric: metricLine(comparison, era: era, style: style),
            note: visible
                ? "\(percent(change)) \(change > 0 ? "higher" : "lower") than \(era) — inside "
                + "the spread of these measurements, not enough to call a change."
                : nil,
            hover: methodology(comparison, era: era)
                + " A change under \(whole(CoolingTrend.slowRiseThreshold * 100)) % is inside "
                + "the spread of these measurements, so it is not called one."
        )
    }

    // MARK: - Shared sentences

    private static func metricLine(
        _ comparison: CoolingTrend.Comparison, era: String, style: TemperatureStyle
    ) -> String {
        "now \(style.perWatt(comparison.recentMedian)) "
            + "· \(style.perWatt(comparison.baselineMedian)) \(era)"
    }

    private static func methodology(_ comparison: CoolingTrend.Comparison, era: String) -> String {
        "Median of \(comparison.recentReadings) readings from the last "
            + "\(CoolingTrend.recentSpanDays) days against \(comparison.baselineReadings) taken "
            + "\(era), all at the same fan speed. This compares your Mac with itself and says "
            + "nothing about any other Mac."
    }

    // MARK: - Naming a time

    /// "in June", "in November 2026", or — beyond eleven months, where a bare
    /// month invites reading it as *this* year's — "on 4 June 2025".
    /// Formatted from templates so every locale orders its own parts.
    static func era(of date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        var calendar = calendar
        calendar.locale = locale
        let months = calendar.dateComponents([.month], from: date, to: now).month ?? 0
        if months >= 11 {
            return "on \(format(date, template: "dMMMMy", calendar: calendar, locale: locale))"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let template = sameYear ? "MMMM" : "MMMMy"
        return "in \(format(date, template: template, calendar: calendar, locale: locale))"
    }

    /// "17 September" — for dates near enough that the year goes unsaid.
    private static func day(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        var calendar = calendar
        calendar.locale = locale
        return format(date, template: "dMMMM", calendar: calendar, locale: locale)
    }

    private static func format(
        _ date: Date, template: String, calendar: Calendar, locale: Locale
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// Whole and unsigned — the direction lives in the words around it.
    private static func percent(_ fraction: Double) -> String {
        "\(whole(abs(fraction) * 100)) %"
    }

    private static func whole(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}
