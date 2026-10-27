import Foundation

/// Markdown in chat messages, as in Slack or GitHub:
///
/// - inline: `**bold**`, `*italic*` or `_italic_`, `~~strikethrough~~`, `` `code` ``,
///   `[links](https://…)`, and plain web addresses and email addresses;
/// - on their own lines: ```` ``` ```` code blocks, `> quotes`, `- lists`, `1. lists`,
///   `# headings` (three levels) and `---` rules.
///
/// A single line break stays a line break, as people expect in chat. Links only
/// open web pages and email; any other kind of link is shown as plain text.
enum MessageMarkdown {
    enum Block: Equatable {
        case paragraph(AttributedString)
        case heading(level: Int, AttributedString)
        case quote(AttributedString)
        /// `marker` is "•" or the item's number ("3.").
        case listItem(marker: String, indent: Int, AttributedString)
        case code(String)
        case rule
    }

    /// Link schemes that may be opened from a message.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    // MARK: - Blocks

    private final class Parsed {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }

    /// Parsed messages, so scrolling and the conversation list don't parse again.
    nonisolated(unsafe) private static let cache: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 500
        return cache
    }()

    static func blocks(for text: String) -> [Block] {
        if let parsed = cache.object(forKey: text as NSString) { return parsed.blocks }
        let blocks = parse(text)
        cache.setObject(Parsed(blocks), forKey: text as NSString)
        return blocks
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
            paragraph.removeAll()
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(inline(quote.joined(separator: "\n"))))
            quote.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushQuote()
                // "```code```" on one line is a one-line block.
                let rest = trimmed.dropFirst(3)
                if rest.hasSuffix("```"), rest.count > 3 {
                    blocks.append(.code(String(rest.dropLast(3))))
                } else {
                    code = []
                }
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst().drop { $0 == " " }))
                continue
            }
            flushQuote()
            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, inline(heading.text)))
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = listItem(line) {
                flushParagraph()
                blocks.append(.listItem(marker: item.marker, indent: item.indent, inline(item.text)))
            } else {
                paragraph.append(line)
            }
        }
        // An unclosed code block runs to the end of the message.
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        flushQuote()
        return blocks
    }

    /// The message without Markdown symbols, for previews, notifications and VoiceOver.
    static func plainText(_ text: String) -> String {
        blocks(for: text).map { block in
            switch block {
            case .paragraph(let string), .heading(_, let string), .quote(let string): String(string.characters)
            case .listItem(let marker, _, let string): "\(marker) \(String(string.characters))"
            case .code(let code): code
            case .rule: "—"
            }
        }
        .joined(separator: "\n")
    }

    /// Whether the text uses any Markdown at all, so plain messages skip the work.
    static func mayContainMarkdown(_ text: String) -> Bool {
        text.contains { "*_~`[]<>#-+|.@:\\&".contains($0) }
    }

    // MARK: - Inline

    /// Inline formatting for one block. Links other than web and email are removed.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false,
                                                              interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        guard var string = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in string.runs {
            guard let link = run.link else { continue }
            if !allowedSchemes.contains(link.scheme?.lowercased() ?? "") {
                string[run.range].link = nil
            }
        }
        return string
    }

    // MARK: - Line kinds

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.filter { $0 != " " }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> (marker: String, indent: Int, text: String)? {
        let spaces = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        let indent = min(spaces / 2, 4)
        if let first = body.first, "-*+•".contains(first), body.dropFirst().first == " " {
            let text = body.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ("•", indent, text)
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        let after = body.dropFirst(digits.count)
        guard let dot = after.first, dot == "." || dot == ")", after.dropFirst().first == " " else { return nil }
        let text = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : ("\(digits).", indent, text)
    }
}
