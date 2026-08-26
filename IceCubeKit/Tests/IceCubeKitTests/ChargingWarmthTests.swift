// ChargingWarmthTests.swift — the app may name this cause, so it must never name it wrongly.

import Foundation
@testable import IceCubeKit
import Testing

/// The case this exists for, measured on a Mac14,9 while charging: die 56 °C,
/// both cells under 35 °C, no process above 0.03 W, and a case that felt
/// distinctly warm to its owner. Every number Ice Cube reported was correct and
/// none of them helped.
///
/// This is the only place the diagnosis window names a cause rather than
/// ranking one, so the tests are shaped around the ways it could name it
/// wrongly: claiming charging heat when nothing is charging, when the case is
/// cool enough that nobody is asking, or when the die is genuinely hot and
/// charging is a distraction from the real answer.
@Suite("ChargingWarmth — the one cause the app may name")
struct ChargingWarmthTests {
    private static func heat(_ celsius: Double, band: ThermalDiagnosis.Heat.Band) -> ThermalDiagnosis.Heat {
        .measured(celsius: celsius, label: "CPU P-core 1", band: band, headroom: 104 - celsius)
    }

    /// The reported case, in its reported numbers.
    @Test("Charging, warm case, cool die — the answer the window had none for")
    func theReportedCase() {
        let warmth = ChargingWarmth.assess(
            isCharging: true,
            batteryCelsius: 34.8,
            heat: Self.heat(56, band: .cool),
            wasWarm: false
        )
        #expect(warmth == .warm(batteryCelsius: 34.8))
        #expect(warmth.isWarm)
    }

    /// The claim is only ever made from an observed fact. If IOKit does not say
    /// charging, no battery temperature may produce this row — that is what
    /// keeps it from being the guess `docs/DIAGNOSIS.md` forbids.
    @Test("Not charging is silent at any temperature", arguments: [20.0, 32.0, 40.0, 60.0, 94.0])
    func notChargingIsAlwaysSilent(battery: Double) {
        #expect(
            ChargingWarmth.assess(
                isCharging: false,
                batteryCelsius: battery,
                heat: Self.heat(45, band: .cool),
                wasWarm: false
            ) == .silent,
            "\(battery) °C without charging is not this row's business"
        )
    }

    /// Below the onset there is nothing to explain: the case does not read as
    /// warm, so nobody is asking why it is.
    @Test("A cool battery is silent even while charging", arguments: [20.0, 28.0, 31.9])
    func coolBatteryIsSilent(battery: Double) {
        #expect(
            ChargingWarmth.assess(
                isCharging: true,
                batteryCelsius: battery,
                heat: Self.heat(45, band: .cool),
                wasWarm: false
            ) == .silent
        )
    }

    /// A hot die is the better answer, and two answers would bury it. This is
    /// the case where naming charging would actively mislead: the user asks why
    /// it is hot, and the honest reply is the 100 °C chip, not the battery.
    @Test("A hot die suppresses it", arguments: [ThermalDiagnosis.Heat.Band.hot, .nearCeiling])
    func hotDieSuppresses(band: ThermalDiagnosis.Heat.Band) {
        #expect(
            ChargingWarmth.assess(
                isCharging: true,
                batteryCelsius: 40,
                heat: Self.heat(100, band: band),
                wasWarm: false
            ) == .silent
        )
    }

    /// `.unknown` is not a hot die. A Mac reporting no die sensor cannot rule
    /// the chip in or out, and the battery reading is still true — refusing to
    /// speak there would withhold the one fact that is known.
    @Test("No die sensor does not suppress it")
    func unknownHeatDoesNotSuppress() {
        #expect(
            ChargingWarmth.assess(
                isCharging: true,
                batteryCelsius: 35,
                heat: .unknown,
                wasWarm: false
            ) == .warm(batteryCelsius: 35)
        )
    }

    /// A Mac with no battery — a desktop — has nothing to report.
    @Test("No battery sensor is silent")
    func noBatteryIsSilent() {
        #expect(
            ChargingWarmth.assess(
                isCharging: true,
                batteryCelsius: nil,
                heat: Self.heat(45, band: .cool),
                wasWarm: false
            ) == .silent
        )
    }

    /// The row must not blink on and off while the battery hovers at the onset,
    /// which is exactly what it would do without the release band — a battery
    /// wandering by a tenth of a degree around 32 °C would rewrite the window
    /// once a second. Same arm/re-arm shape as `AlertManager.evaluate`.
    @Test("Hysteresis: appears at 32, survives down to 30, gone below")
    func hysteresisHoldsTheRowStill() {
        func assess(_ battery: Double, wasWarm: Bool) -> ChargingWarmth {
            ChargingWarmth.assess(
                isCharging: true,
                batteryCelsius: battery,
                heat: Self.heat(45, band: .cool),
                wasWarm: wasWarm
            )
        }
        // Rising: nothing at 31.9, appears at 32.
        #expect(assess(31.9, wasWarm: false) == .silent)
        #expect(assess(32, wasWarm: false).isWarm)
        // Falling: 31 would not have started it, but it does not stop it.
        #expect(assess(31, wasWarm: true).isWarm, "a tenth of a degree must not close the row")
        #expect(assess(30, wasWarm: true).isWarm)
        #expect(assess(29.9, wasWarm: true) == .silent)
    }

    /// The two thresholds must stay ordered, or the release band inverts and
    /// the hysteresis becomes a flicker generator instead of a damper.
    @Test("The release threshold is below the onset")
    func thresholdsAreOrdered() {
        #expect(ChargingWarmth.releaseCelsius < ChargingWarmth.onsetCelsius)
    }
}

