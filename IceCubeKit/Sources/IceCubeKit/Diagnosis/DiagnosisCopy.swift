// DiagnosisCopy.swift — every word the diagnosis window says, as a pure function of the verdict.

import Foundation

/// The window's copy, separated from its layout.
///
/// Two reasons it is not inlined in the view. It is **testable** here and not
/// there — the app target compiles only an allow-list of files into the test
/// bundle, and a `switch` inside a `View` body cannot be exercised at all. And
/// the wording carries obligations that outlive any layout: a refusal must stay
/// distinguishable from an answer, and the two power figures must never read as
/// two slices of one pie.
///
/// ## The rule that shaped this rewrite
///
/// **Do not explain the domain to someone who chose to install a domain tool**
/// (owner, 2026-08-07). Anyone who installs a fan controller already knows that
/// noise buys degrees, that dust blocks vents, and that a hotter chip is worse.
/// Sentences restating any of that were the bulk of the old window's text, so
/// they are gone. What survives on screen is the verdict, the numbers, and the
/// few things a reasonable person would get *wrong* — that Apple Silicon really
/// does run at 95 °C under load, and that °C/W is not comparable between Macs.
///
/// Titles state the verdict rather than pose the question. The window's own
/// title bar asks "Why is it hot?" once; four section headings re-asking it and
/// then answering twice each is what made the old design dense.
public enum DiagnosisCopy {
    /// One section's words.
    public struct Row: Sendable, Equatable {
        /// The headline — states the verdict, never a question.
        public let title: String
        /// The right-aligned numeric line, or `nil` when the section has none.
        public let metric: String?
        /// Visible prose. `nil` in every healthy state; present only where the
        /// user would otherwise get something wrong, or where the app is
        /// reporting a fault.
        public let note: String?
        /// The full explanation, shown on hover and mirrored into the
        /// accessibility hint. `.help()` is mouse-only, so it is never the sole
        /// carrier of anything load-bearing.
        public let hover: String?

        public init(title: String, metric: String? = nil, note: String? = nil, hover: String? = nil) {
            self.title = title
            self.metric = metric
            self.note = note
            self.hover = hover
        }
    }

    // MARK: - Temperature

    /// The heat headline.
    ///
    /// Takes the **load** as well, and this coupling is not decoration: with a
    /// hot die and no load to explain it, the reassuring qualifier "within
    /// design range" must not sit directly above a warning that says the
    /// opposite. The window would be arguing with itself.
    public static func heat(
        _ heat: ThermalDiagnosis.Heat,
        load: ThermalDiagnosis.Load,
        style: TemperatureStyle = .celsius
    ) -> Row {
        switch heat {
        case .unknown:
            Row(
                title: "No die sensor",
                note: "Nothing to judge against.",
                hover: "This Mac reports no CPU or GPU die sensor. Ice Cube will not judge chip "
                    + "temperature from a battery or enclosure reading, so this question stays "
                    + "unanswered."
            )
        case let .measured(celsius, label, band, headroom):
            Row(
                title: title(for: band, load: load),
                // `difference`, not `reading`: headroom is a gap between two
                // temperatures, so Fahrenheit scales it without the +32 offset.
                metric: "\(style.difference(headroom)) to limit",
                // The only band that keeps a visible sentence: it is the one
                // where Ice Cube is about to override the user's curve, which
                // is a thing the app does *to* them and must be said out loud.
                note: band == .nearCeiling
                    ? "At \(style.reading(dieCeiling)) Ice Cube forces maximum cooling."
                    : nil,
                hover: "Hottest die sensor: \(label) at \(style.reading(celsius)). Ice Cube forces "
                    + "maximum cooling at \(style.reading(dieCeiling)) whatever your curve asks "
                    + "for, so this reading has \(style.difference(headroom)) of headroom."
                    + (band == .hot
                        ? " Apple Silicon dies legitimately run \(style.range(95, 105)) under load, "
                        + "which is why this band is hot rather than a fault."
                        : "")
            )
        }
    }

    private static func title(for band: ThermalDiagnosis.Heat.Band, load: ThermalDiagnosis.Load) -> String {
        // Suppress the reassurance when the load section is about to contradict it.
        if case .hotWithoutLoad = load {
            return band == .nearCeiling ? "Very hot" : "Hot"
        }
        return switch band {
        case .cool: "Running cool"
        case .warm: "Normal temperature"
        case .hot: "Hot, within design range"
        case .nearCeiling: "Very hot"
        }
    }

