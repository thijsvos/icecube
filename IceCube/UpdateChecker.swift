// UpdateChecker.swift — the hand-rolled Sparkle replacement: GitHub Releases version check, link only.

import Foundation
import Observation

/// Checks the GitHub Releases API for a newer version. Deliberately minimal
/// (small-footprint rule: no auto-download, no auto-install, no framework):
/// one HTTPS GET, a version compare, and a link the user can click.
///
/// **It lists releases rather than asking for `/releases/latest`,** which is
/// not a stylistic choice. `latest` excludes prereleases, and every release
/// this project has published is a prerelease on purpose — a 0.x unsigned
/// build is not something to hand people as "latest", and GitHub refuses to
/// apply that flag to a prerelease anyway. So `latest` returned 404, 404 was
/// read as "nothing newer", and the check reported *up to date* forever, to
/// everyone, whatever was shipped. It said nothing while doing it.
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// The repository the app was released from (owner/name).
    static let repository = "thijsvos/icecube"

    /// The running app's marketing version.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// One entry from the releases list — only the three fields that decide
    /// anything.
    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlURL: String
        /// Unpublished. Never offered: a draft is a work in progress, not an
        /// offer, and its assets may not exist yet.
        let draft: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
        }

        init(tagName: String, htmlURL: String, draft: Bool = false) {
            self.tagName = tagName
            self.htmlURL = htmlURL
            self.draft = draft
        }
    }

    /// How many releases to consider. The newest is almost always first, but
    /// the version compare below decides rather than the ordering, so a
    /// backported patch published after a newer minor cannot win by recency.
    private static let pageSize = 20

    /// The endpoint, as its own value so a test can pin it.
    ///
    /// Worth pinning because the defect this replaced was *entirely* a choice of
    /// URL: `/releases/latest` is a perfectly reasonable-looking request that
    /// silently excludes every release this project has ever made.
    static var releasesURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=\(pageSize)")!
    }

    /// Performs the HTTP request. Injectable so `check()` is reachable without a
    /// network.
    ///
    /// All of `check()` was untestable before this: the branch that decides
    /// whether a user is told about an update was welded to `URLSession.shared`,
    /// which does not reliably honour `URLProtocol.registerClass`, so there was
    /// no back door either. That is the same function whose endpoint choice
    /// caused #12 — "up to date" reported to everyone, forever.
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let fetch: Fetch

    /// The running app's version, injectable for a reason that is easy to miss:
    /// `IceCubeTests` is a host-less bundle, so `Bundle.main` is the xctest
    /// runner and ``currentVersion`` degrades to `"0"` — under which *every*
    /// release looks newer and an "is this update offered?" test would pass no
    /// matter what the comparison did.
    private let version: String

    init(
        fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) },
        version: String = UpdateChecker.currentVersion
    ) {
        self.fetch = fetch
        self.version = version
    }

    func check() async {
        status = .checking
        do {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard http.statusCode != 404 else {
                // The repo is private or has no releases. Genuinely nothing to
                // offer — unlike the 404 this endpoint replaced, which meant
                // "there are releases, just none GitHub calls latest".
                status = .upToDate
                return
            }
            guard http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let releases = try JSONDecoder().decode([Release].self, from: data)
            if let offer = Self.offer(from: releases, current: version) {
                status = .available(version: offer.version, url: offer.url)
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed("Could not check for updates — are you online?")
        }
    }

    /// The release to offer, or nil when the running build is current.
    ///
    /// Pure, so the selection rules are testable without a network: the bug
    /// this replaced was in exactly this decision and was invisible from the
    /// outside.
    ///
    /// Prereleases are eligible **on purpose.** While the project is 0.x they
    /// are the only releases there are, and filtering them out is what made
    /// the previous implementation a no-op.
    static func offer(from releases: [Release], current: String) -> (version: String, url: URL)? {
        var best: (version: String, url: URL)?
        for release in releases where !release.draft {
            let version = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName
            guard isVersion(version, newerThan: current) else { continue }
            // Only ever offer an https github.com link — a tampered API
            // response can't slip a file:// or custom-scheme URL past this.
            guard let pageURL = URL(string: release.htmlURL),
                  pageURL.scheme == "https", pageURL.host == "github.com"
            else { continue }
            if best == nil || isVersion(version, newerThan: best!.version) {
                best = (version, pageURL)
            }
        }
        return best
    }

    /// Numeric semver-ish comparison: `"0.10.1" > "0.9"`.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y {
                return x > y
            }
        }
        return false
    }
}
