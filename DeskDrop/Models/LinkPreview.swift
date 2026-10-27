import Foundation

/// A preview of the first web link in a message: the page's title, its preview
/// image (og:image) and its icon, as the sender's Mac found them when sending.
/// The images travel between Macs by hash, like stickers, so a colleague's Mac
/// never contacts the website.
struct LinkPreview: Codable, Equatable, Sendable {
    /// The link as it appears in the message (before any redirects).
    let url: URL
    var title: String?
    /// The page's preview image, if it has one.
    var imageHash: String?
    var imageWidth: Int?
    var imageHeight: Int?
    /// The site's icon, shown when there's no preview image.
    var iconHash: String?

    /// "apple.com" for "https://www.apple.com/iphone".
    var host: String {
        let host = url.host?.lowercased() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The images the preview needs.
    var imageHashes: [String] { [imageHash, iconHash].compactMap { $0 } }

    /// The first web link in a message's text, where Markdown makes links: not
    /// inside code, and not email addresses.
    static func firstLink(in text: String) -> URL? {
        for block in MessageMarkdown.blocks(for: text) {
            let string: AttributedString
            switch block {
            case .paragraph(let s), .heading(_, let s), .quote(let s), .listItem(_, _, let s): string = s
            case .code, .rule: continue
            }
            for run in string.runs {
                if let link = run.link, ["http", "https"].contains(link.scheme?.lowercased() ?? ""),
                   link.absoluteString.utf8.count <= 2048 {
                    return link
                }
            }
        }
        return nil
    }

    /// Whether the message is nothing but the link, so the preview can stand in for it.
    static func isOnlyLink(_ text: String) -> Bool {
        let blocks = MessageMarkdown.blocks(for: text)
        guard blocks.count == 1, case .paragraph(let string) = blocks[0] else { return false }
        let visible = string.runs.filter { !String(string[$0.range].characters).allSatisfy(\.isWhitespace) }
        return visible.count == 1 && visible[0].link != nil
    }

    /// A cleaned copy for a message with this text, or nil if it doesn't belong
    /// to the text or has nothing to show.
    func validated(for text: String) -> LinkPreview? {
        guard let link = Self.firstLink(in: text), link == url else { return nil }
        let cleanTitle = title.flatMap(ChatValidator.sanitizeText)
            .map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(200)) }
        var image = imageHash.flatMap { ChatMedia.isHash($0) ? $0 : nil }
        if image != nil {
            guard let width = imageWidth, let height = imageHeight, (1...4096).contains(width), (1...4096).contains(height) else {
                return nil
            }
        } else {
            image = nil
        }
        let icon = iconHash.flatMap { ChatMedia.isHash($0) ? $0 : nil }
        guard cleanTitle != nil || image != nil else { return nil }
        return LinkPreview(url: url, title: cleanTitle, imageHash: image, imageWidth: image == nil ? nil : imageWidth,
                           imageHeight: image == nil ? nil : imageHeight, iconHash: icon)
    }
}
