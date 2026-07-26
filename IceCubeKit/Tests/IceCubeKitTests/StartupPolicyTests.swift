// StartupPolicyTests.swift — what Ice Cube does to your fans on launch, and what it must never do.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("StartupPolicy")
struct StartupPolicyTests {
    private var stored: FanConfig {
        var config = FanConfig(mode: .curve, persistsWithoutApp: true)
        config.sharedCurve = .quiet
        return config
    }

    /// The whole point: a fresh user gets a curve, not macOS's let-it-cook-then
    /// -blast behaviour they installed this app to escape.
    @Test("Someone who has never chosen gets the default curve")
    func freshUserGetsDefault() {
        let decision = StartupPolicy.decide(
            daemonMode: .auto, preference: nil, storedCurve: nil, fallback: .balanced
        )
        #expect(decision == .apply(StartupPolicy.defaultConfig(.balanced)))
    }

    /// There used to be an `.automatic` preference here, honoured forever so
    /// that "chose to hand the fans to macOS" could not be mistaken for "never
    /// chose". Removing macOS mode from the UI removed the choice, so a stored
    /// `"automatic"` no longer decodes — and this pins the consequence, which
    /// is the migration: those users land on the fallback curve rather than on
    /// a mode nothing can express.
    @Test("A preference from the removed macOS mode no longer decodes, so it falls back")
    func retiredAutomaticPreferenceMigrates() {
        #expect(StartupPolicy.Preference(rawValue: "automatic") == nil)
        let decision = StartupPolicy.decide(
            daemonMode: .auto,
            preference: StartupPolicy.Preference(rawValue: "automatic"),
            storedCurve: nil, fallback: .balanced
        )
        #expect(decision == .apply(StartupPolicy.defaultConfig(.balanced)))
    }

    @Test("A saved curve is restored in preference to the default")
    func savedCurveWins() {
        let decision = StartupPolicy.decide(
            daemonMode: .auto, preference: .curve, storedCurve: stored, fallback: .balanced
        )
        #expect(decision == .apply(stored))
    }

    /// Losing the saved curve must not silently demote the user to Automatic —
    /// they chose to run a curve, so run one.
    @Test("A curve preference with an unreadable curve falls back rather than dropping to Automatic")
    func corruptCurveFallsBack() {
        let decision = StartupPolicy.decide(
            daemonMode: .auto, preference: .curve, storedCurve: nil, fallback: .balanced
        )
        #expect(decision == .apply(StartupPolicy.defaultConfig(.balanced)))
    }

    /// Boot persistence means the daemon can already be driving the fans before
    /// the app exists. Re-applying over it would fight it.
    @Test("Anything the daemon is already enforcing is left alone")
    func neverStompsAnActiveMode() {
        for mode in [FanConfig.Mode.curve, .manual] {
            for preference in [StartupPolicy.Preference.curve, nil] {
                #expect(
                    StartupPolicy.decide(
                        daemonMode: mode, preference: preference,
                        storedCurve: stored, fallback: .balanced
                    ) == .leaveAlone,
                    "mode \(mode) preference \(String(describing: preference))"
                )
            }
        }
    }

    /// SAFETY INVARIANT: manual mode is never the persisted default. The policy
    /// can only ever produce a curve, so there is no path by which a launch
    /// puts the fans under fixed-RPM control on its own.
    @Test("No decision can ever start the app in manual mode")
    func neverStartsManual() {
        for preference in [StartupPolicy.Preference.curve, nil] {
            for curve in [stored, FanConfig(mode: .manual, manualTargets: [0: 6000]), nil] {
                let decision = StartupPolicy.decide(
                    daemonMode: .auto, preference: preference,
                    storedCurve: curve, fallback: .balanced
                )
                if case let .apply(config) = decision {
                    #expect(config.mode == .curve, "produced \(config.mode) for \(String(describing: preference))")
                }
            }
        }
    }

    /// A default the user never asked for must not outlive the app that applied
    /// it — running fans app-less is something they opt into.
    @Test("The out-of-the-box default does not persist without the app")
    func defaultDoesNotPersistAppLess() {
        #expect(StartupPolicy.defaultConfig(.balanced).persistsWithoutApp == false)
        #expect(StartupPolicy.defaultConfig(.balanced).sharedCurve == .balanced)
    }
}
