// UpdateCheckerTests.swift — which release the update check offers, and the version compare underneath it.

import Foundation
import Testing

/// The update check had no tests at all, and shipped a defect that made it a
/// no-op for every user: it asked GitHub for `/releases/latest`, which excludes
/// prereleases, while every release this project publishes is one. The endpoint
/// 404ed, 404 was read as "nothing newer", and it reported *up to date* forever.
///
/// Nothing here touches the network. `UpdateChecker.offer(from:current:)` is
/// pure precisely so the decision that was wrong can be pinned in place.
@Suite("UpdateChecker — choosing what to offer")
struct UpdateCheckerTests {
    private func release(
        _ tag: String, draft: Bool = false, url: String? = nil
    ) -> UpdateChecker.Release {
        UpdateChecker.Release(
            tagName: tag,
            htmlURL: url ?? "https://github.com/thijsvos/icecube/releases/tag/\(tag)",
            draft: draft
        )
    }

    /// THE regression test. A prerelease is not a second-class release here —
    /// while the project is 0.x it is the only kind there is, and filtering
    /// them out is what made the previous implementation do nothing.
    @Test("A prerelease is still offered")
    func prereleaseIsOffered() {
        let offer = UpdateChecker.offer(from: [release("v0.1.2")], current: "0.1.1")
        #expect(offer?.version == "0.1.2")
    }

    @Test("A draft is never offered")
    func draftIsIgnored() {
        let offer = UpdateChecker.offer(
            from: [release("v0.2.0", draft: true), release("v0.1.2")], current: "0.1.1"
        )
        #expect(offer?.version == "0.1.2", "an unpublished draft is not an offer")
    }

    @Test("The running version is not offered to itself")
    func sameVersionIsNotAnUpdate() {
        #expect(UpdateChecker.offer(from: [release("v0.1.1")], current: "0.1.1") == nil)
    }

    @Test("An older release is not offered")
    func olderReleaseIsNotOffered() {
        #expect(UpdateChecker.offer(from: [release("v0.1.0")], current: "0.1.1") == nil)
    }

    @Test("No releases at all means nothing to offer")
    func emptyListIsUpToDate() {
        #expect(UpdateChecker.offer(from: [], current: "0.1.1") == nil)
    }

    /// GitHub returns newest-first, but a patch backported onto an old branch is
    /// published *after* a newer minor — so recency is the wrong tiebreak.
    @Test("The highest version wins, not the first in the list")
    func highestVersionWinsRegardlessOfOrder() {
        let offer = UpdateChecker.offer(
            from: [release("v0.1.2"), release("v0.9.0"), release("v0.2.0")], current: "0.1.1"
        )
        #expect(offer?.version == "0.9.0")
    }

    @Test("A tag without the v prefix still works")
    func bareTagIsAccepted() {
        #expect(UpdateChecker.offer(from: [release("0.2.0")], current: "0.1.1")?.version == "0.2.0")
    }

    /// A tampered or compromised API response must not be able to hand the app
    /// a link to anywhere but GitHub — this is the one place a remote server's
    /// words become something the user is invited to click.
    @Test(
        "Only https github.com links are offered",
        arguments: [
            "http://github.com/thijsvos/icecube/releases/tag/v0.2.0",
            "https://evil.example.com/releases/tag/v0.2.0",
            "file:///tmp/payload",
            "javascript:alert(1)",
        ]
    )
    func hostileURLsAreRejected(url: String) {
        let offer = UpdateChecker.offer(from: [release("v0.2.0", url: url)], current: "0.1.1")
        #expect(offer == nil, "offered a link to \(url)")
    }

    /// The defect was entirely a choice of URL, so the URL is what gets pinned.
    /// `/releases/latest` looks perfectly reasonable and silently excludes every
    /// release this project has ever made.
    @Test("The check lists releases rather than asking for the blessed one")
    func endpointListsReleases() {
        let url = UpdateChecker.releasesURL.absoluteString
        #expect(!url.contains("releases/latest"), "latest excludes prereleases — all of ours")
        #expect(url.contains("/releases?"))
        #expect(url.hasPrefix("https://api.github.com/repos/thijsvos/icecube/"))
    }

