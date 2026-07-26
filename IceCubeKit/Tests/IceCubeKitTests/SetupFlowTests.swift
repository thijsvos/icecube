// SetupFlowTests.swift — the first-run setup rules: where the app may live, and what the user is told.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("AppRelocation")
struct AppRelocationTests {
    @Test("An app already in /Applications is left alone")
    func installedIsFine() {
        #expect(AppRelocation.verdict(bundlePath: "/Applications/Ice Cube.app") == .fine)
        #expect(AppRelocation.verdict(bundlePath: "/Applications/Utilities/Ice Cube.app") == .fine)
        #expect(AppRelocation.verdict(bundlePath: "/Users/me/Applications/Ice Cube.app") == .fine)
    }

    /// The reason this whole flow exists: downloading the release and
    /// double-clicking it in ~/Downloads is what a normal person does.
    @Test("Running from Downloads offers a move instead of a dead end")
    func downloadsOffersMove() {
        let verdict = AppRelocation.verdict(bundlePath: "/Users/me/Downloads/Ice Cube.app")
        #expect(verdict == .offerMove(destination: "/Applications"))
    }

    /// A quarantined app launched from a download runs from a randomized
    /// read-only path. It cannot move itself, but the user still must act, so
    /// this is an offer rather than silence.
    @Test("A Gatekeeper-translocated app still prompts")
    func translocatedPrompts() {
        let path = "/private/var/folders/xy/T/AppTranslocation/ABC/d/Ice Cube.app"
        #expect(AppRelocation.verdict(bundlePath: path) == .offerMove(destination: "/Applications"))
        #expect(
            AppRelocation.verdict(bundlePath: "/Users/me/Downloads/Ice Cube.app", isTranslocated: true)
                == .offerMove(destination: "/Applications")
        )
    }

    /// Never nag the developer: install.sh is the supported path, and
    /// relocating a build product would break the next build.
    @Test("Xcode build products are never relocated")
    func developerBuildsAreLeftAlone() {
        for path in [
            "/Users/me/Library/Developer/Xcode/DerivedData/IceCube-abc/Build/Products/Debug/Ice Cube.app",
            "/Users/me/proj/build/Build/Products/Debug/Ice Cube.app",
            "/Users/me/proj/.build/debug/Ice Cube.app",
        ] {
            #expect(AppRelocation.verdict(bundlePath: path) == .developerBuild, "\(path)")
        }
    }

    @Test("Destination keeps the bundle's own name")
    func destinationName() {
        #expect(AppRelocation.destination(for: "/Users/me/Downloads/Ice Cube.app")
            == "/Applications/Ice Cube.app")
    }
}

@Suite("SetupGuidance")
struct SetupGuidanceTests {
    /// The entire point of this type: a person who wants a quieter MacBook
    /// should never read implementation vocabulary.
    @Test("No step's wording contains developer jargon")
    func noJargon() {
        let steps: [SetupGuidance.Step] = [
            .ready, .moveToApplications, .needsPermission, .awaitingApproval,
            .connecting, .connectionStuck, .needsUpdate,
            .blocked(reason: "Something specific went wrong."),
        ]
        let banned = [
            "daemon",
            "xpc",
            "launchd",
            "smappservice",
            "register",
            "bundle",
            "plist",
            "codesign",
            "helper",
        ]
        for step in steps {
            let text = (SetupGuidance.title(for: step) + " "
                + SetupGuidance.detail(for: step) + " "
                + (SetupGuidance.actionTitle(for: step) ?? "")).lowercased()
            for word in banned {
                #expect(!text.contains(word), "step \(step) leaks the word '\(word)': \(text)")
            }
        }
    }

