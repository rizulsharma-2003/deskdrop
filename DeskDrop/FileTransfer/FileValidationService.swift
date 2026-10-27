import Foundation

enum FileValidationError: Error, Equatable {
    case emptyOffer
    case tooManyFiles(Int)
    case invalidPath(String)
    case invalidSize
    case totalSizeMismatch
    case invalidDigest
    case invalidTypeIdentifier
    case duplicatePath(String)
    case pathConflict(String)
    case outsideDestination
}

/// Turns untrusted names into safe single path components.
enum NameSanitizer {
    /// Bidirectional overrides and isolates can disguise an extension
    /// ("invoice\u{202E}fdp.app" displays as "invoiceppa.pdf"), so they are removed.
    private static let bidiControls: Set<UInt32> = [
        0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
    ]

    static let fallbackName = "Untitled"

    static func isBidiControl(_ scalar: Unicode.Scalar) -> Bool {
        bidiControls.contains(scalar.value)
    }

    /// A name that is safe to use as one path component: no separators, no control
    /// or bidi characters, not "." or "..", at most 255 UTF-8 bytes, NFC-normalised.
    static func sanitizeComponent(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.properties.generalCategory == .control || bidiControls.contains(scalar.value) {
                continue
            }
            switch scalar {
            case "/", ":": scalars.append("-")
            default: scalars.append(scalar)
            }
        }
        var name = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            name = fallbackName
        }
        return truncate(name, toUTF8Bytes: ProtocolLimits.maxComponentBytes)
    }

    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && sanitizeComponent(name) == name
    }

    /// A display name suitable for the UI, or nil when nothing usable remains.
    static func sanitizeDisplayName(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace {
                scalars.append(" ")
            } else if scalar.properties.generalCategory == .control || bidiControls.contains(scalar.value) {
                continue
            } else {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(ProtocolLimits.maxDisplayNameLength))
    }

    /// Shortens `name` to fit `limit` UTF-8 bytes, keeping a short extension and never
    /// splitting a character.
    static func truncate(_ name: String, toUTF8Bytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let keepExtension = !ext.isEmpty && ext.utf8.count <= 16
        let suffix = keepExtension ? "." + ext : ""
        var base = keepExtension ? String(name.dropLast(suffix.count)) : name
        while !base.isEmpty, base.utf8.count + suffix.utf8.count > limit {
            base.removeLast()
        }
        return base.isEmpty ? String(suffix.prefix(limit)) : base + suffix
    }
}

/// Validates relative paths received from a peer and maps them into a directory.
enum PathValidator {
    /// The components of a sender-supplied relative path, or an error if any part of
    /// it could escape the destination or is not already in sanitized form.
    static func components(of path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= ProtocolLimits.maxPathBytes, !path.hasPrefix("/") else {
            throw FileValidationError.invalidPath(path)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= ProtocolLimits.maxPathDepth else { throw FileValidationError.invalidPath(path) }
        for part in parts where !NameSanitizer.isSafeComponent(part) {
            throw FileValidationError.invalidPath(path)
        }
        return parts
    }

    /// `root` + components, verified to stay inside `root` after standardization.
    static func url(for components: [String], in root: URL) throws -> URL {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var url = base
        for component in components {
            guard NameSanitizer.isSafeComponent(component) else { throw FileValidationError.outsideDestination }
            url.appendPathComponent(component, isDirectory: false)
        }
        guard isContained(url, in: base) else { throw FileValidationError.outsideDestination }
        return url
    }

    static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) && path.count > prefix.count
    }
}

/// Checks a received offer before it is ever shown to the user.
enum OfferValidator {
    static func validate(_ offer: TransferOffer) throws {
        guard !offer.files.isEmpty else { throw FileValidationError.emptyOffer }
        guard offer.files.count <= ProtocolLimits.maxFilesPerTransfer else {
            throw FileValidationError.tooManyFiles(offer.files.count)
        }

        var total: Int64 = 0
        // APFS and HFS+ are case-insensitive by default, so compare case-folded paths.
        var filePaths = Set<String>()
        var componentLists: [[String]] = []

        for file in offer.files {
            let parts = try PathValidator.components(of: file.path)
            guard (0...ProtocolLimits.maxFileSize).contains(file.size) else { throw FileValidationError.invalidSize }
            let (sum, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow else { throw FileValidationError.invalidSize }
            total = sum
            guard isValidDigest(file.sha256) else { throw FileValidationError.invalidDigest }
            if let type = file.typeIdentifier, !isValidTypeIdentifier(type) {
                throw FileValidationError.invalidTypeIdentifier
            }
            let key = file.path.lowercased()
            guard filePaths.insert(key).inserted else { throw FileValidationError.duplicatePath(file.path) }
            componentLists.append(parts)
        }
        guard total == offer.totalBytes else { throw FileValidationError.totalSizeMismatch }

        // A file may not also be used as a folder ("a" and "a/b").
        for parts in componentLists where parts.count > 1 {
            for depth in 1..<parts.count {
                let ancestor = parts[0..<depth].joined(separator: "/").lowercased()
                if filePaths.contains(ancestor) { throw FileValidationError.pathConflict(ancestor) }
            }
        }
    }

    static func isValidDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isValidTypeIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier.utf8.count <= ProtocolLimits.maxTypeIdentifierLength else { return false }
        return identifier.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || byte == 46 || byte == 45
        }
    }
}
