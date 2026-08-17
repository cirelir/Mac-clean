import Foundation

/// Result of an update check.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case updateAvailable(version: String, releaseURL: URL)
    /// Network failure, missing release, or unparseable response —
    /// callers should treat this as "could not determine" and stay silent.
    case failed
}

/// Checks GitHub Releases for the latest version of Mac Clean.
///
/// The repository publishes tagged releases (e.g. "v0.2.0"); the tag name
/// is compared against `AppVersion.current` with `VersionComparator`.
public actor UpdateChecker {
    private struct GitHubRelease: Decodable, Sendable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private let repositoryPath: String
    private let session: URLSession

    public init(
        repositoryPath: String = "cirelir/Mac-clean",
        session: URLSession = .shared
    ) {
        self.repositoryPath = repositoryPath
        self.session = session
    }

    public func checkLatestVersion() async -> UpdateCheckResult {
        guard
            let url = URL(
                string: "https://api.github.com/repos/\(repositoryPath)/releases/latest"
            )
        else {
            return .failed
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MacClean/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return .failed
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = VersionComparator.displayVersion(release.tagName)
            if VersionComparator.compare(AppVersion.current, release.tagName) == .orderedAscending {
                return .updateAvailable(version: latest, releaseURL: release.htmlURL)
            }
            return .upToDate
        } catch {
            return .failed
        }
    }
}
