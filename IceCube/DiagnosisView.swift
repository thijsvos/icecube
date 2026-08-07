// DiagnosisView.swift — "why is it hot?", laid out. Every word it says lives in DiagnosisCopy.

import IceCubeKit
import SwiftUI

/// The Diagnose window: four verdicts, their numbers, and nothing else.
///
/// Its own window rather than a section of the Sensors browser. That window is
/// sized to a computed ceiling (`SensorsWindowMetrics`) that two earlier
/// additions broke, and this content is a different job: Sensors answers *what
/// are the numbers*, this answers *what do they mean*.
///
/// **This view holds no copy.** Every string comes from ``DiagnosisCopy``,
/// which is pure and tested — a `switch` inside a `View` body cannot be
/// exercised by anything, and the wording here carries obligations (a refusal
/// must stay distinguishable from an answer; the two power figures must never
/// read as two slices of one pie) that deserve tests rather than review.
struct DiagnosisView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                if let verdict = state.diagnosis {
                    SectionRow(copy: DiagnosisCopy.heat(verdict.heat, load: verdict.load)) {
                        if case let .measured(celsius, label, _, _) = verdict.heat {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(temperature(celsius))
                                    .font(.system(.title2, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Theme.temperatureColor(celsius))
                                Text(label)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    Divider()
                    SectionRow(copy: DiagnosisCopy.load(verdict.load), isWarning: isAnomalous(verdict.load))
                    Divider()
                    ProcessSection(source: verdict.source, isSimulated: state.isSimulated)
                    Divider()
                    SectionRow(copy: DiagnosisCopy.cooling(verdict.cooling), isWarning: isStalled(verdict.cooling))
                } else {
                    SectionRow(copy: DiagnosisCopy.waiting)
                }

                Divider()
                Caption(copy: DiagnosisCopy.footer)
            }
            .padding(Theme.Metrics.popoverPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { state.diagnosisAppeared() }
        .onDisappear { state.diagnosisDisappeared() }
    }

    /// Formatted before it reaches `Text`, so a locale that groups thousands
    /// cannot turn a reading into "1.013 °C".
    private func temperature(_ celsius: Double) -> String {
        "\(Int(celsius.rounded())) °C"
    }

    private func isAnomalous(_ load: ThermalDiagnosis.Load) -> Bool {
        if case .hotWithoutLoad = load {
            return true
        }
        return false
    }

    private func isStalled(_ cooling: ThermalDiagnosis.Cooling) -> Bool {
        if case .stalled = cooling {
            return true
        }
        return false
    }
}

// MARK: - Building blocks

/// One section: verdict headline, optional numbers, optional sentence.
///
/// The hover text is mirrored into `.accessibilityHint` on the same combined
/// element. `.help()` is mouse-only, so anything load-bearing that lived there
/// alone would be invisible to VoiceOver and to anyone driving by keyboard.
private struct SectionRow<Extra: View>: View {
    let copy: DiagnosisCopy.Row
    var isWarning = false
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if isWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
                Text(copy.title)
                    .font(.headline)
                    .foregroundStyle(isWarning ? Theme.warning : .primary)
                if copy.hover != nil {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            extra
            if let metric = copy.metric {
                Text(metric)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let note = copy.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(isWarning ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .modifier(Explains(copy.hover))
    }
}

extension SectionRow where Extra == EmptyView {
    init(copy: DiagnosisCopy.Row, isWarning: Bool = false) {
        self.init(copy: copy, isWarning: isWarning) { EmptyView() }
    }
}

/// The process list plus the accounting line.
private struct ProcessSection: View {
    let source: ThermalDiagnosis.Source
    let isSimulated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(DiagnosisCopy.source(source).title)
                    .font(.headline)
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if isSimulated {
                    // A capsule rather than a sentence: orange and a mask icon
                    // say "not real" louder than seven words did.
                    Label("Simulated", systemImage: "theatermasks")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.warning.opacity(0.15), in: Capsule())
                        .help("Simulated processes — no real process was read. The fake PIDs sit above "
                            + "Darwin's ceiling of 99999, so a simulated row cannot name a real process.")
                }
            }
            .accessibilityElement(children: .combine)
            .modifier(Explains(DiagnosisCopy.source(source).hover))

            if let note = DiagnosisCopy.source(source).note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .measured(_, _, top, _, _, _) = source {
                ForEach(top) { process in
                    HStack {
                        Text(process.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        Text(String(format: "%.2f W", process.watts))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            if let accounting = DiagnosisCopy.accounting(source) {
                Caption(copy: accounting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A one-line caption whose full text lives on hover.
private struct Caption: View {
    let copy: DiagnosisCopy.Row

    var body: some View {
        Text(copy.metric ?? copy.note ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityElement(children: .combine)
            .modifier(Explains(copy.hover))
    }
}

/// Attaches hover text and its accessibility mirror together, so the two cannot
/// drift apart — the failure mode being an explanation only a mouse can reach.
private struct Explains: ViewModifier {
    let text: String?

    init(_ text: String?) {
        self.text = text
    }

    func body(content: Content) -> some View {
        if let text {
            content.help(text).accessibilityHint(text)
        } else {
            content
        }
    }
}
