// FanControlOnboarding.swift — what the Control card shows before fan control is set up.

import IceCubeKit
import SwiftUI

/// The pre-setup states of the Control card: never registered, and registered
/// but awaiting the user's approval in System Settings.
///
/// Split out of `FanControlSection` because it is a different audience — this
/// is the only thing a first-run user sees there, and it shares nothing with
/// the manual sliders below it but the card it sits in. Owns no state; the
/// manager comes in, and `dismissPopover` is injected because opening the setup
/// window from inside the popover has load-bearing ordering.
struct FanControlOnboarding: View {
    let helper: HelperManager
    let dismissPopover: () -> Void

    /// Which of the two pre-setup cards a registration state deserves.
    ///
    /// A named type with a pure resolver, rather than an `if` inside `body`,
    /// because the `if` inside `body` is exactly what was wrong: this view was
    /// hard-wired to `onboarding`, so someone who had already registered the
    /// daemon and was one switch away from done read "Fan control is off" with a
    /// "Set Up Fan Control…" button — the card for a user who had done nothing.
    /// `approvalPrompt` existed the whole time and nothing referenced it, which
    /// no test could catch because the decision lived in a `View`. `SetupModel`
    /// distinguishes these two correctly, so only this card was ever wrong.
    enum Prompt: Equatable {
        /// Nothing has been set up yet.
        case notSetUp
        /// Registered; one approval away in System Settings.
        case awaitingApproval

        static func forRegistration(_ registration: HelperManager.Registration) -> Prompt {
            registration == .requiresApproval ? .awaitingApproval : .notSetUp
        }
    }

    var body: some View {
        switch Prompt.forRegistration(helper.registration) {
        case .notSetUp: onboarding
        case .awaitingApproval: approvalPrompt
        }
    }

    /// Both pre-enabled states hand off to the guided setup window rather than
    /// trying to run the flow inside a popover.
    ///
    /// The popover dismisses itself whenever the user clicks away — including
    /// when they go to System Settings to grant the permission — so the one
    /// moment they most need guidance was the one moment this card could not be
    /// on screen.
    private var onboarding: some View {
        FanControlSetupPrompt(
            title: "Fan control is off",
            icon: "fan.slash",
            message: "Ice Cube can run your fans quieter or cooler. It needs your "
                + "permission once — takes about ten seconds.",
            button: "Set Up Fan Control…",
            dismissPopover: dismissPopover
        )
    }

    private var approvalPrompt: some View {
        FanControlSetupPrompt(
            title: "Almost there",
            icon: "checkmark.shield",
            message: "Just needs your approval in System Settings. Ice Cube will "
                + "walk you through it.",
            button: "Finish Setup…",
            dismissPopover: dismissPopover
        )
    }
}

/// The "you have one step left" card, shown for three different reasons: never
/// set up, awaiting approval in System Settings, and a helper left behind by an
/// app update.
///
/// Its own type rather than a method, because it is used from both
/// ``FanControlOnboarding`` and `FanControlSection`'s version-mismatch branch —
/// and because every one of those three states ends at the same button.
struct FanControlSetupPrompt: View {
    let title: String
    let icon: String
    let message: String
    let button: String
    let dismissPopover: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
}
