import Foundation
import Testing
@testable import DeskDrop

@Suite("Filename sanitization")
struct NameSanitizerTests {
    @Test("Separators, control and bidi characters are neutralised", arguments: [
        ("report.pdf", "report.pdf"),
        ("a/b.txt", "a-b.txt"),
        ("a:b.txt", "a-b.txt"),
        ("  spaced name.txt  ", "spaced name.txt"),
        ("tab\there.txt", "tabhere.txt"),
        ("new\nline.txt", "newline.txt"),
        ("invoice\u{202E}fdp.app", "invoicefdp.app"),
        ("zero\u{200F}width.txt", "zerowidth.txt"),
        ("..", "Untitled"),
        (".", "Untitled"),
        ("", "Untitled"),
        ("   ", "Untitled"),
        ("../../etc/passwd", "..-..-etc-passwd"),
        ("Résumé 2024 (final)!.docx", "Résumé 2024 (final)!.docx"),
        ("日本語ファイル.txt", "日本語ファイル.txt"),
        (".env", ".env"),
    ])
    func sanitize(input: String, expected: String) {
        #expect(NameSanitizer.sanitizeComponent(input) == expected)
    }

    @Test("Decomposed Unicode is normalised to NFC")
    func normalisation() {
        let decomposed = "Cafe\u{301}.txt"
        let result = NameSanitizer.sanitizeComponent(decomposed)
        #expect(result == "Café.txt")
        #expect(result.unicodeScalars.count == "Café.txt".unicodeScalars.count)
    }

    @Test("Long names are cut to 255 bytes, keeping the extension and whole characters")
    func truncation() {
        let long = String(repeating: "é", count: 300) + ".pdf"
        let result = NameSanitizer.sanitizeComponent(long)
        #expect(result.utf8.count <= 255)
        #expect(result.hasSuffix(".pdf"))
        #expect(result.dropLast(4).allSatisfy { $0 == "é" })
    }

    @Test("Only already-safe names are accepted as components")
    func safeComponents() {
        #expect(NameSanitizer.isSafeComponent("photo.jpg"))
        #expect(!NameSanitizer.isSafeComponent(".."))
        #expect(!NameSanitizer.isSafeComponent(""))
        #expect(!NameSanitizer.isSafeComponent("a/b"))
        #expect(!NameSanitizer.isSafeComponent(" padded"))
    }

    @Test("Display names are cleaned and bounded")
    func displayNames() {
        #expect(NameSanitizer.sanitizeDisplayName("  Priya’s   MacBook\nPro ") == "Priya’s MacBook Pro")
        #expect(NameSanitizer.sanitizeDisplayName("\u{202E}evil") == "evil")
        #expect(NameSanitizer.sanitizeDisplayName("   ") == nil)
        #expect(NameSanitizer.sanitizeDisplayName(String(repeating: "x", count: 100))?.count == ProtocolLimits.maxDisplayNameLength)
    }
}

@Suite("Path traversal prevention")
struct PathValidatorTests {
    @Test("Hostile relative paths are rejected", arguments: [
        "../secret", "a/../../b", "/etc/passwd", "a//b", "a/./b", "a/", "", "./a", "a/..",
        "folder/\u{202E}txt.exe", "x:y/z",
    ])
    func rejects(path: String) {
        #expect(throws: FileValidationError.self) {
            try PathValidator.components(of: path)
        }
    }

    @Test("Ordinary nested paths are accepted")
    func accepts() throws {
        #expect(try PathValidator.components(of: "Photos/2024/beach.jpg") == ["Photos", "2024", "beach.jpg"])
        #expect(try PathValidator.components(of: "single.txt") == ["single.txt"])
    }

    @Test("Paths that are too deep or too long are rejected")
    func limits() {
        let deep = Array(repeating: "d", count: ProtocolLimits.maxPathDepth + 1).joined(separator: "/")
        #expect(throws: FileValidationError.self) { try PathValidator.components(of: deep) }
        let long = Array(repeating: String(repeating: "n", count: 200), count: 6).joined(separator: "/")
        #expect(throws: FileValidationError.self) { try PathValidator.components(of: long) }
    }

    @Test("Resolved URLs always stay inside the root")
    func containment() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let inside = try PathValidator.url(for: ["a", "b.txt"], in: root.url)
        #expect(PathValidator.isContained(inside, in: root.url.resolvingSymlinksInPath()))
        #expect(throws: FileValidationError.outsideDestination) {
            try PathValidator.url(for: ["..", "escape.txt"], in: root.url)
        }
        #expect(!PathValidator.isContained(root.url.appendingPathComponent("../x"), in: root.url))
        #expect(!PathValidator.isContained(root.url, in: root.url))
    }
}