/// The helper the verdict depends on. `.ambient` is a catch-all that also holds
/// airflow, SSD and wireless, so "the hottest ambient sensor" is not the
/// battery — on the Mac this was measured on, airflow read 39.9 °C while both
/// cells sat below 35 °C. Picking the wrong one would have reported the exhaust
/// temperature as the surface under the user's hand.
@Suite("batteryCelsius — the surface a hand actually touches")
struct BatteryCelsiusTests {
    private static let mac14_9: [SensorReading] = [
        SensorReading(key: "Tp09", label: "CPU P-core 3", celsius: 56.0),
        SensorReading(key: "TaRF", label: "Airflow Right", celsius: 39.9),
        SensorReading(key: "TW0P", label: "Wireless", celsius: 39.6),
        SensorReading(key: "TB1T", label: "Battery 1", celsius: 34.8),
        SensorReading(key: "TH0x", label: "SSD", celsius: 34.5),
        SensorReading(key: "TB2T", label: "Battery 2", celsius: 33.9),
    ]

    @Test("The warmest cell, not the warmest ambient sensor")
    func picksTheWarmestCell() {
        #expect(Self.mac14_9.batteryCelsius == 34.8)
        #expect(
            Self.mac14_9.hottestCelsius(in: .ambient) == 39.9,
            "the catch-all really does answer with airflow, which is why this helper exists"
        )
    }

    @Test("A Mac with no battery reports none")
    func noBattery() {
        let desktop = Self.mac14_9.filter { !$0.key.hasPrefix("TB") }
        #expect(desktop.batteryCelsius == nil)
    }

    @Test("Battery keys are not die keys, so they never drive the curve")
    func batteryIsNotDie() {
        #expect(SMCKeyMaps.isBatteryKey("TB1T"))
        #expect(SMCKeyMaps.isBatteryKey("TB2T"))
        #expect(!SMCKeyMaps.isBatteryKey("TaRF"))
        #expect(!SMCKeyMaps.isBatteryKey("Tp09"))
        #expect(!SMCKeyMaps.isDieKey("TB1T"))
    }
}
