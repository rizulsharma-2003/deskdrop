import Foundation

/// The newest DeskDrop on an update feed: its version and where its signed
/// `.deskdropupdate` package is.
struct FeedRelease: Equatable, Sendable {
    let version: String
    let packageURL: URL
    let size: Int64
    let pageURL: URL?
}

/// Somewhere DeskDrop looks for updates besides nearby Macs.
protocol UpdateFeed: Sendable {
    /// The latest release, or nil if there isn't one with an update package.
    func latest() async throws -> FeedRelease?
    /// Downloads a release's package to a temporary file, which the caller moves.
    func download(_ release: FeedRelease) async throws -> URL
}

/// GitHub Releases of the repository named in Info.plist (`DeskDropUpdateRepository`,
/// from Config/DeskDrop.xcconfig). `scripts/publish-release.sh` attaches each
/// version's signed `.deskdropupdate` to its release. Nothing is trusted because
/// it came from GitHub: the package is checked against the publisher's key like
/// one from a colleague. Only the repository's public release list and the file
/// are fetched, without any identifier.
struct GitHubReleases: UpdateFeed {
    enum Failure: Error, Equatable {
        case unavailable
        case rateLimited
        case malformed
        case tooLarge
    }

    let repository: String
    var session: URLSession = .updates

    /// "owner/name", letters, digits, '-', '_' and '.' only.
    static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 100 && part != "." && part != ".."
                && part.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        }
    }

    func latest() async throws -> FeedRelease? {
        guard Self.isValidRepository(repository),
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { throw Failure.malformed }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try Self.decode(data, repository: repository)
        case 404: return nil
        case 403, 429: throw Failure.rateLimited
        default: throw Failure.unavailable
        }
    }

    func download(_ release: FeedRelease) async throws -> URL {
        guard release.size <= UpdatePackage.maxArchiveBytes + 64_000 else { throw Failure.tooLarge }
        var request = URLRequest(url: release.packageURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let (file, response) = try await session.download(for: request)
        // The download is deleted when this returns, so it's moved first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("feed-\(UUID().uuidString).\(UpdatePackage.fileExtension)")
        try FileManager.default.moveItem(at: file, to: kept)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: kept)
            throw Failure.unavailable
        }
        return kept
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64
        }

        let tag_name: String
        let html_url: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// Reads GitHub's answer: the version from the tag ("v1.8.0"), and the
    /// `.deskdropupdate` asset, which must be a download from this repository.
    static func decode(_ data: Data, repository: String) throws -> FeedRelease? {
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else { throw Failure.malformed }
        guard release.draft != true, release.prerelease != true else { return nil }
        let tag = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard AppVersion(tag) != nil else { return nil }
        let prefix = "/\(repository)/releases/download/".lowercased()
        let asset = release.assets.first { asset in
            guard asset.name.hasSuffix(".\(UpdatePackage.fileExtension)"), let url = URL(string: asset.browser_download_url) else {
                return false
            }
            return url.scheme == "https" && url.host?.lowercased() == "github.com" && url.path.lowercased().hasPrefix(prefix)
        }
        guard let asset, let url = URL(string: asset.browser_download_url) else { return nil }
        return FeedRelease(version: tag, packageURL: url, size: asset.size,
                           pageURL: release.html_url.flatMap(URL.init(string:)))
    }

    /// The repository built into this copy of DeskDrop, if any.
    static var bundled: GitHubReleases? {
        guard let repository = Bundle.main.object(forInfoDictionaryKey: "DeskDropUpdateRepository") as? String,
              isValidRepository(repository) else { return nil }
        return GitHubReleases(repository: repository)
    }
}

extension URLSession {
    /// For update checks and downloads: no cookies or cache, and patient with big files.
    static let updates: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()
}
