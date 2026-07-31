// SystemCapabilityReader.swift — the IOKit half of the dark-wake gate: read the live power capability bits.

import Foundation
import IceCubeKit
import IOKit

/// Reads the system power capabilities, from two independent sources because
/// the good one is not in the SDK.
///
/// Lives in this target for the same reason `SMCWritePort` and
/// `SystemPowerWatcher` do: it is raw IOKit and the app must never link it. The
/// rule that consumes the value is in `DaemonCore`, where it is tested.
///
/// 1. `IOPMConnectionGetSystemCapabilities()` — exported from IOKit.framework
///    and present in the public `IOKit.tbd` stub, but declared only in
///    `IOPMLibPrivate.h`, which Apple does not ship. Resolved with `dlsym`
///    rather than `@_silgen_name` so a macOS that drops it degrades at runtime
///    instead of failing to launch a root daemon. Needs no connection, no root,
///    no run loop and no GUI session — a straight synchronous poll.
/// 2. `IOPMrootDomain`'s `"System Capabilities"` property — fully public API,
///    same bit layout, read straight from the registry with no IPC. Measured
///    `0x0F` where source 1 said `0x1F`: the kernel omits the disk bit. The two
///    disagree only above `video`, which is why only `video` is load-bearing.
///
/// Returns nil when both fail. It never guesses — see `WakeClassifier`, where
/// nil is `.unknown` and `.unknown` is never a full wake.
enum SystemCapabilityReader {
    private typealias GetCapabilities = @convention(c) @Sendable () -> UInt32

    private static let getCapabilities: GetCapabilities? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let symbol = dlsym(handle, "IOPMConnectionGetSystemCapabilities")
        else { return nil }
        return unsafeBitCast(symbol, to: GetCapabilities.self)
    }()

    static func current() -> PowerCapabilities? {
        if let getCapabilities {
            return PowerCapabilities(rawValue: getCapabilities())
        }
        return fromRegistry()
    }

    private static func fromRegistry() -> PowerCapabilities? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(
            entry, "System Capabilities" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return nil }
        return PowerCapabilities(rawValue: value.uint32Value)
    }
}
