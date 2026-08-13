// CurveEditor.swift — the curve editor window: preset loaders, parameter sliders, save & apply.

import IceCubeKit
import SwiftUI

/// The curve editor window. The plot itself lives in ``CurveCanvas``; this view
/// owns the chrome around it — loading presets in, tuning hysteresis and ramp,
/// and sending the result to the daemon.
struct CurveEditorView: View {
    let state: AppState
    @State private var model = CurveEditorModel()
    @State private var presetName = ""

    /// The name a pending save would overwrite, driving the confirmation.
    @State private var pendingOverwrite: String?
    @AppStorage("persistCurve") private var persistCurve = false

    /// Why the window is still here after an Apply — see ``CurveApplyPolicy``.
    /// `nil` in the ordinary case, because the ordinary case closed the window.
    @State private var applyResolution: CurveApplyPolicy.Resolution?

    /// Closes this window. Applying a curve is the one thing the editor exists
    /// to do, so finishing it puts the workbench away.
    @Environment(\.dismiss) private var dismiss

    /// Guards the one-shot seeding below.
    @State private var didSeed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            // A preset file we could not read is real data loss — say so here
            // rather than only in the log, and name the recoverable copy.
            if let failure = state.presets.loadFailure {
                Label(
                    "Saved presets could not be read. The old file was kept as “\(failure)”.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            }
            CurveCanvas(model: model, hottestDie: state.hottestDie)
                .frame(minHeight: 240)
            footer
        }
        .padding(Theme.Metrics.popoverPadding)
        .frame(minWidth: 600, minHeight: 430)
        .confirmationDialog(
            "Replace “\(pendingOverwrite ?? "")”?",
            isPresented: Binding(get: { pendingOverwrite != nil }, set: {
                if !$0 {
                    pendingOverwrite = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                state.presets.saveUserPreset(named: presetName, curve: model.curve)
                presetName = ""
                pendingOverwrite = nil
            }
            Button("Cancel", role: .cancel) { pendingOverwrite = nil }
        } message: {
            Text("The curve saved under this name will be replaced. This cannot be undone.")
        }
        // Sliders, toggle, and buttons all take the ice-blue brand accent.
        .tint(Theme.accent)
        // Open on the curve the fans are actually running — see
        // ``CurveEditorSeed`` for why the daemon's report outranks our own
        // memory of what we sent.
        //
        // Once per window lifetime, and unconditionally latched. `.task` runs
        // again if a window re-appears without being rebuilt, and replacing
        // points somebody is mid-edit on is a worse failure than opening on
        // Balanced during the second after a cold launch when no status has
        // arrived yet — which is exactly what this window did before.
        .task {
            guard !didSeed else { return }
            didSeed = true
            if let seed = CurveEditorSeed.seed(
                enforced: state.helper.status, applied: state.helper.lastAppliedConfig
            ) {
                model.load(seed)
            }
        }
        .onChange(of: state.snapshot) {
            if let die = state.hottestDie {
                model.updatePreview(die: die)
            }
        }
    }

    // MARK: - Header: load presets into the editor

    private var header: some View {
        HStack(spacing: 8) {
            // The preset loaders live in a floating glass pod — a small hovering
            // control cluster, distinct from the canvas it acts on.
            HStack(spacing: 8) {
                Text("Load").premiumSectionLabel()
                ForEach(
                    [("Quiet", FanCurve.quiet), ("Balanced", .balanced), ("Cold", .cold), ("Max", .max)],
                    id: \.0
                ) { name, curve in
                    Button(name) { model.load(curve) }
                        .buttonStyle(.borderless)
                }
                ForEach(state.presets.userPresets) { preset in
                    if let curve = preset.config.sharedCurve {
                        Button(preset.name) { model.load(curve) }
                            .buttonStyle(.borderless)
                            .contextMenu {
                                Button("Delete \u{201C}\(preset.name)\u{201D}", role: .destructive) {
                                    state.presets.removeUserPreset(preset)
                                }
                            }
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .floatingGlass(in: Capsule())
            Spacer()
            Text("double-click: add · ⌫: remove · arrows: nudge")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Footer: parameters, persist, apply, save

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Two rows, each narrower than the window's minimum width — a
            // footer that can outgrow the window pushes the whole layout past
            // its borders. Labels stay fixed-width + monospaced so nothing
            // moves while a slider is being dragged.
            HStack(spacing: 10) {
                Text("Hysteresis \(model.hysteresis, specifier: "%.0f")°")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 78, alignment: .leading)
                Slider(value: $model.hysteresis, in: 0 ... 8, step: 1)
                    .frame(width: 100)
                    .controlSize(.mini)
                Text("Ramp \(Int(model.ramp * 100))%/tick")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 86, alignment: .leading)
                Slider(value: $model.ramp, in: 0.02 ... 0.3)
                    .frame(width: 100)
                    .controlSize(.mini)
                Spacer(minLength: 0)
                if state.isSimulated {
                    Text("SIMULATED")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.warning)
                        .help("Applying a curve needs real hardware")
                }
            }
            HStack(spacing: 8) {
                Toggle("Keep running when app quits", isOn: $persistCurve)
                    .font(.caption)
                    .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                TextField("Preset name", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Button("Save Preset") {
                    // Saving over an existing name replaces it outright — that
                    // is also the only way to *edit* a preset, so the action
                    // stays, but it no longer destroys a curve silently.
                    if state.presets.wouldReplace(name: presetName) {
                        pendingOverwrite = presetName.trimmingCharacters(in: .whitespaces)
                    } else {
                        state.presets.saveUserPreset(named: presetName, curve: model.curve)
                        presetName = ""
                    }
                }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Apply Curve") {
                    Task { await applyCurve() }
                }
                .primaryGlassButton()
                .disabled(!canApply)
            }
            applyNotice
        }
        .controlSize(.small)
    }

    /// The sentence that explains a window which did not close.
    @ViewBuilder
    private var applyNotice: some View {
        switch applyResolution {
        case .none, .close:
            EmptyView()
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        case let .waiting(message):
            // Secondary, not `Theme.warning`, for the reason `FanControlSection`
            // gives: nothing has gone wrong and there is nothing to act on.
            Label(message, systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canApply: Bool {
        guard case .connected = state.helper.connection else { return false }
        return model.curve.isUsable && !state.isSimulated
    }

    private func applyCurve() async {
        var config = FanConfig.curve(model.curve, persists: persistCurve)
        config.hysteresisCelsius = model.hysteresis
        config.rampPerTick = model.ramp
        // Cleared before the send, not after: a notice left over from the last
        // attempt sitting under a button the user just pressed again reads as
        // this attempt's answer, arriving instantly.
        applyResolution = nil
        let outcome = await state.helper.apply(config)
        let resolution = CurveApplyPolicy.resolve(outcome, error: state.helper.lastError)
        applyResolution = resolution
        if resolution == .close {
            dismiss()
        }
    }
}
