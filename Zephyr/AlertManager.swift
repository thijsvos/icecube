// AlertManager.swift — temperature-threshold notifications with a graceful permission flow.

import Foundation
import Observation
import os
import UserNotifications

/// Sends one notification when the hottest die sensor crosses the user's
/// threshold, then re-arms after it cools 5 °C below — a fever alarm, not a
/// nag. Permission is requested lazily on first enable; a denial is surfaced
/// as UI state, never an error dialog.
@MainActor
@Observable
final class AlertManager {
    /// Alert threshold in °C; `nil` = alerts off. Persisted.
    var thresholdCelsius: Double? {
        didSet {
            UserDefaults.standard.set(thresholdCelsius ?? 0, forKey: Self.key)
            if thresholdCelsius != nil {
                requestPermissionIfNeeded()
            }
        }
    }

    /// True when macOS denied notification permission (Settings hint shown).
    private(set) var permissionDenied = false

    private var armed = true
    private static let key = "alertThresholdCelsius"
    private let log = Logger(subsystem: "io.github.thijsvos.zephyr", category: "ui")

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.key)
        thresholdCelsius = stored > 0 ? stored : nil
    }

    /// Called once per snapshot with the hottest die reading.
    func evaluate(dieCelsius: Double?) {
        guard let threshold = thresholdCelsius, let die = dieCelsius else { return }
        if die >= threshold, armed {
            armed = false
            deliver(die: die, threshold: threshold)
        } else if die < threshold - 5 {
            armed = true // re-arm only after a real cooldown
        }
    }

    private func deliver(die: Double, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = "Zephyr temperature alert"
        content.body = "Hottest sensor reached \(Int(die.rounded())) °C (threshold \(Int(threshold)) °C)."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "temp-alert-\(Int(die))", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.log.error("notification failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor [weak self] in
                self?.permissionDenied = !granted
            }
        }
    }
}
