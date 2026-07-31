// PowerCapabilities.swift — the power-capability bits, and the one question a fan daemon asks of them: is a display
// lit?

import Foundation

/// The system power capability bitfield: what the machine has actually powered
/// on for this wake.
///
/// The values are the public `kIOPMSystemCapability*` enum in
/// `<IOKit/pwr_mgt/IOPM.h>` — a plain C enum, so unlike the `kIOMessage*`
/// macros in ``SystemPowerMessage`` Swift *could* import these. They are
/// restated here so IceCubeKit keeps its no-IOKit-import rule (this type is
/// linked into the unprivileged app), and so a typo is caught by a test rather
/// than by a closed laptop.
///
/// Each value was also swept out of the shipping IOKit on this Mac14,9 by
/// calling its own exported `IOPMGetCapabilitiesDescription` per bit:
/// `0x01 "cpu" · 0x02 "vid" · 0x04 "aud" · 0x08 "net" · 0x10 "disk" ·
/// 0x20 "push" · 0x40 "bg"`, and `0x01 -> "DarkWake:cpu"`,
/// `0x1F -> "FullWake:cpu disk net aud vid"` — IOKit labels the two classes
/// itself, and the discriminator is the video bit.
public struct PowerCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The SoC is running. Set on EVERY wake, dark or full — on its own, this
    /// bit is what makes a dark wake a dark wake.
    public static let cpu = PowerCapabilities(rawValue: 0x01)
    /// A display is powered — `kIOPMSystemCapabilityGraphics`, "vid" to IOKit's
    /// own describer. THE discriminator: across seven days of the owner's
    /// `pmset -g log` it was set on 24 of 24 full wakes and 0 of 176 dark
    /// wakes. It means "a panel is lit", NOT "the lid is open", which is why a
    /// docked clamshell Mac driving an external display still classifies as a
    /// full wake and keeps fan control.
    public static let video = PowerCapabilities(rawValue: 0x02)
    public static let audio = PowerCapabilities(rawValue: 0x04)
    public static let network = PowerCapabilities(rawValue: 0x08)
    /// `kIOPMSystemCapabilityAOT` in the kernel header, "disk" in userspace's
    /// describer. Unused, and that disagreement is exactly why nothing above
    /// ``video`` is load-bearing here.
    public static let diskOrAOT = PowerCapabilities(rawValue: 0x10)
    public static let pushServiceTask = PowerCapabilities(rawValue: 0x20)
    public static let backgroundTask = PowerCapabilities(rawValue: 0x40)
    public static let silentRunning = PowerCapabilities(rawValue: 0x80)

    /// `0x79 [CDNPB]` — the hex plus the letters `pmset -g log` prints in its
    /// own wake lines, so a daemon log line can be lined up against the
    /// system's account of the same second without a decoder ring. That
    /// correlation is how this bug was found.
    public static func describe(_ capabilities: PowerCapabilities?) -> String {
        guard let capabilities else { return "capabilities unreadable" }
        let letters: [(PowerCapabilities, String)] = [
            (.cpu, "C"), (.diskOrAOT, "D"), (.network, "N"), (.video, "V"),
            (.audio, "A"), (.pushServiceTask, "P"), (.backgroundTask, "B"),
            (.silentRunning, "S"),
        ]
        let names = letters.filter { capabilities.contains($0.0) }.map(\.1).joined()
        let hex = String(capabilities.rawValue, radix: 16, uppercase: true)
        return "0x\(capabilities.rawValue < 0x10 ? "0" + hex : hex) [\(names)]"
    }
}

/// What the machine is doing, as far as the power manager is concerned.
public enum WakeClass: Sendable, Equatable {
    /// No CPU capability — impossible while our own tick is executing, so in
    /// practice this means the read returned nonsense.
    case asleep
    /// CPU without video: a maintenance / SleepService / network dark wake. The
    /// lid may well be shut and the machine in a bag. Never a reason to spin a
    /// fan.
    case darkWake
    /// CPU and video: a panel is lit — internal, external, or clamshell with an
    /// external display. Safe to resume fan control.
    case fullWake
    /// Neither capability source answered. Never treated as ``fullWake``.
    case unknown
}

/// Turns the bitfield into the only distinction the daemon acts on.
public enum WakeClassifier {
    /// Deliberately stricter than IOKit's own `IOPMIsAUserWake`, which is
    /// literally `caps & 0x02` and therefore calls the physically impossible
    /// value `0x02` — video without CPU — a user wake. Requiring ``cpu`` too
    /// costs nothing and means a garbage read can never be read as a full wake.
    public static func classify(_ capabilities: PowerCapabilities?) -> WakeClass {
        guard let capabilities else { return .unknown }
        guard capabilities.contains(.cpu) else { return .asleep }
        return capabilities.contains(.video) ? .fullWake : .darkWake
    }
}
