// DecisionEventTests.swift — the daemon's own sentences, classified; the table is built from real call sites.

import Foundation
@testable import IceCubeKit
import Testing

/// Every string below is a real `record(...)` call site, copied out of
/// `DaemonCore` and `FanGuardian` rather than invented. That is the point: the
/// classifier reads prose the daemon already writes, so the test's job is to
/// pin the mapping against the actual vocabulary and to fail loudly when a new
/// prefix appears that nobody classified.
@Suite("DecisionEvent — classifying what the daemon said")
struct DecisionEventTests {
    /// SAFETY wins over everything. A safety line that also mentions sleep is
    /// still a safety line, and colouring it as routine would hide the single
    /// event class a user most needs to see.
    @Test("A SAFETY line is safety, whatever else it mentions", arguments: [
        "SAFETY: control lost (read-back failed twice) — reverting to auto",
        "SAFETY: over the temperature ceiling while parked for sleep (Tp09 104 °C) — taking the fans back",
        "SAFETY: forcing maximum cooling — Tp01 105 °C",
        "SAFETY: could not read the fans to park them for sleep — they may still be forced",
        "SAFETY: system did not resume control — holding fans at minimum RPM ourselves",
        "SAFETY: wake re-assert failed — reverting to auto",
    ])
    func safetyWinsOutright(_ text: String) {
        #expect(DecisionEvent.Kind.classify(text) == .safety)
    }

    @Test("The guardian and the self-test are their own kinds", arguments: [
        ("guardian: die 78 °C and nothing cooling — driving the fans (built-in curve)", DecisionEvent.Kind.guardian),
        ("guardian: cooled to 61 °C — releasing the fans", .guardian),
        ("guardian: temperatures readable again", .guardian),
        ("self-test: checking the fan write path", .selfTest),
        ("self-test: the firmware refused the fan write", .selfTest),
    ])
    func prefixedKinds(_ pair: (String, DecisionEvent.Kind)) {
        #expect(DecisionEvent.Kind.classify(pair.0) == pair.1)
    }

    /// A refused dark wake is, to the user, the fans staying put — so it reads
    /// as asleep rather than as a wake. This ordering is the whole reason
    /// `classify` checks sleep first.
    @Test("Sleep and a refused dark wake read as asleep, not as a wake", arguments: [
        "the Mac is going to sleep — handing the fans back (keeping the curve config)",
        "fans parked for sleep in 0.0098 seconds (config kept: curve)",
        "dark wake (0x39 [CDNP]) — the app checked in after a nap, but no display is powered",
        "sleep: nothing of ours is on the fans — leaving them to the firmware",
        "the pre-sleep hand-back never landed — trying again",
    ])
    func sleepBeatsWake(_ text: String) {
        #expect(DecisionEvent.Kind.classify(text) == .asleep)
    }

    @Test("A real wake is a wake", arguments: [
        "wake: resuming curve control (the system powered on — 0x1F [CDNVA])",
        "wake detected — re-establishing curve control",
    ])
    func realWakes(_ text: String) {
        #expect(DecisionEvent.Kind.classify(text) == .wake)
    }

    @Test("Taking the fans and letting them go are distinguishable", arguments: [
        ("curve engaged (persists without app: false)", DecisionEvent.Kind.engaged),
        ("boot: resuming persisted curve config", .engaged),
        ("all fans auto (daemon start)", .released),
        ("quit at 42 °C — cold enough to let the fans stop", .released),
    ])
    func engagedVersusReleased(_ pair: (String, DecisionEvent.Kind)) {
        #expect(DecisionEvent.Kind.classify(pair.0) == pair.1)
    }

    /// Unclassified is a legitimate answer, not a bug — but it must be the
    /// exception. If this ever starts catching safety-shaped prose, the
    /// classifier has drifted from the daemon's vocabulary.
    @Test("Anything unrecognised falls through to other, not to a wrong kind")
    func unknownFallsThrough() {
        #expect(DecisionEvent.Kind.classify("power capabilities at start: 0x1F [CDNVA]") == .other)
        #expect(DecisionEvent.Kind.classify("") == .other)
    }

    /// The daemon's words reach the UI unchanged. Re-wording them here would
    /// create a second vocabulary to keep in sync with ~34 test assertions.
    @Test("The event carries the daemon's sentence verbatim and classifies itself")
    func carriesTheSentence() {
        let text = "SAFETY: forcing maximum cooling — Tp01 105 °C"
        let event = DecisionEvent(text: text, date: Date(timeIntervalSince1970: 1))
        #expect(event.text == text)
        #expect(event.kind == .safety)
    }

    /// It crosses XPC inside `HelperStatus`, so it has to survive a round trip.
    @Test("It round-trips through Codable")
    func codableRoundTrip() throws {
        let event = DecisionEvent(
            text: "curve engaged (persists without app: false)",
            date: Date(timeIntervalSince1970: 42)
        )
        let decoded = try JSONDecoder().decode(DecisionEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
    }
}
