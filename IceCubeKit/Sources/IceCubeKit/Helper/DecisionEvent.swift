// DecisionEvent.swift — one thing the daemon decided, when it decided it, and what kind of decision it was.

import Foundation

/// A single entry in the daemon's decision log, timestamped and classified.
///
/// The daemon has always explained itself: every meaningful decision goes
/// through `DaemonCore.record()` in plain prose, and those sentences are the
/// most useful thing in the system for answering "why did my fans just do
/// that". Until now they went into `HelperStatus.recentEvents` as bare strings,
/// crossed XPC, and were dropped on the floor by the app — computed, tested,
/// transported, and never shown to anyone who could read them.
///
/// This adds the two things a string cannot carry: **when** it happened, so it
/// can be drawn on the same time axis as the charts, and **what kind** of
/// decision it was, so a ceiling trip can be coloured differently from a
/// routine engage.
///
/// The `text` is the daemon's own sentence, unchanged. That is deliberate:
/// those sentences were written to be read by a human debugging a real
/// incident, they are already asserted in ~34 places in `DaemonCoreTests`, and
/// re-wording them in the UI would create a second vocabulary to keep in sync.
public struct DecisionEvent: Sendable, Codable, Equatable, Identifiable {
    /// What sort of decision this was, for colour and filtering.
    ///
    /// Derived once, where the event is created, from the daemon's own prose —
    /// never re-parsed in a view. The prefixes this matches (`SAFETY:`,
    /// `guardian:`, `self-test:`, `boot:`) are conventions the daemon has used
    /// consistently since Phase 3, and ``classify(_:)`` is pinned by a test
    /// table built from the real call sites so a new prefix cannot silently
    /// land in ``other``.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// A safety rule fired: the ceiling, a revert, a lost read-back.
        case safety
        /// `FanGuardian` acted because macOS was not cooling a hot machine.
        case guardian
        /// The daemon took the fans: a curve or manual config engaged.
        case engaged
        /// The daemon let the fans go back to the firmware.
        case released
        /// The fans are with the firmware because the Mac is asleep, parked, or
        /// in a dark wake we refused to treat as a wake.
        case asleep
        /// The daemon took control back after a real wake.
        case wake
        /// The write-path self-test.
        case selfTest
        /// Anything else the daemon had to say.
        case other

        /// Classifies one of the daemon's sentences.
        ///
        /// **Order is load-bearing.** `SAFETY:` wins over everything — a safety
        /// line that mentions sleep is still a safety line, and colouring it as
        /// routine would hide the one event class the user most needs to see.
        /// Sleep is checked before wake because "dark wake … the fans stay with
        /// the firmware" is, to a user, the fans staying put — not a wake.
        public static func classify(_ text: String) -> Kind {
            let lower = text.lowercased()
            if lower.hasPrefix("safety:") {
                return .safety
            }
            if lower.hasPrefix("guardian:") {
                return .guardian
            }
            if lower.hasPrefix("self-test:") {
                return .selfTest
            }
            // Sleep before wake: a refused dark wake leaves the fans alone.
            if lower.contains("parked for sleep") || lower.contains("going to sleep")
                || lower.hasPrefix("sleep:") || lower.contains("dark wake")
                || lower.contains("hand-back never landed")
            {
                return .asleep
            }
            if lower.hasPrefix("wake") || lower.contains("wake detected") {
                return .wake
            }
            if lower.contains("engaged") || lower.hasPrefix("boot: resuming")
                || lower.contains("re-asserting")
            {
                return .engaged
            }
            if lower.hasPrefix("all fans auto") || lower.contains("let the fans stop")
                || lower.contains("leaving the fans to macos") || lower.contains("leaving them to macos")
            {
                return .released
            }
            return .other
        }
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    /// The daemon's own words, verbatim.
    public let text: String

    public init(id: UUID = UUID(), date: Date, kind: Kind, text: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
    }

    /// Builds an event from a daemon sentence, classifying it.
    public init(text: String, date: Date) {
        self.init(id: UUID(), date: date, kind: Kind.classify(text), text: text)
    }
}
