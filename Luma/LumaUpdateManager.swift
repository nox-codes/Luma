//
//  LumaUpdateManager.swift
//  Luma
//
//  Checks GitHub Releases for a newer version of Luma and surfaces it as
//  a card in the companion panel (Option C — GitHub API, no Sparkle).
//
//  Sparkle infrastructure (Options A/B) is wired but dormant:
//  - Info.plist SUFeedURL points to the correct Luma appcast
//  - startSparkleUpdater() in LumaApp.swift is ready to uncomment
//  - Activate by uncommenting that call once GitHub Actions is set up
//
//  Beta detection uses the `prerelease` field from the GitHub API AND
//  checks whether the release name contains "(Beta)" as a fallback.
//  Betas are always shown — the includeBetaUpdates toggle is wired in
//  UserDefaults but dormant until we're ready to filter.
//

import Combine
import Foundation

// MARK: - Data model

struct LumaReleaseInfo {
    /// Cleaned version string, e.g. "0.6.0" (leading "v" stripped).
    let version: String
    /// True when the GitHub release has prerelease=true OR name contains "(Beta)".
    let isBeta: Bool
    /// First non-empty line of the release body, used as the card subtitle.
    let subtitle: String
    /// Direct download URL for the first release asset (.dmg).
    let downloadURL: URL
    /// HTML URL of the release page on GitHub.
    let releasePageURL: URL
}

// MARK: - Manager

@MainActor
final class LumaUpdateManager: ObservableObject {

    static let shared = LumaUpdateManager()

    /// Non-nil when a newer, non-dismissed release is available.
    @Published private(set) var availableUpdate: LumaReleaseInfo?

    // MARK: - UserDefaults keys

    /// Tag name of the last version the user dismissed — suppresses re-showing that version.
    private let dismissedVersionKey = "luma_dismissed_update_version"

    // NOTE: The includeBetaUpdates preference is owned by CompanionPanelView via @AppStorage.
    // When filtering becomes active, read it here with:
    //   UserDefaults.standard.bool(forKey: "luma_include_beta_updates")

    // MARK: - Private state

    private let githubReleasesURL = URL(string: "https://api.github.com/repos/nox-codes/Luma/releases/latest")!
    /// 24-hour interval between background rechecks while the app stays open.
    private let recheckInterval: TimeInterval = 60 * 60 * 24
    private var recheckTimer: Timer?

    private init() {}

    // MARK: - Public API

    /// Call once on app launch (with a short delay so startup isn't blocked).
    func startChecking() {
        // Check 5 seconds after launch so the app is fully up before we hit the network.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { [weak self] in await self?.checkForUpdate() }
        }

        // Re-check every 24 hours for long-running sessions.
        recheckTimer = Timer.scheduledTimer(withTimeInterval: recheckInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.checkForUpdate() }
        }
    }

    /// Marks a version as dismissed — the card won't reappear for it.
    /// Called by the Dismiss button in the update card.
    func dismissUpdate(versionTag: String) {
        UserDefaults.standard.set(versionTag, forKey: dismissedVersionKey)
        availableUpdate = nil
        LumaLogger.log("[LumaUpdate] Dismissed update \(versionTag)")
    }

    // MARK: - Network check

    private func checkForUpdate() async {
        LumaLogger.log("[LumaUpdate] Checking GitHub for latest release…")

        var request = URLRequest(url: githubReleasesURL)
        // GitHub requires a User-Agent header; use the app bundle identifier.
        request.setValue("Luma-macOS/\(currentBundleVersion())", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                LumaLogger.log("[LumaUpdate] Non-HTTP response — skipping")
                return
            }
            guard httpResponse.statusCode == 200 else {
                LumaLogger.log("[LumaUpdate] GitHub API returned \(httpResponse.statusCode) — skipping")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            await processRelease(release)

        } catch {
            LumaLogger.log("[LumaUpdate] Check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Release processing

    @MainActor
    private func processRelease(_ release: GitHubRelease) async {
        let latestVersion = release.tagName.strippingLeadingV()
        let runningVersion = currentBundleVersion()

        LumaLogger.log("[LumaUpdate] Running \(runningVersion), latest on GitHub: \(latestVersion)")

        guard isVersion(latestVersion, newerThan: runningVersion) else {
            LumaLogger.log("[LumaUpdate] Already up to date")
            availableUpdate = nil
            return
        }

        // Don't re-show a version the user already dismissed.
        let dismissedVersion = UserDefaults.standard.string(forKey: dismissedVersionKey) ?? ""
        if dismissedVersion == release.tagName {
            LumaLogger.log("[LumaUpdate] Version \(release.tagName) was dismissed — skipping")
            return
        }

        // Beta detection: official prerelease flag OR "(Beta)" in the release name.
        let isBeta = release.prerelease || release.name.contains("(Beta)")

        // NOTE: includeBetaUpdates is dormant — we always show updates regardless.
        // When ready to activate filtering, add:
        //   guard !isBeta || includeBetaUpdates else { return }

        // Subtitle: first non-empty line of the release body.
        let subtitle = firstNonEmptyLine(of: release.body ?? "")

        // Download URL: first asset's browser_download_url, or the HTML release page as fallback.
        let releasePageURL = URL(string: release.htmlURL)!
        let downloadURL: URL
        if let firstAsset = release.assets.first, let assetURL = URL(string: firstAsset.browserDownloadURL) {
            downloadURL = assetURL
        } else {
            downloadURL = releasePageURL
        }

        LumaLogger.log("[LumaUpdate] Update available — \(release.tagName)\(isBeta ? " (Beta)" : "")")
        availableUpdate = LumaReleaseInfo(
            version: latestVersion,
            isBeta: isBeta,
            subtitle: subtitle,
            downloadURL: downloadURL,
            releasePageURL: releasePageURL
        )
    }

    // MARK: - Version comparison

    /// Returns true when `candidate` is semantically newer than `running`.
    /// Compares up to three dot-separated integer components (major.minor.patch).
    private func isVersion(_ candidate: String, newerThan running: String) -> Bool {
        let candidateParts = versionComponents(of: candidate)
        let runningParts   = versionComponents(of: running)

        for index in 0..<3 {
            let candidateComponent = index < candidateParts.count ? candidateParts[index] : 0
            let runningComponent   = index < runningParts.count   ? runningParts[index]   : 0
            if candidateComponent != runningComponent {
                return candidateComponent > runningComponent
            }
        }
        return false // equal versions — not newer
    }

    private func versionComponents(of versionString: String) -> [Int] {
        versionString
            .components(separatedBy: ".")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Helpers

    private func currentBundleVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Returns the first non-empty line of a multi-line string.
    /// Falls back to an empty string if the body is blank.
    private func firstNonEmptyLine(of text: String) -> String {
        text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
            ?? ""
    }
}

// MARK: - String helper

private extension String {
    /// Strips a leading "v" or "V" from a version tag (e.g. "v0.6.0" → "0.6.0").
    func strippingLeadingV() -> String {
        if first == "v" || first == "V" { return String(dropFirst()) }
        return self
    }
}

// MARK: - GitHub API response models

private struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    let body: String?
    let prerelease: Bool
    let htmlURL: String
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName   = "tag_name"
        case name
        case body
        case prerelease
        case htmlURL   = "html_url"
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case browserDownloadURL = "browser_download_url"
    }
}
