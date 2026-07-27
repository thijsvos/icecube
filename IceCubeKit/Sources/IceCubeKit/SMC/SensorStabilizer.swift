// SensorStabilizer.swift — keeps the published sensor list static: fresh values when plausible, last good otherwise.

import Foundation

/// Merges one tick's raw sensor reads with the last known-good values so the
/// published list **always** contains every discovered sensor, in the same
/// order — a sensor that glitches for a tick holds its previous value instead
/// of vanishing.
///
/// Rows that appear and disappear make the whole popover resize every second;
/// a static list is a UI requirement, not a nicety.
enum SensorStabilizer {
    /// - Parameters:
    ///   - sensors: the discovered sensor list (fixed at discovery time).
    ///   - freshValues: this tick's successful raw reads, by key (a failed
    ///     read simply has no entry).
    ///   - lastGood: the previous known-good value per key.
    /// - Returns: one reading per discovered sensor — fresh when plausible,
    ///   held otherwise — plus the updated known-good cache.
    static func stabilize(
        sensors: [SMCKeyMaps.SensorDescriptor],
        freshValues: [String: Double],
        lastGood: [String: Double]
    ) -> (readings: [SensorReading], lastGood: [String: Double]) {
        var cache = lastGood
        var readings: [SensorReading] = []
        readings.reserveCapacity(sensors.count)
        for sensor in sensors {
            if let fresh = freshValues[sensor.key], SMCKeyMaps.isPlausibleTemperature(fresh) {
                cache[sensor.key] = fresh
                readings.append(SensorReading(key: sensor.key, label: sensor.label, celsius: fresh))
            } else if let held = cache[sensor.key] {
                readings.append(SensorReading(key: sensor.key, label: sensor.label, celsius: held))
            }
            // No fresh value AND no held value: unreachable in practice —
            // discovery only admits sensors whose first read was plausible,
            // which seeds the cache.
        }
        return (readings, cache)
    }
}
