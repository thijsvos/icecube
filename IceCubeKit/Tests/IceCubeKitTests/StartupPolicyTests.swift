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

    /// The trap this design exists to avoid. Choosing Automatic used to just
    /// delete the stored curve, making "chose Automatic" indistinguishable from
    /// "never chose" — so a default-on-absence would re-apply a curve every
    /// launch, silently overriding them.
    @Test("An explicit Automatic choice is honoured, not treated as 'no preference'")
    func explicitAutomaticIsRespected() {
        let decision = StartupPolicy.decide(
            daemonMode: .auto, preference: .automatic, storedCurve: nil, fallback: .balanced
        )
        #expect(decision == .leaveAlone)
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
            for preference in [StartupPolicy.Preference.curve, .automatic, nil] {
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
        for preference in [StartupPolicy.Preference.curve, .automatic, nil] {
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