    /// A rejected URL must not take a legitimate release down with it.
    @Test("A bad link does not suppress a good one")
    func badLinkDoesNotBlockAGoodRelease() {
        let offer = UpdateChecker.offer(
            from: [release("v0.9.0", url: "file:///tmp/payload"), release("v0.2.0")],
            current: "0.1.1"
        )
        #expect(offer?.version == "0.2.0")
    }

    @Test("Real GitHub JSON decodes into the fields the decision uses")
    func decodesGitHubPayload() throws {
        let json = """
        [{"tag_name":"v0.1.1","html_url":"https://github.com/thijsvos/icecube/releases/tag/v0.1.1",
          "draft":false,"prerelease":true,"name":"Ice Cube 0.1.1"}]
        """
        let releases = try JSONDecoder().decode(
            [UpdateChecker.Release].self, from: Data(json.utf8)
        )
        #expect(releases.first?.tagName == "v0.1.1")
        #expect(releases.first?.draft == false)
        #expect(releases.first?.htmlURL.hasPrefix("https://github.com/") == true)
    }

    @Test(
        "Version compare is numeric, not lexicographic",
        arguments: [
            ("0.10.1", "0.9", true),
            ("0.9", "0.10.1", false),
            ("1.0", "0.99.99", true),
            ("0.1.1", "0.1.1", false),
            ("0.1.1", "0.1", true),
            ("0.1", "0.1.1", false),
        ]
    )
    func versionCompare(_ case: (newer: String, older: String, expected: Bool)) {
        #expect(UpdateChecker.isVersion(`case`.newer, newerThan: `case`.older) == `case`.expected)
    }

    // MARK: - Checking without being asked

    /// The object used to be a `@State` on the Settings window, so it did not
    /// exist unless somebody opened Settings. These pin the rule that replaced
    /// that: pure, so a day of elapsed time is a parameter rather than a wait.
    @Test("A Mac that has never checked is due")
    func neverCheckedIsDue() {
        #expect(UpdateChecker.isAutomaticCheckDue(lastChecked: nil, now: Date(), enabled: true))
    }

    @Test("Switching it off stops it, even when a check is long overdue")
    func disabledIsNeverDue() {
        let ancient = Date(timeIntervalSince1970: 0)
        #expect(!UpdateChecker.isAutomaticCheckDue(lastChecked: ancient, now: Date(), enabled: false))
        #expect(!UpdateChecker.isAutomaticCheckDue(lastChecked: nil, now: Date(), enabled: false))
    }

    /// Quitting and reopening four times in a morning must make one request,
    /// not four — GitHub allows 60 an hour per address, shared with everything
    /// else on it.
    @Test("A second launch the same day does not check again")
    func throttledWithinTheInterval() {
        let now = Date()
        let anHourAgo = now.addingTimeInterval(-3600)
        #expect(!UpdateChecker.isAutomaticCheckDue(lastChecked: anHourAgo, now: now, enabled: true))
    }

    @Test("A day later it is due again")
    func dueAfterTheInterval() {
        let now = Date()
        let stale = now.addingTimeInterval(-UpdateChecker.automaticInterval - 1)
        #expect(UpdateChecker.isAutomaticCheckDue(lastChecked: stale, now: now, enabled: true))
    }

    /// Clocks move backwards — on wake, and after a timezone change. Treating
    /// a future timestamp as "not due yet" would lock checks out until real
    /// time caught up, which for a badly-set clock can be years.
    @Test("A timestamp in the future is due, not a lockout")
    func clockWentBackwards() {
        let now = Date()
        let future = now.addingTimeInterval(60 * 60 * 24 * 365)
        #expect(UpdateChecker.isAutomaticCheckDue(lastChecked: future, now: now, enabled: true))
    }

    /// Opt-out, not opt-in. `bool(forKey:)` returns false for a key never
    /// written, so reading it that way would have shipped the feature off.
    @Test("Automatic checks default to on when nothing was ever stored")
    func defaultsToEnabled() {
        #expect(UpdateChecker(defaults: MemoryDefaults()).automaticChecksEnabled)
    }

    @Test("An explicit off survives a relaunch")
    func offIsRemembered() {
        let store = MemoryDefaults()
        let first = UpdateChecker(defaults: store)
        first.automaticChecksEnabled = false
        #expect(!UpdateChecker(defaults: store).automaticChecksEnabled)
    }
}
