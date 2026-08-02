// WritePathReportTests.swift — the sentence a user reads when their Mac cannot drive its fans.

import Foundation
@testable import IceCubeKit
import Testing

/// `summary` measured 0% covered: nothing in either suite referenced it, and
/// its only consumer is the Settings pane, which is not unit-testable.
///
/// It is display text rather than behaviour, so nothing here can cook a Mac.
/// It earns a suite anyway because it is a `switch` over a `Verdict` with two
/// data-dependent branches inside it — the shape a sixth case breaks silently —
/// and because this is the string someone quotes when filing the new-model
/// report that is the project's only route onto unmapped hardware.
@Suite("WritePathReport — what it tells the user")
struct WritePathReportTests {
    private func report(_ verdict: WritePathReport.Verdict, unlock: String? = nil, detail: String? = nil)
        -> WritePathReport
    {
        WritePathReport(
            verdict: verdict,
            unlockBranch: unlock,
            modelIdentifier: "Mac14,9",
            osVersion: "26.4",
            testedAt: Date(timeIntervalSince1970: 1_753_000_000),
            detail: detail
        )
    }

    @Test("A verified write path says so plainly, without mentioning an unlock it did not need")
    func verifiedIsPlain() {
        let summary = report(.verified, unlock: "direct").summary
        #expect(summary.contains("works"))
        #expect(!summary.contains("Ftst"), "a direct-mode Mac must not be told about an unlock branch it never took")
    }

    /// The one branch inside `.verified`. Worth its own case because the
    /// `Ftst` unlock is generation-specific, and knowing a machine needed it is
    /// exactly what a new-model report is for.
    @Test("A Mac that needed the Ftst unlock is told, because that fact belongs in a bug report")
    func verifiedNamesTheUnlockWhenOneWasNeeded() {
        #expect(report(.verified, unlock: "ftst").summary.contains("Ftst"))
    }

    @Test("A refusal separates fan control from monitoring, which still works")
    func rejectedKeepsMonitoring() {
        let summary = report(.rejected).summary
        #expect(summary.contains("refused"))
        #expect(summary.lowercased().contains("monitoring"), "the user must know they did not lose everything")
    }

    /// The verdict the project most wants reported — writes accepted and then
    /// ignored, which looks like success from every angle except the fans.
    @Test("The silent-failure verdict asks to be reported")
    func notVerifiedAsksForAReport() {
        #expect(report(.notVerified).summary.lowercased().contains("report"))
    }

    @Test("A fanless Mac is told that is normal, not that something failed")
    func noUsableFansIsNotAFailure() {
        let summary = report(.noUsableFans).summary
        #expect(summary.lowercased().contains("no controllable fans"))
        #expect(summary.lowercased().contains("monitoring"))
    }

    /// `.unavailable` is the only verdict that hands the firmware's own words
    /// to the user, and the only one with a fallback when there are none.
    @Test("An unavailable check prefers the firmware's own words over canned text")
    func unavailablePrefersTheDetail() {
        #expect(report(.unavailable, detail: "The SMC was busy.").summary == "The SMC was busy.")
    }

    @Test("An unavailable check with nothing to say still says something useful")
    func unavailableFallsBackWhenThereIsNoDetail() {
        let summary = report(.unavailable).summary
        #expect(!summary.isEmpty)
        #expect(summary.lowercased().contains("again"), "a transient failure should invite a retry")
    }

    /// Cheap guard on the shape rather than the wording: every verdict must
    /// produce a non-empty sentence, so a future case cannot ship blank.
    @Test("Every verdict produces a sentence", arguments: WritePathReport.Verdict.allCases)
    func everyVerdictSpeaks(verdict: WritePathReport.Verdict) {
        #expect(!report(verdict).summary.isEmpty)
    }
}
