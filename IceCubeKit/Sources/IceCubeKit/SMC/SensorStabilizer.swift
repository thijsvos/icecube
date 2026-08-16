// SensorStabilizer.swift — keeps the published sensor list static: fresh values when plausible, last good otherwise.

import Foundation

/// Merges one tick's raw sensor reads with the last known-good values so the
/// published list contains every sensor that has **ever** reported, in
/// discovery order — a sensor that glitches for a tick holds its previous
/// value instead of vanishing.
///
/// Rows that appear and disappear make the whole popover resize every second;
/// a static list is a UI requirement, not a nicety. The guarantee is precisely
/// **monotone**: once a key has produced one plausible reading it is present in
/// every later tick, at the same position, forever — the list never shrinks and
/// never reorders. It is deliberately *not* "fixed at discovery": admission is
/// by key existence (``SensorAdmission``), and on Apple Silicon a power-gated
/// cluster reports nothing usable for up to ~85 s after launch (measured on
/// Mac14,9). Those sensors join the list when they first report.
enum SensorStabilizer {
    /// Turns one tick's raw reads into the list the UI renders, holding the last
    /// good value for any sensor that misread.
    ///
    /// - Parameters:
    ///   - sensors: the discovered sensor list (fixed at discovery time).
    ///   - freshValues: this tick's successful raw reads, by key (a failed
    ///     read simply has no entry).
    ///   - lastGood: the previous known-good value per key.
    /// - Returns: one reading for every sensor that has produced a plausible
    ///   value at least once this process — this tick's read when it was
    ///   plausible, the last good one otherwise — plus the updated known-good
    ///   cache. An admitted sensor that has **never** reported yields no reading
    ///   at all, which is why the published list grows over the first minute of a
    ///   launch instead of starting complete.
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
            // Admitted, nothing to show yet: the key exists but has not
            // produced a plausible reading in this process — a power-gated
            // cluster at launch, or a curated key this particular machine never
            // populates. No row beats an invented one; the row appears on the
            // tick the sensor first reports, and stays from then on. This
            // branch was documented as unreachable while admission required a
            // plausible first read, which is exactly what made the sensor list
            // a per-launch lottery.
        }
        return (readings, cache)
    }
}
