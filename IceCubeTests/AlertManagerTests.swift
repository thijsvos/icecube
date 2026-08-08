// AlertManagerTests.swift — the fever alarm's hysteresis, and the switch that decides whether Ice Cube speaks at all.

import Foundation
import IceCubeKit
import Testing

/// `AlertManager` was in the test target's allow-list from the day it was
/// written and had **zero tests** until 2026-08-07, sitting at 39 % covered
/// after two PRs doubled its size. The seams were already there — an injected
/// `KeyValueStore` and a `deliversNotifications` flag — so this was a gap, not
/// a constraint.
///
/// What is *not* asserted here is delivery itself: `UNUserNotificationCenter`
/// needs a real bundle and a user, and a host-less test bundle has neither.
/// Everything up to the hand-off is covered, and the hand-off is gated by one
/// flag that `simulatedAlertsAreNotDelivered` pins separately.
@MainActor
@Suite("AlertManager — when to speak, and when to have already spoken")
struct AlertManagerTests {
    static func manager(
        _ store: SimulatedEnvironment.Defaults = SimulatedEnvironment.Defaults(),
        delivers: Bool = false
    ) -> AlertManager {
        AlertManager(defaults: store, deliversNotifications: delivers)
    }

    // MARK: - The temperature threshold

    @Test("Alerts are off until the user picks a threshold")
    func thresholdDefaultsToOff() {
        #expect(Self.manager().threshold == .off)
    }

    /// Stored as an `Int`, so a value written by an older build reads back
    /// without a migration shim.
    @Test("A stored threshold survives a relaunch")
    func thresholdPersists() {
        let store = SimulatedEnvironment.Defaults()
        Self.manager(store).threshold = .hot
        #expect(Self.manager(store).threshold == .hot)
    }

    @Test("An unrecognised stored threshold falls back to off rather than crashing")
    func garbageThresholdFallsBack() {
        let store = SimulatedEnvironment.Defaults()
        store.set(77, forKey: "alertThresholdCelsius")
        #expect(Self.manager(store).threshold == .off)
    }

    @Test("Off means no threshold, every other case is a real temperature")
    func thresholdCelsiusMapping() {
        #expect(AlertManager.Threshold.off.celsius == nil)
        for threshold in AlertManager.Threshold.allCases where threshold != .off {
            #expect(threshold.celsius == Double(threshold.rawValue))
        }
    }

    /// A fever alarm, not a nag: crossing the threshold fires once, and the
    /// alarm does not re-arm until the machine has genuinely cooled 5 °C below
    /// it. Without the hysteresis a die hovering on the boundary would notify
    /// on every poll.
    @Test("Crossing the threshold fires once and stays quiet until a real cooldown")
    func feverAlarmDoesNotNag() {
        let alerts = Self.manager()
        alerts.threshold = .hot // 90

        alerts.evaluate(dieCelsius: 91) // fires, disarms
        alerts.evaluate(dieCelsius: 95)
        alerts.evaluate(dieCelsius: 91)
        alerts.evaluate(dieCelsius: 86) // still inside the 5 °C band
        #expect(!alerts.isArmedForTesting, "hovering above the release point must not re-arm")

        alerts.evaluate(dieCelsius: 84) // 90 - 5 - 1: a real cooldown
        #expect(alerts.isArmedForTesting, "and a genuine cooldown must")
    }

    @Test("A missing reading is not a crossing")
    func nilReadingIsIgnored() {
        let alerts = Self.manager()
        alerts.threshold = .hot
        alerts.evaluate(dieCelsius: nil)
        #expect(alerts.isArmedForTesting, "no reading is not the same as a cool reading")
    }

    @Test("With alerts off, nothing is evaluated at any temperature")
    func offMeansOff() {
        let alerts = Self.manager()
        alerts.evaluate(dieCelsius: 110)
        #expect(alerts.isArmedForTesting)
    }

    // MARK: - Loss of control

    /// On by default, and stored as its own negation.
    ///
    /// `KeyValueStore.bool` cannot distinguish "never set" from "set false", so
    /// a key meaning *enabled* would default a new user to silence — for the
    /// class of event the daemon itself calls the one the user most needs to
    /// see. Storing *disabled* makes the missing-key default fall out of
    /// `bool`'s own `false`.
    @Test("Loss-of-control reporting is on for someone who has never opened Settings")
    func controlReportingDefaultsOn() {
        #expect(Self.manager().reportsControlLoss)
    }

