// UpdateChecker.swift — the hand-rolled Sparkle replacement: GitHub Releases version check, link only.

import Foundation
import Observation

/// Checks the GitHub Releases API for a newer version. Deliberately minimal
/// (small-footprint rule: no auto-download, no auto-install, no framework):
/// one HTTPS GET, a version compare, and a link the user can click.
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

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
    }

    func check() async {
        status = .checking
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard http.statusCode != 404 else {
                // Repo not published or no releases yet — not an error state.
                status = .upToDate
                return
            }
            guard http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst())
                : release.tag_name
            if Self.isVersion(latest, newerThan: Self.currentVersion),
               let pageURL = URL(string: release.html_url),
               pageURL.scheme == "https", pageURL.host == "github.com"
            {
                // Only ever offer an https github.com link — a tampered API
                // response can't slip a file:// or custom-scheme URL past this.
                status = .available(version: latest, url: pageURL)
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed("Could not check for updates — are you online?")
        }
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