    @Test("Every step a user can be stuck on offers an action")
    func actionableSteps() {
        #expect(SetupGuidance.actionTitle(for: .moveToApplications) != nil)
        #expect(SetupGuidance.actionTitle(for: .needsPermission) != nil)
        #expect(SetupGuidance.actionTitle(for: .awaitingApproval) != nil)
        #expect(SetupGuidance.actionTitle(for: .needsUpdate) != nil)
        // The dead end this step exists to prevent: registered but unreachable
        // used to render as an endless spinner with nothing to press.
        #expect(SetupGuidance.actionTitle(for: .connectionStuck) != nil)
        #expect(SetupGuidance.actionTitle(for: .blocked(reason: "x")) != nil)
        // These two are the app working; there is nothing to press.
        #expect(SetupGuidance.actionTitle(for: .ready) == nil)
        #expect(SetupGuidance.actionTitle(for: .connecting) == nil)
    }

    /// The directions are shown only to someone who is stuck, so they must
    /// actually be directions — and must obey the same no-jargon rule as
    /// everything else the user reads.
    @Test("The stuck-on-approval directions name the real place to click")
    func approvalDirectionsAreSpecific() {
        let text = SetupGuidance.approvalDirections
        #expect(text.contains("Login Items"))
        #expect(text.contains("Allow in the Background"))
        for word in ["daemon", "XPC", "launchd", "register", "plist"] {
            #expect(!text.lowercased().contains(word.lowercased()), "leaks '\(word)'")
        }
        // Long enough to be reading time, short enough not to be abandonment.
        #expect(SetupGuidance.approvalHelpDelay >= 10)
        #expect(SetupGuidance.approvalHelpDelay <= 30)
    }

    /// Long enough that ordinary startup never trips it, short enough that a
    /// person does not give up first.
    @Test("The stuck-connection timeout is neither trigger-happy nor endless")
    func stuckDelayIsSane() {
        #expect(SetupGuidance.connectionStuckDelay >= 10)
        #expect(SetupGuidance.connectionStuckDelay <= 60)
        #expect(SetupGuidance.connectionStuckDelay > SetupGuidance.approvalHelpDelay - 10)
    }

    @Test("The unsigned-build failure becomes advice, not an error code")
    func humanizesCodesigning() {
        let technical = "Registration failed (-67056): Codesigning failure loading plist"
        let human = SetupGuidance.humanize(technical)
        #expect(!human.contains("-67056"))
        #expect(human.lowercased().contains("signed"))
    }

    @Test("The wrong-location failure becomes an instruction")
    func humanizesLocation() {
        let technical = "Ice Cube has to run from /Applications to register its helper — "
            + "it’s running from /Users/me/Downloads/Ice Cube.app"
        let human = SetupGuidance.humanize(technical)
        #expect(human.lowercased().contains("applications folder"))
        #expect(!human.lowercased().contains("register"))
    }

    /// A message we did not anticipate is more useful verbatim than replaced
    /// with a vague catch-all.
    @Test("Unrecognized failures pass through rather than being flattened")
    func passesThroughUnknown() {
        let odd = "The fan controller reported error 42 during calibration."
        #expect(SetupGuidance.humanize(odd) == odd)
    }
}

@Suite("Preset wording")
struct PresetWordingTests {
    /// The option this used to guard is gone (2026-07-26). Renaming "Auto" to
    /// "macOS" and warning about it in the tooltip treated the symptom; the
    /// cause was that "stop controlling the fans" was offered as a preset
    /// alongside the curves at all. This now pins its absence, so it cannot
    /// quietly come back as one.
    @Test("No built-in preset hands the fans back — every one means Ice Cube drives")
    func noPresetHandsTheFansBack() {
        for kind in [Preset.Kind.quiet, .balanced, .cold, .max, .custom] {
            #expect(Preset.Kind(rawValue: "auto") == nil)
            #expect(kind.explanation.lowercased().contains("hands them back") == false)
        }
    }

    @Test("Every preset explains itself without jargon")
    func everyPresetIsExplained() {
        for kind in [Preset.Kind.quiet, .balanced, .cold, .max, .custom] {
            let text = kind.explanation
            #expect(text.count > 20, "\(kind) needs a real explanation")
            for word in ["daemon", "XPC", "SMC", "RPM clamp", "launchd"] {
                #expect(!text.lowercased().contains(word.lowercased()), "\(kind) leaks '\(word)'")
            }
        }
    }
}
