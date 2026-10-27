import Foundation

/// Trending and search results from GIPHY, for GIFs and stickers.
///
/// GIPHY needs an API key (free at developers.giphy.com). It can be built in
/// with the `GIPHYAPIKey` Info.plist entry, or pasted into Settings › Messages.
/// Only the search text, the content rating and the key are sent; DeskDrop sends
/// GIPHY no identifiers and no analytics.
struct GiphyClient: Sendable {
    enum Catalog: String, Sendable {
        case gifs
        case stickers
    }

    /// GIPHY's content ratings. DeskDrop is used at work, so G is the default.
    enum Rating: String, CaseIterable, Codable, Sendable, Identifiable {
        case g
        case pg
        case pg13 = "pg-13"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .g: String(localized: "G — suitable for everyone")
            case .pg: String(localized: "PG")
            case .pg13: String(localized: "PG-13")
            }
        }
    }

    /// One image GIPHY offers in a particular size.
    struct Rendition: Equatable, Sendable {
        let url: URL
        let width: Int
        let height: Int
    }

    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        /// A small version for the picker grid.
        let preview: Rendition
        /// The version that's sent.
        let full: Rendition
    }

    struct Page: Equatable, Sendable {
        let items: [Item]
        /// Where the next page starts, or nil at the end.
        let nextOffset: Int?
    }

    enum Failure: Error, Equatable {
        case missingKey
        /// GIPHY refused the key.
        case invalidKey
        case rateLimited
        case unavailable
        case malformed
    }

    let apiKey: String
    var session: URLSession = .giphy

    static let pageSize = 24

    /// The key built into this copy of DeskDrop, if any.
    static var bundledKey: String? {
        (Bundle.main.object(forInfoDictionaryKey: "GIPHYAPIKey") as? String)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
    }

    /// Trending when `query` is empty, otherwise search results.
    func page(_ catalog: Catalog, query: String, offset: Int = 0, rating: Rating) async throws -> Page {
        guard !apiKey.isEmpty else { throw Failure.missingKey }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.giphy.com"
        components.path = "/v1/\(catalog.rawValue)/\(trimmed.isEmpty ? "trending" : "search")"
        var items = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "rating", value: rating.rawValue),
            URLQueryItem(name: "bundle", value: "messaging_non_clips"),
        ]
        if !trimmed.isEmpty {
            items.append(URLQueryItem(name: "q", value: String(trimmed.prefix(50))))
            items.append(URLQueryItem(name: "lang", value: Locale.current.language.languageCode?.identifier ?? "en"))
        }
        components.queryItems = items
        guard let url = components.url else { throw Failure.malformed }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure.unavailable
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return try Self.decode(data, offset: offset)
        case 401, 403: throw Failure.invalidKey
        case 429: throw Failure.rateLimited
        default: throw Failure.unavailable
        }
    }

    // MARK: - Decoding

    private struct Response: Decodable {
        struct Image: Decodable {
            let url: String?
            let width: String?
            let height: String?
        }

        struct Entry: Decodable {
            let id: String
            let title: String?
            let images: [String: Image]
        }

        struct Pagination: Decodable {
            let total_count: Int?
            let count: Int?
            let offset: Int?
        }

        let data: [Entry]
        let pagination: Pagination?
    }

    /// Reads GIPHY's response, keeping only items with usable images on GIPHY's servers.
    static func decode(_ data: Data, offset: Int = 0) throws -> Page {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw Failure.malformed }
        func rendition(_ entry: Response.Entry, _ names: [String]) -> Rendition? {
            for name in names {
                guard let image = entry.images[name], let link = image.url, let url = URL(string: link),
                      ChatMedia.isGiphyMedia(url), url.absoluteString.utf8.count <= 512,
                      let width = image.width.flatMap(Int.init), let height = image.height.flatMap(Int.init),
                      (1...2048).contains(width), (1...2048).contains(height) else { continue }
                return Rendition(url: url, width: width, height: height)
            }
            return nil
        }
        let items = response.data.compactMap { entry -> Item? in
            guard entry.id.utf8.count <= 64,
                  let preview = rendition(entry, ["fixed_width_downsampled", "fixed_width", "fixed_width_small", "downsized"]),
                  let full = rendition(entry, ["downsized", "fixed_width", "original"]) else { return nil }
            return Item(id: entry.id, title: Self.cleanTitle(entry.title), preview: preview, full: full)
        }
        let count = response.pagination?.count ?? response.data.count
        let next = offset + count
        let total = response.pagination?.total_count ?? 0
        return Page(items: items, nextOffset: count > 0 && next < total ? next : nil)
    }

    /// GIPHY titles end in " GIF" or " Sticker", and sometimes "by someone".
    static func cleanTitle(_ title: String?) -> String {
        var text = (title ?? "").trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: " by ", options: .backwards) { text = String(text[..<range.lowerBound]) }
        for suffix in [" GIF", " Sticker"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        return String(text.prefix(120))
    }

    /// The message to send for a picked item.
    static func media(for item: Item, catalog: Catalog) -> ChatMedia {
        ChatMedia(kind: catalog == .stickers ? .sticker : .gif, url: item.full.url, hash: nil,
                  width: item.full.width, height: item.full.height, title: item.title, giphyID: item.id)
    }
}

extension URLSession {
    /// No cookies, no cache on disk (DeskDrop keeps its own), short timeouts.
    static let giphy: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
