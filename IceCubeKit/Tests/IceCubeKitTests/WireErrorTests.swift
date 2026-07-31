// WireErrorTests.swift — every daemon error must still be readable, and recognisable, after crossing XPC.

import Foundation
@testable import IceCubeKit
import Testing

/// The app renders whatever the daemon hands it, so an error that loses its
/// message on the wire is an error the user cannot act on. This suite is the
/// wire.
///
/// `NSKeyedArchiver(requiringSecureCoding: true)` stands in for XPC: it is the
/// same `NSSecureCoding` round trip an `(NSError?) -> Void` reply block
/// performs, which is what lets this be a `swift test` rather than a ritual
/// with a real daemon and a closed lid.
@Suite("WireError — daemon errors survive the trip to the app")
struct WireErrorTests {
    /// One value per case. `IceCubeError.wireName`'s exhaustive switch makes a
    /// ninth case a compile error; `everyCaseHasItsOwnName` catches a
    /// copy-pasted string.
    private static let everyCase: [IceCubeError] = [
        .smcConnectionFailed(kernReturn: -536_870_212),
        .smcCallFailed(key: "F0Md", kernReturn: -536_870_206),
        .smcFirmwareRejected(key: "F0Md", result: .badCommand),
        .smcKeyNotFound(key: "Ftst"),
        .smcNotPrivileged(key: "F0Tg"),
        .smcDecodingFailed(key: "TC0P", type: "flt ", bytes: [0, 1, 2, 3]),
        .smcEncodingFailed(type: "ui8 ", value: 99999),
        .systemAsleep,
    ]

    /// Encode and decode exactly as the XPC reply block does.
    private func acrossTheWire(_ error: NSError) throws -> NSError {
        let data = try NSKeyedArchiver.archivedData(withRootObject: error, requiringSecureCoding: true)
        return try #require(
            try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data)
        )
    }

    // MARK: The message

    @Test("Every error the daemon can throw is still readable on the app's side")
    func everyCaseKeepsItsMessage() throws {
        for error in Self.everyCase {
            let decoded = try acrossTheWire(WireError.wire(error))
            #expect(decoded.localizedDescription == error.errorDescription)
        }
    }

    /// The regression witness, and the reason `WireError` is not "just use
    /// `as NSError`". Swift supplies `localizedDescription` through a lazy
    /// userInfo value provider that reads the Swift error still boxed inside
    /// the bridge; the box does not survive encoding, so the far side falls
    /// back to naming the type. This is the exact string from the owner's
    /// screenshot.
    @Test("The bare bridge is what loses the message")
    func bareBridgeLosesTheMessage() throws {
        let bare = try acrossTheWire(IceCubeError.systemAsleep as NSError)
        #expect(bare.localizedDescription != IceCubeError.systemAsleep.errorDescription)
        #expect(bare.localizedDescription.contains("IceCubeKit.IceCubeError"))
    }

    /// The bar the whole app is held to: implementation jargon never reaches
    /// the user.
    @Test("No message the user sees names a module or a type")
    func messagesCarryNoJargon() throws {
        for error in Self.everyCase {
            let decoded = try acrossTheWire(WireError.wire(error))
            #expect(!decoded.localizedDescription.contains("IceCubeKit"))
            #expect(!decoded.localizedDescription.contains("IceCubeError"))
        }
    }

    // MARK: Recognising the sleep refusal

    @Test("The case name survives the wire")
    func caseNameSurvives() throws {
        let decoded = try acrossTheWire(WireError.wire(IceCubeError.systemAsleep))
        #expect(WireError.caseName(of: decoded) == "systemAsleep")
        #expect(WireError.isDeferredUntilWake(decoded))
    }

    /// A false positive here would swallow a real failure silently, so this
    /// sweeps every other case rather than spot-checking one.
    @Test("Nothing else is mistaken for the sleep refusal")
    func onlySystemAsleepDefers() throws {
        for error in Self.everyCase where error != .systemAsleep {
            let decoded = try acrossTheWire(WireError.wire(error))
            #expect(!WireError.isDeferredUntilWake(decoded))
        }
    }

    /// Covers same-process callers and the tests themselves, where the error is
    /// still a live enum and never sees a wire.
    @Test("The refusal is recognised in-process too")
    func recognisedInProcess() {
        #expect(WireError.isDeferredUntilWake(IceCubeError.systemAsleep))
        #expect(!WireError.isDeferredUntilWake(IceCubeError.smcKeyNotFound(key: "F0Md")))
    }

    // MARK: What must not change

    /// Domain and code are preserved so anything that matches on them keeps
    /// working — the fix adds information, it does not re-label the error.
    @Test("Domain and code are unchanged, so nothing matching on them breaks")
    func domainAndCodeAreUntouched() {
        for error in Self.everyCase {
            let bare = error as NSError
            let wired = WireError.wire(error)
            #expect(wired.domain == bare.domain)
            #expect(wired.code == bare.code)
        }
    }

    /// `HelperService.apply` also catches `JSONDecoder`'s `DecodingError`,
    /// which bridges with a real message and real debug keys. Merging rather
    /// than replacing `userInfo` is what keeps them.
    @Test("A foreign error keeps its own message and its debug keys")
    func foreignErrorsAreNotFlattened() throws {
        struct Config: Decodable { let mode: String }
        var thrown: Error?
        do {
            _ = try JSONDecoder().decode(Config.self, from: Data(#"{"wrong": 1}"#.utf8))
        } catch {
            thrown = error
        }
        let error = try #require(thrown)
        let decoded = try acrossTheWire(WireError.wire(error))
        #expect(decoded.domain == NSCocoaErrorDomain)
        #expect(decoded.userInfo["NSDebugDescription"] != nil)
        #expect(decoded.localizedDescription == (error as NSError).localizedDescription)
        #expect(WireError.caseName(of: decoded) == nil, "not ours, so no case name")
    }

    /// A duplicated name would make two errors indistinguishable to the app,
    /// which is how a real failure ends up silently deferred forever.
    @Test("Every case has its own name")
    func everyCaseHasItsOwnName() {
        #expect(Set(Self.everyCase.map(\.wireName)).count == Self.everyCase.count)
        #expect(Self.everyCase.count == 8, "a ninth case belongs in this list too")
    }
}
