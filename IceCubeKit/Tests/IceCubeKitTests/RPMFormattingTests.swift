// RPMFormattingTests.swift — fan readings must read the same in every locale.

import Foundation
@testable import IceCubeKit
import Testing

/// The bug these pin was found in the project's own README screenshots, taken
/// on a Dutch-locale Mac: the popover read "6.802 RPM" and the sensors browser
/// "(2.317–6.800)". Correct `nl_NL`, and unreadable to everyone else — a fan
/// controller that appears to report 6.8 RPM is not making a cosmetic mistake.
@Suite("RPM formatting — no locale may garble a fan reading")
struct RPMFormattingTests {
    @Test("Four- and five-digit speeds carry no grouping separator")
    func noGroupingSeparator() {
        #expect(RPM.text(6802) == "6802")
        #expect(RPM.text(2317) == "2317")
        #expect(RPM.text(12345) == "12345")
        // The exact characters a grouping locale would have inserted.
        for value in [1000.0, 6802, 12345] {
            let text = RPM.text(value)
            #expect(text.contains(".") == false, "grouped as \(text)")
            #expect(text.contains(",") == false, "grouped as \(text)")
            #expect(text.contains("\u{202F}") == false, "narrow-space grouped as \(text)")
            #expect(text.contains("\u{00A0}") == false, "nbsp grouped as \(text)")
        }
    }

    @Test("Readings round rather than truncate")
    func rounds() {
        #expect(RPM.text(2316.6) == "2317")
        #expect(RPM.text(2316.4) == "2316")
        #expect(RPM.text(0) == "0")
    }

    @Test("The labeled form is the number plus a plain unit")
    func labeled() {
        #expect(RPM.labeled(6802) == "6802 RPM")
        #expect(RPM.labeled(2317.5) == "2318 RPM")
    }

    /// Guards the actual mechanism: `Text("\(someInt)")` picks the
    /// `LocalizedStringKey` overload and groups. Anything that formats a fan
    /// reading has to go through a String first, which is what `RPM` is for.
    @Test("Formatting is independent of the process locale")
    func localeIndependent() {
        // `String(Int)` is locale-invariant by construction; assert the property
        // directly so a future switch to a NumberFormatter cannot break it.
        let text = RPM.text(6802)
        #expect(text == String(6802))
        // No closure and no key path here on purpose: swiftformat rewrites
        // `allSatisfy { $0.isASCII }` into `allSatisfy(\.isASCII)`, and the
        // key-path form reads as throwing inside `#expect`, so the suite stops
        // compiling the next time anyone runs the formatter.
        #expect(text.data(using: .ascii) != nil, "non-ASCII digits or separator in \(text)")
    }
}
