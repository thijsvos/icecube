// UpdateCheckerCheckTests.swift — what the update check tells the user for each answer GitHub can give.

import Foundation
import IceCubeKit
import Testing

/// `check()` was the whole of `UpdateChecker`'s uncovered surface, and it was
/// uncovered because it was welded to `URLSession.shared`.
///
/// It deserves tests more than most: the defect it replaced (#12) was entirely
/// a decision inside this function — reading `/releases/latest`, which excludes
/// prereleases, so an app whose every release is a prerelease told every user
/// "up to date", forever, and nothing failed. The status-code branches below
/// are the descendants of that bug.
@MainActor
@Suite("UpdateChecker.check — every answer GitHub can give")
struct UpdateCheckerCheckTests {
    /// `nonisolated`, and built from a literal URL rather than
    /// `UpdateChecker.releasesURL`: the injected fetch is `@Sendable` and
    /// escapes the main actor, so anything it captures must too.
    private nonisolated static func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com/repos/thijsvos/icecube/releases")!,
            statusCode: code, httpVersion: nil, headerFields: nil
        )!
    }

    private func checker(
        status code: Int = 200,
        body: Data = Data("[]".utf8),
        version: String = "0.1.0"
    ) -> UpdateChecker {
        let canned = Self.response(code)
        return UpdateChecker(fetch: { _ in (body, canned) }, version: version)
    }

    private func releases(_ tags: [String]) -> Data {
        let items = tags.map {
            ["tag_name": $0, "html_url": "https://github.com/thijsvos/icecube/releases/tag/\($0)", "draft": false]
                as [String: Any]
        }
        return try! JSONSerialization.data(withJSONObject: items)
    }

    @Test("A newer release is offered, with its version and link")
    func newerReleaseIsOffered() async {
        let checker = checker(body: releases(["v0.2.0"]), version: "0.1.0")
        await checker.check()
        guard case let .available(version, url) = checker.status else {
            Issue.record("expected an offer, got \(checker.status)")
            return
        }
        #expect(version == "0.2.0")
        #expect(url.host == "github.com")
    }

    @Test("An empty releases list is up to date, not an error")
    func emptyListIsUpToDate() async {
        let checker = checker(body: releases([]))
        await checker.check()
        #expect(checker.status == .upToDate)
    }

    @Test("A release older than the running build is not offered")
    func olderReleaseIsNotOffered() async {
        let checker = checker(body: releases(["v0.0.9"]), version: "0.1.0")
        await checker.check()
        #expect(checker.status == .upToDate)
    }

    /// The literal status code the old bug misread. Here 404 means the repo is
    /// private or has no releases at all — genuinely nothing to offer — as
    /// opposed to `/releases/latest`'s 404, which meant "there are releases,
    /// just none GitHub is willing to call latest".
    @Test("A 404 means there is nothing to offer, not that the check failed")
    func notFoundIsUpToDate() async {
        let checker = checker(status: 404)
        await checker.check()
        #expect(checker.status == .upToDate, "404 from the list endpoint is an empty answer, not a failure")
    }

    @Test(
        "Any other HTTP status is reported as a failure rather than silently passing",
        arguments: [403, 500, 301, 418]
    )
    func otherStatusCodesFail(code: Int) async {
        let checker = checker(status: code)
        await checker.check()
        guard case .failed = checker.status else {
            Issue.record("HTTP \(code) should not read as success; got \(checker.status)")
            return
        }
    }

    @Test("A response that is not HTTP at all fails rather than crashing")
    func nonHTTPResponseFails() async throws {
        let bare = try URLResponse(
            url: #require(URL(string: "https://api.github.com/repos/thijsvos/icecube/releases")),
            mimeType: nil, expectedContentLength: 0, textEncodingName: nil
        )
        let checker = UpdateChecker(fetch: { _ in (Data(), bare) }, version: "0.1.0")
        await checker.check()
        guard case .failed = checker.status else {
            Issue.record("expected failure, got \(checker.status)")
            return
        }
    }

    @Test("Malformed JSON fails rather than being read as an empty list")
    func malformedJSONFails() async {
        let checker = checker(body: Data("{ this is not a releases array }".utf8))
        await checker.check()
        guard case .failed = checker.status else {
            Issue.record("a decode failure must not masquerade as 'up to date'; got \(checker.status)")
            return
        }
    }

    @Test("A transport error fails rather than throwing out of check()")
    func transportErrorFails() async {
        let checker = UpdateChecker(fetch: { _ in throw URLError(.notConnectedToInternet) }, version: "0.1.0")
        await checker.check()
        guard case .failed = checker.status else {
            Issue.record("expected failure, got \(checker.status)")
            return
        }
    }

    /// **Documented, not fixed.** The catch in `check()` is total, so a GitHub
    /// rate-limit and a malformed payload both tell a demonstrably-online user
    /// "are you online?". Pinned so the wording cannot drift without someone
    /// deciding to, and so the imprecision is on the record.
    @Test("Every failure currently shares one message, including ones that are not connectivity")
    func failureMessageIsCurrentlyUndifferentiated() async {
        let rateLimited = checker(status: 403)
        let malformed = checker(body: Data("nonsense".utf8))
        await rateLimited.check()
        await malformed.check()
        #expect(rateLimited.status == malformed.status, "today these are indistinguishable to the user")
        if case let .failed(message) = rateLimited.status {
            #expect(message.contains("online"))
        }
    }

    @Test("A draft is never offered even when it is the newest thing published")
    func draftIsNotOffered() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            [
                "tag_name": "v9.9.9",
                "html_url": "https://github.com/thijsvos/icecube/releases/tag/v9.9.9",
                "draft": true,
            ] as [String: Any],
        ])
        let checker = checker(body: body, version: "0.1.0")
        await checker.check()
        #expect(checker.status == .upToDate)
    }
}

