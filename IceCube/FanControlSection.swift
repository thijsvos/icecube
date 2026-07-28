// FanControlSection.swift — the popover's fan-control area: onboarding, approval, manual sliders, revert.

import IceCubeKit
import SwiftUI

/// The control section of the popover.
///
/// What it shows depends on where the helper stands: onboarding (not
/// registered) → approval prompt → manual controls. Manual mode gets an
/// unmissable orange tint (PLAN.md §1.2), and "Auto" is always the biggest,
/// easiest action.
struct FanControlSection: View {
    /// A plain `let`: observation-driven redraw works without @Bindable, which
    /// exists only to project `$`-bindings — and this view forms none.
    let helper: HelperManager
    /// Live fan readings (for slider ranges and current values).
    let fans: [Fan]
    /// Closes the popover. Injected rather than re-derived from
    /// `@Environment(\.dismiss)` here, so the two-mode dismissal is defined in
    /// exactly one place (`PopoverView.dismissPopover`) — this section is only
    /// ever built inside the popover, and a second copy of that logic is a
    /// second copy to keep right.
    let dismissPopover: () -> Void

    /// Slider positions, per fan id. Committed to the daemon on release only
    /// — dragging must not spam the SMC with writes.
    @State private var sliderTargets: [Int: Double] = [:]