    // MARK: - Power

    /// The load headline. States the measured fact, never a cause.
    public static func load(_ load: ThermalDiagnosis.Load, style: TemperatureStyle = .celsius) -> Row {
        switch load {
        case .noPowerSignal:
            Row(
                title: "No power reading",
                note: "This Mac reports no watts.",
                hover: "This Mac exposes no system power figure, so Ice Cube cannot say whether "
                    + "the work explains the heat. Heat per watt is unavailable for the same reason."
            )
        case let .measuring(watts):
            Row(
                title: "Drawing \(oneDecimal(watts)) W",
                metric: "heat per watt: measuring",
                hover: "Heat per watt needs the power and the temperature to hold steady for "
                    + "\(whole(CoolingEfficiency.settleWindow)) seconds. It settles when the "
                    + "machine does; a number published early would describe nothing."
            )
        case let .explained(watts, rise, resistance):
            Row(
                title: "Drawing \(oneDecimal(watts)) W",
                // Both are differences: a rise above airflow, and a rise per
                // watt. Neither takes the Fahrenheit offset.
                metric: "\(style.difference(rise)) above airflow · \(style.perWatt(resistance))",
                hover: "The die sits \(style.difference(rise)) above its own airflow while the "
                    + "machine draws \(oneDecimal(watts)) W. Lower \(style.symbol)/W is better, and "
                    + "it falls as the fans "
                    + "speed up. The reference is a sensor inside this Mac rather than the room, "
                    + "so compare it with your own past readings — not with another Mac."
            )
        case let .hotWithoutLoad(watts, celsius):
            // A finding, not a readout. This is the one state the window exists
            // for, and it keeps its sentence at full weight.
            Row(
                title: "Hot with no load to explain it",
                metric: "\(style.reading(celsius)) while drawing \(oneDecimal(watts)) W",
                hover: "Below \(whole(ThermalDiagnosis.idleWattsCeiling)) W this Mac is not working "
                    + "hard — measured at 7.9 W at true idle. A die this hot on that little power "
                    + "points at airflow rather than work: a blocked vent, a stopped fan, or dust "
                    + "on the heatsink. The cooling trend below says whether this is new or has "
                    + "been building for months."
            )
        }
    }

    // MARK: - Processes

    /// The process-section headline.
    public static func source(_ source: ThermalDiagnosis.Source) -> Row {
        switch source {
        case .measuring:
            return Row(
                title: "Reading processes…",
                hover: "Per-process power is a rate, not a counter reading, so it needs two "
                    + "samples a moment apart. The first figures arrive within a couple of seconds."
            )
        case let .measured(leading, comparedBoth, top, _, _, _):
            // Without both classes read, "leading" is not a claim to make.
            guard comparedBoth else {
                return Row(
                    title: "CPU energy by process",
                    note: top.isEmpty ? "No process is drawing measurable CPU power." : nil,
                    hover: "This Mac does not report both a CPU-class and a GPU-class die sensor, "
                        + "so Ice Cube will not say which side of the chip is leading. The list is "
                        + "CPU energy from the kernel."
                )
            }
            let gpuLed = leading == .gpu
            return Row(
                title: gpuLed ? "GPU hotter than CPU" : "CPU hotter than GPU",
                // Visible, not hover: when the GPU leads, the list below is
                // measuring the wrong thing, and a user reading it without that
                // caveat draws the wrong conclusion.
                note: gpuLed
                    ? "These are CPU figures. Ice Cube cannot see which app is using the GPU."
                    : (top.isEmpty ? "No process is drawing measurable CPU power." : nil),
                hover: "Which silicon leads comes from the SMC's sensor classes. The per-process "
                    + "figures come from the kernel's CPU energy counter, which cannot see GPU work "
                    + "at all — so during graphics work the process numbers stay small and the "
                    + "remainder grows."
            )
        }
    }

