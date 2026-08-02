// AlertManager.swift — temperature-threshold notifications with a graceful permission flow.

import Foundation
import Observation
import os
import UserNotifications

/// Sends one notification when the hottest die sensor crosses the user's
/// threshold, then re-arms after it cools 5 °C below — a fever alarm, not a
/// nag.
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
    private let log = Logger(subsystem: "io.github.thijsvos.icecube", category: "ui")

    /// When true, every threshold rule still runs and the UI still updates —
    /// but nothing is handed to `UNUserNotificationCenter`.
    ///
    /// Simulated temperatures are a sine wave with random spikes, so an ungated
    /// simulated run posts real Notification Centre banners about a machine
    /// that is fine, and can raise a real permission prompt the user never
    /// asked for. Suppressing only the delivery keeps the Alerts settings and
    /// the arm/re-arm logic demonstrable, which CLAUDE.md rule 3 requires.
    private let deliversNotifications: Bool
    private let defaults: any KeyValueStore

    init(defaults: any KeyValueStore = UserDefaults.standard, deliversNotifications: Bool = true) {
        self.deliversNotifications = deliversNotifications
        self.defaults = defaults
        // `integer(forKey:)` reads a previously stored 85.0 as 85, so existing
        // users migrate with no shim.
        threshold = Threshold(rawValue: defaults.integer(forKey: Self.key)) ?? .off
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

    private func deliver(die: Double, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Ice Cube temperature alert"
        content.body = "Hottest sensor reached \(Int(die.rounded())) °C (threshold \(Int(threshold)) °C)."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "temp-alert-\(Int(die))", content: content, trigger: nil
        )
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