/// The comparison's *contract*, as opposed to its arithmetic.
///
/// `UpdateCheckerTests.versionCompare` already pins six ordering cases and they
/// are correct. What nothing pinned is what `isVersion` assumes about its
/// input — which matters because every Ice Cube release is a prerelease, so the
/// tag shapes below are not hypothetical.
@Suite("UpdateChecker.isVersion — the contract, not just the ordering")
struct UpdateCheckerVersionContractTests {
    /// Multi-digit components compare numerically, not lexically. `"0.1.10"`
    /// sorts before `"0.1.9"` as a string; the release after v0.1.9 must still
    /// be offered.
    @Test("A two-digit patch is newer than a one-digit one")
    func twoDigitPatch() {
        #expect(UpdateChecker.isVersion("0.1.10", newerThan: "0.1.9"))
        #expect(!UpdateChecker.isVersion("0.1.9", newerThan: "0.1.10"))
    }

    /// **Documents a real constraint, not a bug being fixed.** `isVersion`
    /// requires pre-stripped input — the `v` is removed by `offer`, and both of
    /// its call sites hand over bare numbers. Feed it a raw tag and `Int("v0")`
    /// silently yields 0, so `v1.0.0` reads as older than `0.9`.
    ///
    /// Unreachable through `offer` today. Pinned so that if anyone ever calls
    /// `isVersion` with a tag directly, this test tells them why it went wrong.
    @Test("It requires a stripped version — a raw v-prefixed tag parses as zeroes")
    func vPrefixIsNotHandledHere() {
        #expect(
            !UpdateChecker.isVersion("v1.0.0", newerThan: "0.9"),
            "contract: strip the tag before comparing; `offer` does this and `isVersion` does not"
        )
        #expect(UpdateChecker.isVersion("1.0.0", newerThan: "0.9"), "stripped, the same comparison is correct")
    }

    /// Every release this project ships is a prerelease, so suffixed tags are
    /// the likely future. Both directions are currently surprising:
    /// `0.2.0-rc1` reads as *equal* to `0.2.0` and is therefore never offered,
    /// while `0.2.0-beta.1` gains a fourth component and reads as *newer*.
    ///
    /// Recorded rather than corrected — changing it is a release-naming
    /// decision. If a suffixed tag is ever cut, this suite is where the
    /// behaviour was written down.
    @Test("Non-numeric suffixes are parsed loosely, in both directions")
    func prereleaseSuffixes() {
        #expect(
            !UpdateChecker.isVersion("0.2.0-rc1", newerThan: "0.2.0"),
            "a -rc suffix is dropped, so the tag reads as equal and is never offered"
        )
        #expect(
            UpdateChecker.isVersion("0.2.0-beta.1", newerThan: "0.2.0"),
            "but a dotted suffix adds a component, so this one reads as newer"
        )
    }

    @Test("An empty or junk version is treated as zero rather than crashing")
    func junkIsZero() {
        #expect(UpdateChecker.isVersion("0.1.0", newerThan: ""))
        #expect(!UpdateChecker.isVersion("", newerThan: "0.1.0"))
        #expect(!UpdateChecker.isVersion("", newerThan: ""))
    }
}
