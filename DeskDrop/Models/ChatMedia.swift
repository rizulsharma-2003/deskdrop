import Foundation

/// A GIF or sticker sent as a message instead of text.
///
/// GIFs and GIPHY stickers travel as a GIPHY media link; each Mac downloads the
/// image from GIPHY itself, and only from GIPHY. Stickers you made yourself have
/// no link: they travel between Macs by content hash (see `MediaExchange`).
struct ChatMedia: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case gif
        case sticker
        /// Something a newer DeskDrop sends; shown as its fallback text.
        case unknown

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    let kind: Kind
    /// GIPHY media link, for GIFs and GIPHY stickers.
    var url: URL?
    /// SHA-256 (lowercase hex) of a sticker image carried between Macs.
    var hash: String?
    /// Pixel size, so the message is laid out before the image loads.
    let width: Int
    let height: Int
    /// GIPHY's title, for VoiceOver and the fallback text.
    var title: String?
    /// GIPHY's ID, for "Open on GIPHY".
    var giphyID: String?

    /// The GIPHY page for this GIF or sticker.
    var giphyPage: URL? {
        guard let giphyID else { return nil }
        return URL(string: "https://giphy.com/\(kind == .sticker ? "stickers" : "gifs")/\(giphyID)")
    }

    /// What older DeskDrop versions (and previews) show instead of the image.
    var fallbackText: String {
        let label = kind == .sticker ? String(localized: "Sticker") : String(localized: "GIF")
        guard let page = giphyPage else { return "[\(label)]" }
        let name = title.map { $0.isEmpty ? "" : "\($0) " } ?? ""
        return "\(label): \(name)\(page.absoluteString)"
    }

    /// GIPHY's media servers. Nothing else is ever downloaded for a message.
    static let giphyHosts: Set<String> = ["i.giphy.com", "media.giphy.com", "media0.giphy.com", "media1.giphy.com",
                                          "media2.giphy.com", "media3.giphy.com", "media4.giphy.com"]

    static func isGiphyMedia(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return giphyHosts.contains(host) && url.user == nil && url.port == nil
    }

    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A cleaned copy, or nil if the media can't be shown safely.
    func validated() -> ChatMedia? {
        guard kind != .unknown, (1...2048).contains(width), (1...2048).contains(height) else { return nil }
        let cleanURL = url.flatMap { Self.isGiphyMedia($0) && $0.absoluteString.utf8.count <= 512 ? $0 : nil }
        let cleanHash = hash.flatMap { Self.isHash($0) ? $0 : nil }
        // Exactly one source: a GIPHY link, or (for stickers) an image carried by hash.
        switch (cleanURL, cleanHash) {
        case (_?, nil): break
        case (nil, _?) where kind == .sticker: break
        default: return nil
        }
        let cleanID = giphyID.flatMap { id in
            id.utf8.count <= 64 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } ? id : nil
        }
        let cleanTitle = title.flatMap(ChatValidator.sanitizeText).map { String($0.prefix(120)) }
        return ChatMedia(kind: kind, url: cleanURL, hash: cleanHash, width: width, height: height,
                         title: cleanTitle, giphyID: cleanURL == nil ? nil : cleanID)
    }
}

/// "My profile photo is now this image" (nil: no photo). Sent when a colleague
/// connects and whenever you change it.
struct AvatarInfo: Codable, Equatable, Sendable {
    let hash: String?
}

/// An image answering a `mediaRequest`: a profile photo or a sticker.
struct MediaBlob: Codable, Equatable, Sendable {
    let hash: String
    let data: Data
}
