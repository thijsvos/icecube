// AlertManager.swift — the app's notifications: a fever alarm, and the moments Ice Cube stops being in charge.

import Foundation
import IceCubeKit
import Observation
import os
import UserNotifications

/// Everything Ice Cube will interrupt you for.
///
/// Two jobs, deliberately in one type because they share the permission flow,
/// the simulated-mode gate and the "do not nag" instinct:
///
/// 1. **A temperature threshold.** One notification when the hottest die sensor
///    crosses the user's limit, re-armed only after a real 5 °C cooldown.
/// 2. **Loss of control.** The daemon reverting, a failed write, the guardian
///    taking the fans off macOS, or the fans sitting at maximum for an hour.
///    Decided by ``ControlAlertRules``, which is pure and owns every question
///    about how often it is acceptable to speak.
///
/// The second job was missing entirely until 2026-08-07, and its absence was
/// measurable: seven days of the owner's log held five `SAFETY:` lines and ten
/// guardian engagements, none of which the user was ever told about. The app
/// said when the Mac was hot and never said when it had stopped being able to
/// do anything about it.
///
/// Permission is requested lazily on first enable; a denial is surfaced as UI
/// state, never an error dialog.
@Observable
final class AlertManager {
    /// The die-temperature threshold that fires an alert.
    ///
    /// An enum, like every other user preference in the app (`TemperatureUnit`,
    /// `PollInterval`, `MenuBarDisplayMode`, `ChartHeight`): the allowed values
    /// are a fixed set, and the old shape carried them as a `Double?` in the
    /// model, an `Int` in the picker binding and a `0` sentinel on disk, with
    /// lossy conversions at both boundaries.
    enum Threshold: Int, CaseIterable, Identifiable {
        case off = 0
        case warm = 85
        case hot = 90
        case critical = 95

        var id: Int {
            rawValue
        }

        /// The threshold in °C, or `nil` when alerts are off.
        var celsius: Double? {
            self == .off ? nil : Double(rawValue)
        }
    }

    /// Alert threshold; `.off` disables notifications. Persisted.
    var threshold: Threshold {
        didSet {
            defaults.set(threshold.rawValue, forKey: Self.key)
            if threshold != .off {
                requestPermissionIfNeeded()
            }
        }
    }

    /// True when macOS denied notification permission (Settings hint shown).
    private(set) var permissionDenied = false

    private var armed = true
    private static let key = "alertThresholdCelsius"
    /// Stores the NEGATION — see the initialiser.
    private static let controlKey = "alertsControlLossDisabled"
    private let log = Logger(subsystem: HelperConstants.logSubsystem, category: "ui")

    /// When true, every threshold rule still runs and the UI still updates —
    /// but nothing is handed to `UNUserNotificationCenter`.
    ///
    /// Simulated temperatures are a sine wave with random spikes, so an ungated
    /// simulated run posts real Notification Centre banners about a machine
    /// that is fine, and can raise a real permission prompt the user never
    /// asked for. Suppressing only the delivery keeps the Alerts settings and
    /// the arm/re-arm logic demonstrable, which CLAUDE.md rule 3 requires.
    private let deliversNotifications: Bool

    /// Exposed for `SimulatedIsolationTests`: whether this instance can post at
    /// all. The suppression is the guarantee, so it is asserted rather than
    /// trusted to a constructor argument nobody checks.
    var deliversNotificationsForTesting: Bool {
        deliversNotifications
    }

    private let defaults: any KeyValueStore

    init(defaults: any KeyValueStore = UserDefaults.standard, deliversNotifications: Bool = true) {
        self.deliversNotifications = deliversNotifications
        self.defaults = defaults
        // `integer(forKey:)` reads a previously stored 85.0 as 85, so existing
        // users migrate with no shim.
        threshold = Threshold(rawValue: defaults.integer(forKey: Self.key)) ?? .off
        // Defaults ON: this is the class of event the daemon itself calls "the
        // one event class the user most needs to see", and it was silent until
        // now, so a user who has never opened Settings should still be told.
        //
        // The key stores the *negation* for that reason. `KeyValueStore` has no
        // `object(forKey:)`, so `bool` cannot distinguish "never set" from
        // "deliberately false" — and widening a protocol that exists to keep
        // tests off the real preferences system, for one default, is the wrong
        // trade. Storing "disabled" makes the missing-key default fall out of
        // `bool`'s own `false`.
        reportsControlLoss = !defaults.bool(forKey: Self.controlKey)
    }

    /// Called once per snapshot with the hottest die reading.
    func evaluate(dieCelsius: Double?) {
        guard let limit = threshold.celsius, let die = dieCelsius else { return }
        if die >= limit, armed {
            armed = false
            guard deliversNotifications else { return }
            deliver(die: die, threshold: limit)
        } else if die < limit - 5 {
            armed = true // re-arm only after a real cooldown
        }
    }

    // MARK: - Loss of control

    /// Whether Ice Cube may say it has lost control of the fans.
    ///
    /// On by default, and separately from the temperature threshold. Someone who
    /// does not want a fever alarm may still want to know their fan control
    /// stopped working — those are different questions, and tying them together
    /// is how the second one stayed unanswerable for so long.
    var reportsControlLoss: Bool {
        didSet {
            defaults.set(!reportsControlLoss, forKey: Self.controlKey)
            if reportsControlLoss {
                requestPermissionIfNeeded()
            }
        }
    }

    /// Everything ``ControlAlertRules`` remembers between polls.
    @ObservationIgnored private var controlState = ControlAlertRules.State()

    /// Called once per status refresh with the decisions that are **new**.
    ///
    /// The freshness matters: `HelperManager` already dedupes by `id` and
    /// already computes exactly this set, so handing over the whole timeline
    /// would re-alert on every poll.
    func evaluateControl(freshDecisions: [DecisionEvent], fans: [Fan], now: Date = Date()) {
        guard reportsControlLoss else { return }
        let alerts = ControlAlertRules.evaluate(
            freshDecisions: freshDecisions,
            fans: fans,
            now: now,
            state: &controlState
        )
        for alert in alerts {
            // Logged whether or not it is delivered, so the decision to speak is
            // auditable even when notifications are denied or simulated.
            log.notice("alert: \(alert.title, privacy: .public)")
            guard deliversNotifications else { continue }
            deliver(title: alert.title, body: alert.body, id: alert.id)
        }
    }

    private func deliver(die: Double, threshold: Double) {
        deliver(
            title: "Ice Cube temperature alert",
            body: "Hottest sensor reached \(Int(die.rounded())) °C (threshold \(Int(threshold)) °C).",
            id: "temp-alert-\(Int(die))"
        )
    }

    private func deliver(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        // The async API: this type is already @MainActor, so a plain Task
        // inherits that isolation. The old completion handler wrapped a nested
        // Task { @MainActor [weak self] } whose only job was to hop to the main
        // actor to touch a Logger — which is Sendable and needs no isolation.
        Task { [log] in
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                log.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func requestPermissionIfNeeded() {
        Task {
            let granted = await (try? UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])) ?? false
            permissionDenied = !granted
        }
    }
}