    /// The accounting caption: where constraint 2 (the figures do not sum) and
    /// the privacy fact both live.
    ///
    /// Deliberately built from `·`-separated facts rather than a sentence
    /// containing the words "total" or "of which". Both would invite the
    /// subtraction the two numbers cannot support.
    public static func accounting(_ source: ThermalDiagnosis.Source) -> Row? {
        guard case let .measured(_, _, _, attributed, unattributed, unreadable) = source else { return nil }
        var parts = ["processes \(oneDecimal(attributed)) W"]
        if let unattributed {
            parts.append("rest of machine \(oneDecimal(unattributed)) W")
        }
        if unreadable > 0 {
            parts.append("\(unreadable) more need root")
        }
        var hover = "The \(oneDecimal(attributed)) W is CPU energy summed across every readable "
            + "process, not just the ones listed. It comes from the kernel"
        hover += unattributed != nil
            ? "; the machine's figure comes from the SMC. They measure different things and are not "
            + "two slices of one pie — what is left over covers the display, GPU, SSD and radios"
            : ". This Mac reports no system power figure, so there is no remainder to state"
        hover += unreadable > 0
            ? ", plus \(unreadable) processes Ice Cube cannot read without root."
            : "."
        hover += " Ice Cube also cannot see GPU work per process. docs/DIAGNOSIS.md has the full "
            + "accounting."
        return Row(title: "", metric: parts.joined(separator: " · "), hover: hover)
    }

    // MARK: - Fans

    /// The cooling headline.
    ///
    /// **The curve percentage never appears on screen.** `commandedFraction` is
    /// a fraction of the *curve*, while the RPM range starts at the fan's own
    /// minimum rather than at zero — so 45 % of a 2317–6800 range is 4334 RPM,
    /// and printing "45 %" beside "3400 of 6800" (which is 50 %) invites an
    /// arithmetic check that cannot pass. It moves to hover, which says why.
    public static func cooling(_ cooling: ThermalDiagnosis.Cooling) -> Row {
        switch cooling {
        case .notControlling:
            Row(
                title: "Ice Cube is not driving the fans",
                hover: "Either no curve is active, or this Mac reports no fan Ice Cube can drive. "
                    + "Fan control is switched on in Settings."
            )
        case let .stalled(fan):
            // A fault. Keeps its sentence.
            Row(
                title: "\(fan) fan is not spinning",
                note: "Commanded above its own minimum, but reading below it.",
                hover: "Ice Cube commands a target RPM and reads back what the fan actually does. "
                    + "A fan reading below target for a second or two while it spins up is normal "
                    + "and is never reported here. Reading below the fan's own minimum while "
                    + "commanded above it is not."
            )
        case let .atMaximum(rpm):
            Row(
                title: "Curve is asking for everything",
                metric: "fans at \(RPM.labeled(rpm))",
                hover: "At this temperature your curve is already asking for 90 % or more of its "
                    + "range, so there is nothing left for Ice Cube to give. Only a cooler curve, "
                    + "or less load, changes the temperature from here."
            )
        case let .headroom(fraction, current, maximum):
            Row(
                title: "Fans have room to spare",
                metric: "\(RPM.text(current)) of \(RPM.labeled(maximum))",
                hover: "Your curve is asking for \(whole(fraction * 100)) % at this temperature. "
                    + "That percentage is of the curve, not of the RPM range — the range starts at "
                    + "the fan's own minimum rather than at zero, so it will not equal "
                    + "\(RPM.text(current)) ÷ \(RPM.text(maximum))."
            )
        }
    }

    // There is deliberately no footer.
    //
    // A standing line reading "these numbers never add up to the whole machine,
    // and are not meant to" was cut on 2026-08-07: it told the user nothing,
    // because it editorialised about a fact the accounting line above it already
    // states as data. "processes 9.9 W · rest of machine 31.7 W · 205 more need
    // root" shows both that the figures do not sum and that some are unreadable,
    // in the place the numbers actually are. The mechanism lives on that line's
    // hover. A disclaimer that repeats a visible fact in prose is furniture.

    /// Shown before the first differenced sample exists.
    public static let waiting = Row(
        title: "Measuring…",
        note: "The first reading takes a couple of seconds.",
        hover: "Per-process power is a rate, so it needs two readings a moment apart. Sampling "
            + "starts when this window opens and stops when it closes."
    )

    // MARK: - Formatting

    /// The die ceiling, read from the safety rule rather than typed in.
    ///
    /// A `Double`, not a formatted string: the caller renders it through the
    /// active ``TemperatureStyle``, and a pre-formatted "104" would have to be
    /// parsed back to convert.
    private static var dieCeiling: Double {
        SafetyMonitor.Limits().dieCeiling
    }

    /// Built as a `String` here rather than interpolated into a `Text`, so a
    /// locale that groups thousands cannot render 6800 as "6.800" — the trap
    /// ``RPM/text(_:)`` documents, and the reason this rounds through `Int`
    /// instead of reaching for a formatter that would have to be told not to.
    private static func whole(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func twoDecimals(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
