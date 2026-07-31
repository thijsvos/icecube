// WireError.swift — the one place an error is made readable and recognisable before it crosses XPC.

import Foundation

/// The app↔daemon error boundary: everything the daemon throws goes over the
/// wire through ``wire(_:)``, and everything the app classifies comes back out
/// through ``isDeferredUntilWake(_:)``.
///
/// **Why this type exists.** `reply(error as NSError)` looks lossless and is
/// not. Swift supplies a `LocalizedError`'s `localizedDescription` through a
/// global userInfo *value provider*, which recovers the text from the Swift
/// error still boxed inside the bridged `NSError`. XPC encodes only domain,
/// code and the userInfo *dictionary* — measured `[:]` for every
/// ``IceCubeError`` — so the box does not survive, the provider returns nil on
/// the far side even though it is still registered there, and Foundation falls
/// back to "The operation couldn't be completed. (IceCubeKit.IceCubeError error
/// 7.)" That sentence is what the owner found in the popover after a lid close,
/// and it was never specific to that error: all eight cases degraded
/// identically, so every daemon error the app has ever shown has been this
/// string with a different number in it.
///
/// Materialising the text into the dictionary before it is encoded is the whole
/// fix. `WireErrorTests` pins it, including a witness that the bare
/// `as NSError` bridge still loses the message — so a later "simplification"
/// back to it fails a test instead of shipping.
public enum WireError {
    /// userInfo key carrying ``IceCubeError/wireName``.
    ///
    /// A name rather than the `NSError` code, because the code is the enum's
    /// declaration-order tag: add a case and every matcher below it starts
    /// quietly agreeing with the wrong error. An unrecognised name is treated
    /// as an ordinary failure and shown, which is the direction to fail in.
    public static let caseKey = "io.github.thijsvos.icecube.errorCase"

    /// The form an error must be in before it is handed to an XPC reply block.
    ///
    /// Merges rather than replaces `userInfo`: `HelperService.apply` also
    /// catches `JSONDecoder`'s `DecodingError`, which bridges to
    /// `NSCocoaErrorDomain` with real debug keys (`NSCodingPath`,
    /// `NSDebugDescription`) and a usable message of its own. Replacing the
    /// dictionary would discard those for no gain. Domain and code are
    /// preserved either way, so nothing that matches on them can break.
    public static func wire(_ error: Error) -> NSError {
        let ns = error as NSError
        var info = ns.userInfo
        if info[NSLocalizedDescriptionKey] == nil {
            // Read HERE, on the sending side. `errorDescription` is recoverable
            // only while the Swift error is still boxed inside this NSError;
            // asking for it after the wire yields nil, measured.
            info[NSLocalizedDescriptionKey] =
                (error as? LocalizedError)?.errorDescription ?? ns.localizedDescription
        }
        if let known = error as? IceCubeError {
            info[caseKey] = known.wireName
        }
        return NSError(domain: ns.domain, code: ns.code, userInfo: info)
    }

    /// The case name an error was wired with, or nil for anything else.
    public static func caseName(of error: Error) -> String? {
        (error as NSError).userInfo[caseKey] as? String
    }

    /// Whether this is the daemon declining a write because the Mac is parked
    /// for sleep — which is not a failure and must not be shown as one.
    ///
    /// Matches the live enum first, so the rule holds in-process (unit tests,
    /// and any same-process caller) as well as by name after the wire.
    public static func isDeferredUntilWake(_ error: Error) -> Bool {
        if let known = error as? IceCubeError {
            return known == .systemAsleep
        }
        return caseName(of: error) == IceCubeError.systemAsleep.wireName
    }
}
