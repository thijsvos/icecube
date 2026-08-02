// FanControlMemory.swift — what the app remembers about fan control between launches, and the keys it lives under.

import Foundation
import IceCubeKit

/// The app's persisted memory of the user's fan-control intent: the last curve,
/// the startup preference, and whether a curve may outlive the app.
///
/// Its own type because these three are one subject with one lifetime, and
/// because scattering `defaults.set(_:forKey:)` across a 900-line manager is how
/// a key ends up written from two places with two different meanings. It has
/// already happened once here: `persistCurvePreference` used to read
/// `UserDefaults.standard` directly while everything else read the injected
/// suite, so under test it consulted the developer's own preference and the
/// power rule's assertions depended on a setting outside the test.
///
/// Takes a ``KeyValueStore`` rather than `UserDefaults` for the same reason
/// `HelperManager` does — tests hand it an in-memory store and nothing touches
/// the preferences system.
struct FanControlMemory {
    private let defaults: any KeyValueStore

    init(defaults: any KeyValueStore) {
        self.defaults = defaults
    }

    // MARK: - Keys

    private static let lastCurveKey = "lastCurveConfig"
    private static let preferenceKey = "startupPreference"
    private static let persistCurveKey = "persistCurve"

    // MARK: - The persist toggle

    /// The app-wide "keep the curve running when I quit" preference.
    var persistsCurveWithoutApp: Bool {
        defaults.bool(forKey: Self.persistCurveKey)
    }

    // MARK: - The last curve

    /// The last curve config the user successfully applied, if any.
    var lastCurve: FanConfig? {
        guard let data = defaults.data(forKey: Self.lastCurveKey),
              var config = try? JSONDecoder().decode(FanConfig.self, from: data)
        else { return nil }
        // The stored copy predates the current toggle, so the live preference
        // wins — otherwise turning persistence off would not take effect until
        // the user next applied a curve by hand.
        config.persistsWithoutApp = persistsCurveWithoutApp
        return config
    }

    /// Records a config the daemon **accepted**.
    ///
    /// Only on success, and that is load-bearing: this write used to run
    /// unconditionally, so a curve the daemon rejected was still stored and
    /// silently resumed on the next launch — fan control the user had been told
    /// had failed, arriving without any interaction.
    func remember(applied config: FanConfig) {
        switch config.mode {
        case .curve:
            defaults.set(StartupPolicy.Preference.curve.rawValue, forKey: Self.preferenceKey)
            if let data = try? JSONEncoder().encode(config) {
                defaults.set(data, forKey: Self.lastCurveKey)
            }
        case .auto:
            // Unreachable from the UI since the macOS preset was removed — auto
            // is now only ever a daemon resting state, never a user choice. If
            // one does arrive, forget the stored preference rather than record
            // an intent nothing can express: "never chose" is the truth, and it
            // lands the next launch on the fallback curve.
            defaults.removeObject(forKey: Self.preferenceKey)
            defaults.removeObject(forKey: Self.lastCurveKey)
        case .manual:
            // Manual is never the persisted default — no launch may put the fans
            // under fixed-RPM control on its own.
            break
        }
    }

    /// The user's last deliberate mode choice, for `StartupPolicy`.
    var storedPreference: StartupPolicy.Preference? {
        guard let raw = defaults.string(forKey: Self.preferenceKey) else { return nil }
        return StartupPolicy.Preference(rawValue: raw)
    }

    /// Turning fan control off is a clean slate, not a pause: leaving either
    /// key behind would let a later re-enable silently resurrect a curve from a
    /// session the user has long forgotten.
    func forgetEverything() {
        defaults.removeObject(forKey: Self.lastCurveKey)
        defaults.removeObject(forKey: Self.preferenceKey)
    }
}
