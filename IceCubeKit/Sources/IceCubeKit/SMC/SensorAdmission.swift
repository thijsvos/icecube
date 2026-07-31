// SensorAdmission.swift — decides which curated sensors a Mac HAS, from key existence rather than from a value.

import Foundation

/// Which of a candidate sensor list this machine actually carries.
///
/// **Membership is a property of the hardware, so it is decided from the one
/// signal that does not change between two runs of the app**: whether the
/// firmware knows the key, and whether its wire type carries a number we can
/// decode. A reading is never consulted — this type cannot see one.
///
/// Measured on Mac14,9 (2026-07-30), which is why the rule changed. All 20
/// curated keys exist, and none failed a single read in 11,300 attempts. What
/// varies is the *value*: a power-gated CPU cluster returns a frozen firmware
/// sentinel — two constants, 6.70 °C and 4.63 °C, applied to a whole cluster at
/// once — and the old rule, which admitted a key only if its FIRST read was
/// plausible, read that as "dead sensor" and disowned the key for the life of
/// the process. Idle, the P-cluster is gated at 66.9 % of instants and the
/// E-cluster at 21.8 %, all-or-nothing per cluster, so discovery resolved 20,
/// 16, 12 or 8 sensors depending on the millisecond it happened to run.
///
/// Re-reading cannot fix that, which is why this is not a retry: a gated key
/// does not refresh at all (24 consecutive 1 s samples yielded one distinct
/// value), an immediate retry recovered 0 of 18 misses, and so did +5 ms and
/// +50 ms. Gate episodes last 1.1–84.8 s.
///
/// The two conditions separate cleanly, which is what makes existence safe to
/// trust: an absent key **throws** (13 of 13 absent candidates, every attempt),
/// while a gated key never does. Plausibility keeps its old job on the value
/// path — see ``SensorStabilizer`` — so a sentinel 6.70 °C is still kept out of
/// the display, the charts and the alert threshold. It simply no longer decides
/// whether the sensor exists.
///
/// A pure function over probe results, for the same reason `DaemonCore` lives
/// in this package: `SystemSMCProvider` holds a concrete `SMCConnection` and
/// cannot be faked, so a rule living inside it could not be tested — and this
/// particular rule has now been wrong once already.
enum SensorAdmission {
    /// What one key-info probe found.
    ///
    /// `absent` is a case rather than a `nil` because "the firmware has no such
    /// key" and "the firmware would not answer" are different facts with
    /// different consequences: the first is a stable property of the model, the
    /// second is a transport failure that must not be cached as an answer.
    enum Probe: Sendable, Equatable {
        /// The firmware answered, reporting this 4-character wire type.
        case present(type: String)
        /// The firmware says this machine has no such key.
        case absent
    }

    /// The candidates this machine carries, in the **candidate list's** order.
    ///
    /// Order is the caller's, never the probe dictionary's: the popover, the
    /// charts and the Sensors window all render this order, and deriving it
    /// from an unordered dictionary would trade one per-launch lottery for
    /// another.
    static func admit(
        candidates: [SMCKeyMaps.SensorDescriptor],
        probes: [String: Probe]
    ) -> [SMCKeyMaps.SensorDescriptor] {
        candidates.filter { candidate in
            guard case let .present(type) = probes[candidate.key] ?? .absent,
                  let decoded = SMCDataType(rawValue: type)
            else { return false }
            return carriesTemperature(decoded)
        }
    }

    /// Whether a key of this wire type can carry a temperature we can decode.
    ///
    /// Exhaustive on purpose: when `SMCDataType` grows a case — an Intel port
    /// adding `sp78` is the likely one — the compiler asks whether it is a
    /// temperature, instead of the new type silently failing admission and a
    /// sensor quietly disappearing from the list.
    private static func carriesTemperature(_ type: SMCDataType) -> Bool {
        switch type {
        case .float, .fpe2, .uint8, .uint16, .uint32: true
        case .flag, .fanDescriptor: false
        }
    }
}
