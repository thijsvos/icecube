// FanControlMemoryTests.swift — what the app remembers between launches, and the one mode it must never remember.

import Foundation
import IceCubeKit
import Testing

/// This is where "manual is never the persisted default" is actually enforced
/// on the app side, and until it had a type of its own the rule was three
/// `defaults.set` calls scattered through a 900-line manager.
///
/// The invariant matters: no launch may put the fans under fixed-RPM control on
/// its own. `StartupPolicy` is unit-tested to only ever produce a curve; this is
/// the other half — the app must not *record* a manual choice in the first place.
@MainActor
@Suite("FanControlMemory — what survives a quit, and what must not")
struct FanControlMemoryTests {
    private func memory() -> (FanControlMemory, MemoryDefaults) {
        let store = MemoryDefaults()
        return (FanControlMemory(defaults: store), store)
    }

    private func curve(_ kind: FanCurve = .cold, persists: Bool = false) -> FanConfig {
        FanConfig(mode: .curve, persistsWithoutApp: persists, sharedCurve: kind)
    }

    @Test("A curve the daemon accepted comes back on the next launch")
    func curveRoundTrips() {
        let (m, _) = memory()
        m.remember(applied: curve())
        #expect(m.lastCurve?.sharedCurve == FanCurve.cold)
        #expect(m.storedPreference == .curve)
    }

    /// SAFETY INVARIANT. Manual is always watchdogged and is never the persisted
    /// default — so it must not reach storage at all, and it must not overwrite
    /// a curve the user had chosen earlier.
    @Test("Manual control is never written to storage, and never erases a curve")
    func manualIsNeverRemembered() {
        let (m, _) = memory()
        m.remember(applied: curve())
        m.remember(applied: FanConfig(mode: .manual, manualTargets: [0: 4000]))
        #expect(m.storedPreference == .curve, "the manual choice must not be recorded")
        #expect(m.lastCurve?.sharedCurve == FanCurve.cold, "nor may it wipe the curve")
    }

    /// "Never chose" and "chose Automatic" used to be indistinguishable, which
    /// is why auto now clears rather than records. A fresh install and a
    /// deliberate auto both land on the fallback curve, which is the intent.
    @Test("Auto forgets rather than recording an intent nothing can express")
    func autoForgets() {
        let (m, _) = memory()
        m.remember(applied: curve())
        m.remember(applied: FanConfig(mode: .auto))
        #expect(m.storedPreference == nil)
        #expect(m.lastCurve == nil)
    }

    /// The live toggle wins over whatever flag was stored with the curve —
    /// otherwise turning persistence off would not take effect until the user
    /// next applied a curve by hand.
    @Test("The persist toggle is read live, not restored from the stored copy")
    func persistPreferenceIsLive() {
        let (m, store) = memory()
        m.remember(applied: curve(persists: true))
        #expect(m.lastCurve?.persistsWithoutApp == false, "toggle is off, so the curve is not persisting")

        store.set(true, forKey: "persistCurve")
        #expect(m.lastCurve?.persistsWithoutApp == true)
    }

    /// Turning fan control off is a clean slate, not a pause: leaving either key
    /// behind lets a later re-enable resurrect a curve from a session the user
    /// has long forgotten.
    @Test("Turning fan control off forgets everything")
    func offMeansOff() {
        let (m, _) = memory()
        m.remember(applied: curve())
        m.forgetEverything()
        #expect(m.lastCurve == nil)
        #expect(m.storedPreference == nil)
    }

    @Test("A fresh install remembers nothing")
    func freshInstallIsEmpty() {
        let (m, _) = memory()
        #expect(m.lastCurve == nil)
        #expect(m.storedPreference == nil)
        #expect(!m.persistsCurveWithoutApp)
    }
}
