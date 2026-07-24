// RegistrationPreflightTests.swift — the rules that stop a re-register destroying a working helper install.

@testable import IceCubeKit
import Testing

/// Re-register is unregister-then-register. These pin the cases where the
/// register half was never going to succeed, so the unregister half must not
/// run at all.
@Suite("RegistrationPreflight")
struct RegistrationPreflightTests {
    private let installed = "/Applications/Ice Cube.app"

    @Test("A signed app in /Applications is cleared to register")
    func happyPath() {
        #expect(RegistrationPreflight.blocker(teamID: "74Q48XUN7W", bundlePath: installed) == nil)
    }

    @Test("An unsigned build is blocked — SMAppService refuses the plist outright")
    func unsignedIsBlocked() {
        let blocker = RegistrationPreflight.blocker(teamID: nil, bundlePath: installed)
        #expect(blocker != nil)
        #expect(blocker?.contains("code-signed") == true)
        // An empty Team ID is the same situation as none.
        #expect(RegistrationPreflight.blocker(teamID: "", bundlePath: installed) != nil)
    }

    /// The exact configuration that broke a working install: a signed-but-ad-hoc
    /// build launched straight out of the build directory. Registration failed
    /// with "Codesigning failure loading plist … -67056" AFTER the unregister
    /// had already happened.
    @Test("A build running from the build directory is blocked before anything is torn down")
    func buildDirectoryIsBlocked() {
        let path = "/Users/someone/Projects/mac_fan_tool/build/Build/Products/Debug/Ice Cube.app"
        let blocker = RegistrationPreflight.blocker(teamID: "74Q48XUN7W", bundlePath: path)
        #expect(blocker != nil)
        #expect(blocker?.contains("/Applications") == true)
        // The message must name where it actually is, so the fix is obvious.
        #expect(blocker?.contains(path) == true)
    }

    @Test("DerivedData is blocked too, signed or not")
    func derivedDataIsBlocked() {
        let path = "/Users/someone/Library/Developer/Xcode/DerivedData/IceCube-abc/Build/Products/Debug/Ice Cube.app"
        #expect(RegistrationPreflight.blocker(teamID: "74Q48XUN7W", bundlePath: path) != nil)
    }

    @Test("Unsigned is reported ahead of location — it's the unrecoverable one")
    func unsignedTakesPrecedence() {
        let blocker = RegistrationPreflight.blocker(
            teamID: nil, bundlePath: "/Users/someone/build/Ice Cube.app"
        )
        #expect(blocker?.contains("code-signed") == true)
    }

    @Test("Apps filed into an /Applications subfolder still count as installed")
    func applicationsSubfolder() {
        #expect(RegistrationPreflight.isInApplications("/Applications/Utilities/Ice Cube.app"))
        #expect(RegistrationPreflight.isInApplications("/Applications/Ice Cube.app"))
        #expect(RegistrationPreflight.isInApplications("/Applications/Ice Cube.app/"))
        // ~/Applications is a real install location too.
        #expect(RegistrationPreflight.isInApplications("/Users/thijsvos/Applications/Ice Cube.app"))
    }

    @Test("Paths that merely mention Applications are not install locations")
    func lookalikePathsRejected() {
        #expect(RegistrationPreflight.isInApplications("/tmp/Applications/Ice Cube.app") == false)
        #expect(RegistrationPreflight.isInApplications("/Volumes/Data/Applications/Ice Cube.app") == false)
        #expect(RegistrationPreflight.isInApplications("/ApplicationsFake/Ice Cube.app") == false)
        #expect(RegistrationPreflight.isInApplications("/Users/x/Projects/Applications.app") == false)
    }
}
