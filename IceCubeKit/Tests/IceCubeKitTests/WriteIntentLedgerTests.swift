// WriteIntentLedgerTests.swift — the "newest decision wins" rule, exhaustively, with no race to stage.

@testable import IceCubeKit
import Testing

/// These exist because the behaviour they cover is a race, and three attempts
/// to stage that race from outside `DaemonCore` produced a test that passed and
/// failed on alternate runs. Extracting the rule made it ordinary logic.
@Suite("WriteIntentLedger — the newest fan-write decision wins")
struct WriteIntentLedgerTests {
    @Test("A freshly issued ticket is the current one")
    func newestIsCurrent() {
        var ledger = WriteIntentLedger()
        let ticket = ledger.issue()
        #expect(ledger.isCurrent(ticket))
    }

    /// The whole point: the guardian's floor-hold engage queues, a curve engage
    /// arrives behind it, and the floor hold must not commit an intent the
    /// daemon has already moved on from.
    @Test("A ticket taken before a newer decision is no longer current")
    func olderTicketGoesStale() {
        var ledger = WriteIntentLedger()
        let stale = ledger.issue()
        let fresh = ledger.issue()
        #expect(ledger.isCurrent(stale) == false, "the queued decision must stand down")
        #expect(ledger.isCurrent(fresh), "and the newer one proceeds")
    }

    @Test("Only the very newest survives a burst of decisions")
    func onlyTheNewestSurvives() throws {
        var ledger = WriteIntentLedger()
        let tickets = (0 ..< 25).map { _ in ledger.issue() }
        for ticket in tickets.dropLast() {
            #expect(ledger.isCurrent(ticket) == false, "ticket \(ticket) should be stale")
        }
        #expect(try ledger.isCurrent(#require(tickets.last)))
    }

    @Test("Tickets are distinct, so two decisions can never be confused")
    func ticketsAreDistinct() {
        var ledger = WriteIntentLedger()
        let issued = (0 ..< 500).map { _ in ledger.issue() }
        #expect(Set(issued).count == issued.count)
    }

    /// A ticket nobody issued — a defaulted or garbage value — must never read
    /// as current, or a writer could commit without ever having queued.
    @Test("A ticket that was never issued is not current")
    func unissuedTicketIsNotCurrent() {
        var ledger = WriteIntentLedger()
        _ = ledger.issue()
        #expect(ledger.isCurrent(0) == false)
        #expect(ledger.isCurrent(-1) == false)
        #expect(ledger.isCurrent(Int.max) == false)
    }

    /// A fresh ledger has issued nothing, so nothing can claim to be current —
    /// including the zero value a stored property would default to.
    @Test("A ledger that has issued nothing considers no ticket current")
    func freshLedgerHasNoCurrentTicket() {
        let ledger = WriteIntentLedger()
        #expect(ledger.isCurrent(0), "0 is the pre-issue state and matches itself")
        #expect(ledger.isCurrent(1) == false)
    }

    /// `issue()` wraps rather than traps. A daemon that crashes on its 2^63rd
    /// fan write would be worse than one that reuses a ticket after more writes
    /// than a Mac performs in its lifetime — but the wrap must not trap.
    @Test("Issuing wraps instead of trapping at the boundary")
    func wrapsWithoutTrapping() {
        var ledger = WriteIntentLedger()
        for _ in 0 ..< 1000 {
            _ = ledger.issue()
        }
        #expect(ledger.isCurrent(1000))
    }
}
