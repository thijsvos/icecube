// CurveDerivationCopyTests.swift — the panel hands over a curve, so its sentences carry weight.

import Foundation
@testable import IceCubeKit
import Testing

@Suite("CurveDerivationCopy — what the editor says about a curve it drew")
struct CurveDerivationCopyTests {
    private static func derivation(
        target: Double = 85,
        holds: Double = 85,
        shortfall: CurveDerivation.Shortfall? = nil
    ) -> CurveDerivation.Derivation {
        CurveDerivation.Derivation(
            curve: .balanced,
            targetCelsius: target,
            holdsAtCelsius: holds,
            wattsRange: 19.6 ... 52.4,
            bandsUsed: 4,
            records: 1340,
            shortfall: shortfall
        )
    }

    // MARK: - A curve it can stand behind

    @Test("A met target says what it holds and what the claim rests on")
    func aMetTargetShowsItsEvidence() {
        let summary = CurveDerivationCopy.summary(
            .derived(Self.derivation()), style: .celsius
        )
        #expect(summary.isCaution == false)
        #expect(summary.headline.contains("85"))
        #expect(summary.detail.contains("1340 readings"))
        #expect(summary.detail.contains("4 fan speeds"))
        // Whole watts: PSTR's own burst noise is ±15 W.
        #expect(summary.detail.contains("20–52 W"))
    }

    /// The finding the feature exists for. It must read as a fact about the
    /// hardware, not as the app failing to do its job — so the headline leads
    /// with what the Mac *does* hold.
    @Test("A target the machine cannot reach is named as the machine's limit")
    func anUnreachableTargetIsAFindingNotAFailure() {
        let summary = CurveDerivationCopy.summary(
            .derived(Self.derivation(
                target: 85,
                holds: 87.1,
                shortfall: CurveDerivation.Shortfall(
                    watts: 52.4, settlesAtCelsius: 87.1, fanFraction: 0.95
                )
            )),
            style: .celsius
        )
        #expect(summary.isCaution)
        #expect(summary.headline.hasPrefix("Holds 87"))
        #expect(summary.detail.contains("52 W"))
        #expect(summary.detail.contains("Nothing on this Mac holds"))
    }

    // MARK: - No curve, and why

    @Test("A fresh install is told what is missing and roughly how long it takes")
    func nothingMeasuredYetIsNotAnError() {
        let summary = CurveDerivationCopy.summary(
            .unavailable(.tooFewBands(measured: 0, need: 2)), style: .celsius
        )
        // Waiting for evidence is the ordinary state of a new install. Painting
        // it as a caution would teach the eye that yellow means nothing.
        #expect(summary.isCaution == false)
        #expect(summary.detail.contains("2 different"))
        #expect(summary.detail.contains("week"))
    }

    @Test("One measured fan speed is refused in its own words, not the empty ones")
    func oneBandGetsItsOwnSentence() {
        let one = CurveDerivationCopy.summary(
            .unavailable(.tooFewBands(measured: 1, need: 2)), style: .celsius
        )
        let none = CurveDerivationCopy.summary(
            .unavailable(.tooFewBands(measured: 0, need: 2)), style: .celsius
        )
        #expect(one.headline != none.headline)
        #expect(one.detail.contains("1 fan speed"))
    }

    @Test("Readings stacked at one load are refused as a range problem")
    func noLoadRangeSaysSo() {
        let summary = CurveDerivationCopy.summary(.unavailable(.noLoadCovered), style: .celsius)
        #expect(summary.isCaution == false)
        #expect(summary.detail.contains("one load"))
    }

    // MARK: - Both units

    /// Every temperature in this file goes through `TemperatureStyle`. A bare
    /// °C would read correctly to the developer and wrongly to everyone whose
    /// Mac is set to Fahrenheit, and it would never fail a test written in °C.
    @Test("Every temperature is rendered in the reader's own unit")
    func fahrenheitGetsTheSameSentence() {
        let cases: [CurveDerivation.Verdict] = [
            .derived(Self.derivation()),
            .derived(Self.derivation(
                target: 85, holds: 87.1,
                shortfall: CurveDerivation.Shortfall(
                    watts: 52.4, settlesAtCelsius: 87.1, fanFraction: 0.95
                )
            )),
        ]
        for verdict in cases {
            let fahrenheit = CurveDerivationCopy.summary(verdict, style: .fahrenheit)
            let celsius = CurveDerivationCopy.summary(verdict, style: .celsius)

            #expect(!fahrenheit.headline.contains("°C"))
            #expect(!fahrenheit.detail.contains("°C"))
            #expect(fahrenheit.headline.contains("°F"))
            #expect(fahrenheit.headline != celsius.headline)
            // 85 °C is 185 °F: three digits where there were two, which is the
            // width change a fixed-size panel has to survive.
            #expect(fahrenheit.headline.contains("185") || fahrenheit.headline.contains("189"))
        }
    }
}
