// ControlStatusTests.swift — the status line must never claim control the daemon is not exercising.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("ControlStatus — who is driving the fans")
struct ControlStatusTests {
    // MARK: Precedence

    @Test("Each daemon mode maps to the state describing it")
    func modesMap() {
        #expect(ControlStatus.of(HelperStatus(mode: .manual)) == .manual)
        #expect(ControlStatus.of(HelperStatus(mode: .curve)) == .curve)
        #expect(ControlStatus.of(HelperStatus(mode: .auto)) == .automatic)
    }

    /// The distinction the removed "macOS" preset died for. In auto mode the
    /// daemon's guardian may be driving the fans itself because the Mac got hot
    /// and macOS was not cooling it — saying "Automatic" there tells the user
    /// nobody is looking after them, which is the opposite of the truth.
    @Test("Auto with the guardian active says Ice Cube stepped in")
    func guardianIsNotPlainAutomatic() {
        let cooling = HelperStatus(mode: .auto, guardianActive: true)
        #expect(ControlStatus.of(cooling) == .guardianCooling)
        #expect(ControlStatus.of(cooling).text.contains("Ice Cube"))
        #expect(ControlStatus.of(cooling) != .automatic)
    }

    /// …and the guardian flag must NOT override a mode the user actually chose.
    /// The daemon can report it set while a curve or manual config is live; the
    /// mode is what is being enforced.
    @Test("The guardian flag never overrides an explicit mode")
    func guardianDoesNotOverrideChosenModes() {
        #expect(ControlStatus.of(HelperStatus(mode: .curve, guardianActive: true)) == .curve)
        #expect(ControlStatus.of(HelperStatus(mode: .manual, guardianActive: true)) == .manual)
    }

    /// No connection is not "everything is fine". Claiming control the app
    /// cannot confirm is exactly the lie this type exists to prevent.
    @Test("No daemon status reads as off, never as controlling")
    func noStatusIsOff() {
        let status = ControlStatus.of(nil)
        #expect(status == .automatic)
        #expect(status.isCurve == false)
        #expect(status.emphasis == .quiet)
    }

    // MARK: The words themselves

    /// Every state must say something, and no two may say the same thing — a
    /// duplicate would make two genuinely different situations indistinguishable
    /// on screen, which is how "Automatic" came to cover the guardian case.
    @Test("Every state has distinct, non-empty wording and its own icon")
    func wordingIsDistinct() {
        let texts = ControlStatus.allCases.map(\.text)
        let icons = ControlStatus.allCases.map(\.icon)
        #expect(texts.allSatisfy { !$0.isEmpty })
        #expect(Set(texts).count == ControlStatus.allCases.count, "two states say the same thing")
        #expect(Set(icons).count == ControlStatus.allCases.count, "two states share an icon")
    }

    /// The vocabulary rule the Settings window states outright: these strings
    /// are read by someone who does not know what a helper or a daemon is.
    /// `SetupFlowTests` enforces the same list on the setup flow.
    @Test("No implementation jargon reaches the user")
    func noJargon() {
        for status in ControlStatus.allCases {
            let text = status.text.lowercased()
            for word in ["helper", "daemon", "xpc", "smc", "launchd", "privileged"] {
                #expect(!text.contains(word), "\(status) says \"\(status.text)\"")
            }
        }
    }

    /// Manual is the one state that warns. It is watchdogged, it does not track
    /// load, and unlike a curve it will happily hold a low RPM into a thermal
    /// event — so it must not look like the routine case.
    @Test("Only manual mode is emphasised as a warning")
    func onlyManualWarns() {
        for status in ControlStatus.allCases {
            #expect((status.emphasis == .warning) == (status == .manual), "\(status)")
        }
    }

    @Test("isCurve is true for exactly one state")
    func isCurveIsExclusive() {
        #expect(ControlStatus.allCases.filter(\.isCurve) == [.curve])
    }
}