    private var isManual: Bool {
        helper.status?.mode == .manual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.cardContentSpacing) {
            Text("Control").premiumSectionLabel()
            content
            if let error = helper.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
            }
        }
        // Same tokens as every other card in this VStack — a change to
        // Theme.Metrics.cornerRadius now reaches all four, not three.
        .popoverCard(
            fill: isManual ? AnyShapeStyle(Theme.warning.opacity(0.12)) : AnyShapeStyle(.quinary),
            border: isManual ? Theme.warning.opacity(0.5) : .clear
        )
    }

    @ViewBuilder
    private var content: some View {
        switch helper.registration {
        case .unknown, .notRegistered:
            onboarding
        case .requiresApproval:
            approvalPrompt
        case .enabled:
            enabledContent
        }
    }

    // MARK: - Onboarding & approval

    /// Both pre-enabled states hand off to the guided setup window rather than
    /// trying to run the flow inside a popover.
    ///
    /// The popover dismisses itself whenever the user clicks away — including
    /// when they go to System Settings to grant the permission — so the one
    /// moment they most need guidance was the one moment this card could not be
    /// on screen.
    private var onboarding: some View {
        setupPrompt(
            title: "Fan control is off",
            icon: "fan.slash",
            message: "Ice Cube can run your fans quieter or cooler. It needs your "
                + "permission once — takes about ten seconds.",
            button: "Set Up Fan Control…"
        )
    }

    private var approvalPrompt: some View {
        setupPrompt(
            title: "Almost there",
            icon: "checkmark.shield",
            message: "Just needs your approval in System Settings. Ice Cube will "
                + "walk you through it.",
            button: "Finish Setup…"
        )
    }

    private func setupPrompt(
        title: String, icon: String, message: String, button: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(button) {
                WindowOpener.openFromPopover(
                    WindowOpener.ID.setup, using: openWindow, dismissing: dismissPopover
                )
            }
            .controlSize(.small)
            .primaryGlassButton()
        }
    }

    // MARK: - Enabled: connection states & manual controls

    @ViewBuilder
    private var enabledContent: some View {
        switch helper.connection {
        case .disconnected:
            Label("Helper enabled — connecting…", systemImage: "bolt.horizontal")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .versionMismatch:
            // The version number was the whole message before. It told the user
            // nothing they could act on and read as a fault they had caused.
            setupPrompt(
                title: "Update needed",
                icon: "arrow.triangle.2.circlepath",
                message: "Ice Cube was updated. One more step finishes it — fan "
                    + "control is paused until then.",
                button: "Finish Update…"
            )
        case .connected:
            // A Mac with no controllable fans is a supported configuration, not
            // an error: the M2 Air is in the curated model set and is passively
            // cooled. Without this it got the full control card — four preset
            // buttons and a "Take Manual Control" button, every one of them a
            // no-op — which reads as an app that is broken rather than a Mac
            // that has nothing to control.
            if fans.isEmpty {
                Label(
                    "This Mac has no controllable fans. Temperature monitoring works normally.",
                    systemImage: "wind.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                controls
            }
        }
    }

    /// What the panel is reporting right now, derived once.
    ///
    /// The label, glyph and tint used to be three independent if-ladders over
    /// four booleans, each re-deriving the same precedence by hand and each
    /// re-reading `helper.status?`. HelperStatus is versioned and grows (v3
    /// added `guardianActive` itself), so a fifth state now becomes a compile
    /// error in exactly the places that must handle it.
    private enum ControlState {
        case manual, curve, guardianCooling, automatic

        var text: String {
            switch self {
            case .manual: "MANUAL fan control"
            case .curve: "Curve active"
            // Says who is driving. "Automatic" left people believing Ice Cube
            // was managing cooling when it had handed the fans to macOS.
            case .guardianCooling: "macOS · Ice Cube stepped in"
            // No longer something anyone can pick — since the macOS preset was
            // removed this only appears in passing (before the first config
            // lands at launch) or after a safety revert. "Not controlling"
            // rather than "macOS is controlling" because, per the field
            // finding, macOS frequently does not pick the fans back up.
            case .automatic: "Fan control is off"
            }
        }

        var icon: String {
            switch self {
            case .manual: "hand.raised.fill"
            case .curve: "chart.xyaxis.line"
            case .guardianCooling: "wind"
            case .automatic: "gearshape"
            }
        }

        var style: AnyShapeStyle {
            switch self {
            case .manual: AnyShapeStyle(Theme.warning)
            case .curve, .guardianCooling: AnyShapeStyle(Theme.accent)
            case .automatic: AnyShapeStyle(.secondary)
            }
        }
    }

    private var controlState: ControlState {
        guard let status = helper.status else { return .automatic }
        switch status.mode {
        case .manual: return .manual
        case .curve: return .curve
        // The daemon's guardian is driving the fans itself under Auto — the
        // Mac got hot and macOS wasn't cooling it.
        case .auto: return status.guardianActive ? .guardianCooling : .automatic
        }
    }

    private var isCurve: Bool {
        controlState == .curve
    }

    private var statusText: String {
        controlState.text
    }

    private var statusIcon: String {
        controlState.icon
    }

    private var statusColor: AnyShapeStyle {
        controlState.style
    }

    /// The preset quick-switch row (PLAN.md §1.2). Applying a curve preset
    /// needs the editor's persist setting, stored app-wide.
    @AppStorage("persistCurve") private var persistCurve = false

    /// The preset row — now a single spectrum, quietest to loudest.
    ///
    /// It used to be split by a divider, because "hand the fans to macOS" sat
    /// alongside the curves and read as one more point on that spectrum when it
    /// was really a different kind of choice entirely. With that entry gone the
    /// row means one thing throughout — how hard Ice Cube drives your fans —
    /// so the grouping cue has nothing left to group and the divider went too.
    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(PresetStore.builtins) { preset in
                presetButton(preset)
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private func presetButton(_ preset: Preset) -> some View {
        Button(preset.name) {
            Task { await helper.applyPreset(preset, persistCurve: persistCurve) }
        }
        .buttonStyle(.bordered)
        .tint(isActivePreset(preset) ? Theme.accent : nil)
        .help(preset.kind.explanation)
    }

    @Environment(\.openWindow) private var openWindow

    /// Which preset to light up.
    ///
    /// Prefers what the DAEMON says it is enforcing, falling back to the last
    /// config this app sent. It used to consult only the app's own memory, so
    /// anything the daemon was running that the app had not personally sent —
    /// a curve resumed at boot before the app even launched — left every
    /// button unlit while the fans audibly ran. The truth about what is being
    /// enforced lives in the daemon; the app's memory is a cache of it.
    private func isActivePreset(_ preset: Preset) -> Bool {
        guard let status = helper.status, status.mode == preset.config.mode else {
            return false
        }
        if status.mode == .curve, let active = status.activeCurve {
            return active == preset.config.sharedCurve
        }
        return PresetHighlight.matches(preset, applied: helper.lastAppliedConfig)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            presetRow
            // On its OWN line. This is the most important sentence in the card
            // — whether Ice Cube is driving your fans or not — and sharing a
            // row with two buttons truncated it to "macOS is controlli…",
            // which tells the user nothing at exactly the moment they need to
            // know. A full-width line also means the wording can be chosen for
            // clarity instead of for character count.
            Label(statusText, systemImage: statusIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Curves…") {
                    WindowOpener.openFromPopover(
                        WindowOpener.ID.curves, using: openWindow, dismissing: dismissPopover
                    )
                }
                .controlSize(.small)
                .help("Edit the temperature→fan curve")
                Spacer()
                // "Hand Back to macOS" used to live here, and it is gone for the
                // same reason its preset twin is: nobody installs a fan-control
                // app in order to stop controlling the fans, and on this
                // hardware the hand-back does not even work — macOS was
                // observed leaving them parked while the die climbed to 92 °C.
                // The honest version of that action removes the daemon, and it
                // lives in Settings -> "Turn Off Fan Control".
                //
                // Which frees this slot to offer manual control from a curve as
                // well as from a standing start, rather than only from the one
                // state the user could no longer reach on purpose.
                if !isManual {
                    Button("Take Manual Control") {
                        engageManual()
                    }
                    .controlSize(.small)
                    .help("Set each fan's speed by hand")
                }
            }
            if controlState == .guardianCooling {
                Text("Ice Cube is cooling the Mac — macOS left the fans idle while it ran hot. "
                    + "It hands back once things cool down.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isManual {
                ForEach(fans) { fan in
                    sliderRow(fan)
                }
                if helper.status?.lastWriteVerified == false {
                    Label(
                        "Last write not verified — the system may be resisting control.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                }
            }
        }
    }

    private func sliderRow(_ fan: Fan) -> some View {
        HStack(spacing: 8) {
            Text(fan.name)
                .font(.caption)
                .frame(width: 40, alignment: .leading)
            Slider(
                value: Binding(
                    get: { sliderTargets[fan.id] ?? fan.targetRPM },
                    set: { sliderTargets[fan.id] = $0 }
                ),
                in: fan.minRPM ... max(fan.maxRPM, fan.minRPM + 1),
                onEditingChanged: { editing in
                    if !editing {
                        commitTargets()
                    } // commit on release only
                }
            )
            .controlSize(.small)
            // On the SLIDER, not on the readout beside it. The label used to
            // live on the Text, which VoiceOver reads as a separate element —
            // so the only control in the app that sets fan speed by hand
            // announced itself as an anonymous "slider, 50%", and the number
            // arrived detached from the thing that changes it.
            .accessibilityLabel("\(fan.name) fan speed")
            .accessibilityValue(RPM.labeled(sliderTargets[fan.id] ?? fan.targetRPM))
            Text(RPM.text(sliderTargets[fan.id] ?? fan.targetRPM))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                // The slider now announces this value; reading it twice is noise.
                .accessibilityHidden(true)
        }
    }

    // MARK: - Actions

    /// Enters manual mode holding the fans where they are now (no jump in
    /// noise), ready for the user to slide.
    private func engageManual() {
        for fan in fans {
            // Via the sequencer's guarded clamp, NOT `clamped(to: Mn ... Mx)`:
            // Mn and Mx are read with independent `try?`s that each fall back
            // to 0 ("degrade per-key rather than losing the whole fan"), so an
            // inverted range is a modelled outcome — and building a
            // ClosedRange from one traps. This is the same helper the daemon
            // clamps writes with, and it returns maxRPM for a degenerate fan,
            // exactly as the old min(max(...)) did.
            sliderTargets[fan.id] = FanWriteSequencer.clamp(fan.actualRPM, to: fan)
        }
        commitTargets()
    }

    /// Sends a target for **every** fan, not just the sliders the user touched.
    ///
    /// `sliderTargets` is `@State`, and since the off-screen popover
    /// optimization the whole content subtree is torn down when the popover
    /// closes — so this map starts empty on every reopen. Sending it verbatim
    /// meant that after a reopen, moving one slider committed a single-entry
    /// map: `engageManual` skips fans missing from `targets`, so the other fan
    /// stayed physically forced but dropped out of the daemon's tracked config,
    /// where `verifyManualState` then reported it as held and wake re-assert
    /// skipped it. Filling from the live readings keeps the map complete.
    private func commitTargets() {
        guard !fans.isEmpty else { return }
        let targets = Dictionary(
            fans.map { fan in
                (fan.id, sliderTargets[fan.id] ?? FanWriteSequencer.clamp(fan.actualRPM, to: fan))
            },
            uniquingKeysWith: { first, _ in first }
        )
        Task { await helper.applyManual(targets: targets) }
    }
}