@Suite("Offer validation")
struct OfferValidatorTests {
    private func file(_ path: String, size: Int64 = 1, digest: String = String(repeating: "c", count: 64),
                      type: String? = "public.data") -> OfferedFile {
        OfferedFile(path: path, size: size, sha256: digest, typeIdentifier: type)
    }

    private func offer(_ files: [OfferedFile], total: Int64? = nil) -> TransferOffer {
        TransferOffer(transferID: UUID(), files: files, totalBytes: total ?? files.reduce(0) { $0 + $1.size })
    }

    @Test("A well-formed offer passes")
    func valid() throws {
        try OfferValidator.validate(offer([file("a.txt"), file("Folder/b.txt"), file("Folder/sub/c.txt", size: 0)]))
    }

    @Test("Empty and oversized offers are rejected")
    func counts() {
        #expect(throws: FileValidationError.emptyOffer) { try OfferValidator.validate(offer([])) }
        let many = (0...ProtocolLimits.maxFilesPerTransfer).map { file("f\($0).txt") }
        #expect(throws: FileValidationError.tooManyFiles(many.count)) { try OfferValidator.validate(offer(many)) }
    }

    @Test("Sizes must be sane and add up")
    func sizes() {
        #expect(throws: FileValidationError.invalidSize) { try OfferValidator.validate(offer([file("a", size: -1)], total: -1)) }
        #expect(throws: FileValidationError.totalSizeMismatch) { try OfferValidator.validate(offer([file("a", size: 5)], total: 4)) }
        #expect(throws: FileValidationError.invalidSize) {
            try OfferValidator.validate(offer([file("a", size: ProtocolLimits.maxFileSize + 1)], total: 0))
        }
    }

    @Test("Digests and type identifiers must be well-formed")
    func digestsAndTypes() {
        #expect(throws: FileValidationError.invalidDigest) { try OfferValidator.validate(offer([file("a", digest: "abc")])) }
        #expect(throws: FileValidationError.invalidDigest) {
            try OfferValidator.validate(offer([file("a", digest: String(repeating: "Z", count: 64))]))
        }
        #expect(throws: FileValidationError.invalidTypeIdentifier) {
            try OfferValidator.validate(offer([file("a", type: "public.data; rm -rf /")]))
        }
    }

    @Test("Duplicate paths are rejected, ignoring case")
    func duplicates() {
        #expect(throws: FileValidationError.self) { try OfferValidator.validate(offer([file("A.txt"), file("a.txt")])) }
    }

    @Test("A path cannot be both a file and a folder")
    func fileFolderConflict() {
        #expect(throws: FileValidationError.pathConflict("docs")) {
            try OfferValidator.validate(offer([file("docs"), file("docs/inner.txt")]))
        }
    }

    @Test("Traversal inside an offer is rejected")
    func traversal() {
        #expect(throws: FileValidationError.invalidPath("../../Library/LaunchAgents/evil.plist")) {
            try OfferValidator.validate(offer([file("../../Library/LaunchAgents/evil.plist")]))
        }
    }
}