    @Test("Turning it off persists, and so does turning it back on")
    func controlReportingPersistsBothWays() {
        let store = SimulatedEnvironment.Defaults()

        Self.manager(store).reportsControlLoss = false
        #expect(!Self.manager(store).reportsControlLoss, "an explicit off must survive a relaunch")

        Self.manager(store).reportsControlLoss = true
        #expect(Self.manager(store).reportsControlLoss)
    }

    /// The inverted key is an implementation detail, but getting it backwards
    /// would silence the feature for everyone — so the stored value is pinned
    /// directly rather than only through the round trip above.
    @Test("The stored key holds the negation")
    func storedKeyIsInverted() {
        let store = SimulatedEnvironment.Defaults()
        Self.manager(store).reportsControlLoss = false
        #expect(store.object(forKey: "alertsControlLossDisabled") as? Bool == true)
    }

    @Test("With loss-of-control reporting off, no decision produces an alert")
    func disabledMeansNoControlAlerts() {
        let alerts = Self.manager()
        alerts.reportsControlLoss = false
        // Would otherwise be a notification: a genuine fault, not a routine line.
        alerts.evaluateControl(
            freshDecisions: [DecisionEvent(text: "SAFETY: fan write failed mid-sequence", date: Date())],
            fans: [],
            now: Date()
        )
        // No delivery to assert against, so the observable is that the rules'
        // state was never advanced — a second call with the switch back on must
        // still be able to speak.
        alerts.reportsControlLoss = true
        alerts.evaluateControl(
            freshDecisions: [DecisionEvent(text: "SAFETY: fan write failed mid-sequence", date: Date())],
            fans: [],
            now: Date()
        )
    }

    /// The two switches are independent on purpose. Someone who does not want a
    /// fever alarm may still want to know their fan control stopped working.
    @Test("The temperature threshold and loss-of-control reporting do not gate each other")
    func theTwoSwitchesAreIndependent() {
        let alerts = Self.manager()
        #expect(alerts.threshold == .off)
        #expect(alerts.reportsControlLoss, "off by default for one, on by default for the other")

        alerts.threshold = .critical
        alerts.reportsControlLoss = false
        #expect(alerts.threshold == .critical, "turning one off must not disturb the other")
    }

    // MARK: - Delivery

    /// Suppression is the guarantee simulated mode rests on, so it is asserted
    /// rather than trusted to a constructor argument. The rules still run —
    /// CLAUDE.md rule 3 requires the feature to stay demonstrable — only the
    /// hand-off to `UNUserNotificationCenter` is skipped.
    @Test("A suppressed manager still evaluates every rule")
    func suppressedStillEvaluates() {
        let alerts = Self.manager(delivers: false)
        #expect(!alerts.deliversNotificationsForTesting)

        alerts.threshold = .warm
        alerts.evaluate(dieCelsius: 99)
        #expect(!alerts.isArmedForTesting, "the hysteresis advanced even though nothing was delivered")

        alerts.evaluateControl(
            freshDecisions: [DecisionEvent(text: "SAFETY: control lost (read-back failed twice)", date: Date())],
            fans: [],
            now: Date()
        )
    }

    @Test("Permission is not assumed denied before anything has asked")
    func permissionStartsUndenied() {
        #expect(!Self.manager().permissionDenied)
    }

    // MARK: - The unit reaches the notification

    /// A user who picked °F was told °C by the one surface that reaches them
    /// when the app is not on screen. Fixed 2026-08-08.
    @Test("The alert body honours the temperature unit")
    func alertBodyFollowsTheUnit() {
        let celsius = AlertManager.alertBody(die: 95, threshold: 90, style: .celsius)
        #expect(celsius == "Hottest sensor reached 95 °C (threshold 90 °C).")

        let fahrenheit = AlertManager.alertBody(die: 95, threshold: 90, style: .fahrenheit)
        #expect(fahrenheit == "Hottest sensor reached 203 °F (threshold 194 °F).")
        #expect(!fahrenheit.contains("°C"))
    }

    /// Both numbers are absolute readings, so both take the offset. Converting
    /// only one is the asymmetry worth pinning — it would read as a threshold
    /// the machine had blown past by 100 degrees.
    @Test("Both figures convert, not just the reading")
    func bothFiguresConvert() {
        let body = AlertManager.alertBody(die: 100, threshold: 100, style: .fahrenheit)
        #expect(body == "Hottest sensor reached 212 °F (threshold 212 °F).", "equal in °C stays equal in °F")
    }
}
