// DiagnosisView.swift — "why is it hot?", answered in four rows that each admit when they cannot answer.

import IceCubeKit
import SwiftUI

/// The Diagnose window: what Ice Cube can say about this moment, and nothing
/// more.
///
/// Its own window rather than a section of the Sensors browser. That window is
/// already sized to a computed ceiling (`SensorsWindowMetrics`) that two
/// previous additions broke, and this content is a different job: Sensors
/// answers *what are the numbers*, this answers *what do they mean*.
///
/// Every row here can say "I don't know", and the layout treats that as a
/// first-class state rather than an empty space — see `docs/DIAGNOSIS.md`.
struct DiagnosisView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                if let verdict = state.diagnosis {
                    HeatRow(heat: verdict.heat)
                    Divider()
                    LoadRow(load: verdict.load)
                    Divider()
                    SourceRow(source: verdict.source, isSimulated: state.isSimulated)
                    Divider()
                    CoolingRow(cooling: verdict.cooling)
                } else {
                    WaitingRow()
                }

                Divider()
                Text(
                    "Ice Cube reads the SMC and the kernel's per-process energy counters. "
                        + "It cannot see GPU work per process, and processes owned by root are "
                        + "invisible without privilege — so these figures never add up to the "
                        + "whole machine, and are not meant to."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Metrics.popoverPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { state.diagnosisAppeared() }
        .onDisappear { state.diagnosisDisappeared() }
    }
}

// MARK: - Rows

/// Shown for the first tick or two, before a process sample can exist.
private struct WaitingRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Measuring…")
                .font(.headline)
            Text(
                "Per-process power is a rate, so it needs two readings a moment apart. "
                    + "The first answer arrives within a couple of seconds."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HeatRow: View {
    let heat: ThermalDiagnosis.Heat

    var body: some View {
        Section(title: "How hot is it?") {
            switch heat {
            case .unknown:
                Text("This Mac reports no CPU or GPU die sensor, so there is nothing to judge.")
                    .foregroundStyle(.secondary)
            case let .measured(celsius, label, band, headroom):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(celsius.rounded())) °C")
                        .font(.system(.title2, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.temperatureColor(celsius))
                    Text(label)
                        .foregroundStyle(.secondary)
                }
                Text(Self.sentence(band: band, headroom: headroom))
            }
        }
    }

    /// Deliberately unalarmed in the `hot` band. CLAUDE.md records that die
    /// sensors legitimately reach 95–105 °C under load; a warning at 95 °C
    /// teaches the user to ignore the band that actually matters.
    static func sentence(band: ThermalDiagnosis.Heat.Band, headroom: Double) -> String {
        let room = "\(Int(headroom.rounded())) °C below the 104 °C limit Ice Cube enforces"
        return switch band {
        case .cool: "Comfortable — \(room)."
        case .warm: "Normal working temperature — \(room)."
        case .hot: "Hot, but within what this silicon is built for — \(room)."
        case .nearCeiling: "Very hot — \(room). Ice Cube forces maximum cooling at the limit."
        }
    }
}

private struct LoadRow: View {
    let load: ThermalDiagnosis.Load

    var body: some View {
        Section(title: "Does the work explain it?") {
            switch load {
            case .noPowerSignal:
                Text("This Mac exposes no power figure, so the question cannot be answered here.")
                    .foregroundStyle(.secondary)
            case let .measuring(watts):
                Text("Drawing \(Self.watts(watts)).")
                Text("Waiting for the machine to hold steady long enough to measure cooling efficiency.")
                    .foregroundStyle(.secondary)
            case let .explained(watts, rise, resistance):
                Text("Drawing \(Self.watts(watts)), and the die sits \(Int(rise.rounded())) °C above its own airflow.")
                Text(
                    "That is \(String(format: "%.2f", resistance)) °C per watt. "
                        + "Compare it with your own past readings — not with another Mac."
                )
                .foregroundStyle(.secondary)
            case let .hotWithoutLoad(watts, celsius):
                Label(
                    "\(Int(celsius.rounded())) °C while drawing only \(Self.watts(watts)) — "
                        + "there is no load here to explain that heat.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(Theme.warning)
                Text("Worth checking: blocked vents, a fan that has stopped, or dust on the heatsink.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func watts(_ value: Double) -> String {
        "\(String(format: "%.1f", value)) W"
    }
}

private struct SourceRow: View {
    let source: ThermalDiagnosis.Source
    let isSimulated: Bool

    var body: some View {
        Section(title: "What is producing it?") {
            switch source {
            case .measuring:
                Text("Measuring…").foregroundStyle(.secondary)
            case let .measured(leading, top, attributed, unattributed, unreadable):
                Text(leading == .gpu ? "The GPU is leading the CPU." : "The CPU is leading the GPU.")

                if isSimulated {
                    Label("Simulated processes — no real process was read.", systemImage: "theatermasks")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }

                if top.isEmpty {
                    Text("Nothing is drawing measurable CPU power right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(top) { process in
                        HStack {
                            Text(process.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text("\(String(format: "%.2f", process.watts)) W")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }

                Text(Self.accounting(attributed: attributed, unattributed: unattributed, unreadable: unreadable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The sentence that keeps the list honest.
    ///
    /// Per-process figures are CPU energy from the kernel; the system figure is
    /// the whole machine from the SMC. They are independent measurements of
    /// different things, so the remainder is stated rather than hidden — a list
    /// that appeared to sum to the total would be the lie this feature exists
    /// not to tell.
    static func accounting(attributed: Double, unattributed: Double?, unreadable: Int) -> String {
        var text = "CPU energy accounts for \(String(format: "%.1f", attributed)) W across every readable process."
        if let unattributed {
            text += " The other \(String(format: "%.1f", unattributed)) W is the display, GPU, SSD and radios"
            text += unreadable > 0 ? ", plus \(unreadable) processes that need root to read." : "."
        } else if unreadable > 0 {
            text += " \(unreadable) processes need root to read."
        }
        return text
    }
}

private struct CoolingRow: View {
    let cooling: ThermalDiagnosis.Cooling

    var body: some View {
        Section(title: "Is cooling doing all it can?") {
            switch cooling {
            case .notControlling:
                Text("Ice Cube is not driving the fans right now.")
                    .foregroundStyle(.secondary)
            case let .stalled(fan):
                Label(
                    "The \(fan) fan is commanded to spin but is reading below its own minimum.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(Theme.warning)
            case let .atMaximum(rpm):
                Text("Your curve is already asking for everything — fans at \(RPM.labeled(rpm)).")
                Text("There is nothing left to give at this temperature.")
                    .foregroundStyle(.secondary)
            case let .headroom(fraction, current, maximum):
                Text(
                    "Your curve is asking for \(Int((fraction * 100).rounded())) % at this temperature — "
                        + "fans at \(RPM.labeled(current)) of a possible \(RPM.labeled(maximum))."
                )
                Text("A cooler preset would trade noise for temperature here.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shared layout

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
