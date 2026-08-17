// InsideSymbolTests.swift — proves every icon the schematic asks for actually exists on this macOS.

import AppKit
import Foundation
import IceCubeKit
import Testing

/// The one failure mode a string-typed symbol name has.
///
/// `InsideLayout` names its icons as `String`s so the decision can live in
/// `IceCubeKit` beside the other decisions rather than in a view — the kit has
/// no business importing SwiftUI. The cost of that is real and this suite is
/// what pays it: a symbol name that is misspelled, or that exists in a later SF
/// Symbols release than the macOS 14 deployment target, resolves to **nothing**
/// and draws **nothing**. No crash, no warning, no log line — just a label with
/// a gap where the icon was, on someone else's Mac.
///
/// So the names are checked against AppKit, in the app bundle, where AppKit is.
@MainActor
@Suite("Inside — every icon it asks for resolves")
struct InsideSymbolTests {
    /// A sensor set covering every class and every component prefix the map
    /// knows about, using the keys a Mac14,9 actually reports.
    private static let everySensor = [
        SensorReading(key: "Tp01", label: "CPU P-cores", celsius: 72),
        SensorReading(key: "Tg0f", label: "GPU", celsius: 61),
        SensorReading(key: "Tf0A", label: "Other silicon", celsius: 58),
        SensorReading(key: "TB1T", label: "Battery 1", celsius: 34),
        SensorReading(key: "TB2T", label: "Battery 2", celsius: 35),
        SensorReading(key: "TH0x", label: "SSD", celsius: 44),
        SensorReading(key: "TW0P", label: "Wireless", celsius: 40),
        SensorReading(key: "TaLP", label: "Airflow Left", celsius: 39),
        SensorReading(key: "TaRF", label: "Airflow Right", celsius: 41),
    ]

    @Test("Every block's symbol exists in this system's SF Symbols")
    func everySymbolResolves() {
        let blocks = InsideLayout.blocks(for: Self.everySensor)
        #expect(blocks.count == 9, "the fixture must exercise every branch, got \(blocks.count)")
        for block in blocks {
            #expect(
                NSImage(systemSymbolName: block.symbolName, accessibilityDescription: nil) != nil,
                "\(block.label) asked for \"\(block.symbolName)\", which does not resolve — it would draw nothing"
            )
        }
    }

    @Test("The fallback symbol resolves too, since it is what an unknown sensor gets")
    func fallbackResolves() {
        #expect(NSImage(systemSymbolName: InsideLayout.fallbackSymbol, accessibilityDescription: nil) != nil)
    }

    /// Two batteries, an SSD and a wireless card are four blocks of almost the
    /// same size showing almost the same number. Distinct icons are the only
    /// thing telling them apart at a glance, so "distinct" is the property.
    @Test("The board components do not share an icon with each other")
    func componentIconsAreDistinct() {
        let components = InsideLayout.blocks(for: Self.everySensor).filter { $0.role == .component }
        #expect(components.count == 4, "two batteries, SSD, wireless")
        let symbols = Set(components.map(\.symbolName))
        #expect(
            symbols.count == 3,
            "the two batteries share one icon by design; SSD and wireless must each have their own — got \(symbols)"
        )
        #expect(!symbols.contains(InsideLayout.fallbackSymbol), "none of them should be falling back")
    }
}
