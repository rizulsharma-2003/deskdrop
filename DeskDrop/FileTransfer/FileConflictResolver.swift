import Foundation

/// Places finished items into the receiving folder without ever silently
/// overwriting anything.
struct FileConflictResolver: Sendable {
    /// Compound extensions that should stay together when numbering ("a 2.tar.gz").
    private static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]
    private static let maxAttempts = 9999

    /// Splits "report.final.pdf" into ("report.final", ".pdf").
    static func split(_ name: String) -> (base: String, ext: String) {
        let lower = name.lowercased()
        for compound in compoundExtensions where lower.hasSuffix("." + compound) && lower.count > compound.count + 1 {
            let cut = name.index(name.endIndex, offsetBy: -(compound.count + 1))
            return (String(name[..<cut]), String(name[cut...]))
        }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, name.count > ext.count + 1 else { return (name, "") }
        let cut = name.index(name.endIndex, offsetBy: -(ext.count + 1))
        return (String(name[..<cut]), String(name[cut...]))
    }

    /// "report.pdf" → attempt 1: "report.pdf", 2: "report 2.pdf", 3: "report 3.pdf".
    static func candidateName(for name: String, attempt: Int) -> String {
        guard attempt > 1 else { return name }
        let (base, ext) = split(name)
        let candidate = "\(base) \(attempt)\(ext)"
        return NameSanitizer.truncate(candidate, toUTF8Bytes: ProtocolLimits.maxComponentBytes)
    }

    /// Moves `source` into `directory` as `name`, numbering the name if needed.
    /// `moveItem` refuses to overwrite, so a file appearing between the existence check
    /// and the move is handled by trying the next name.
    func moveKeepingBoth(_ source: URL, into directory: URL, name: String) throws -> URL {
        let fileManager = FileManager()
        for attempt in 1...Self.maxAttempts {
            let candidate = Self.candidateName(for: name, attempt: attempt)
            let destination = try PathValidator.url(for: [candidate], in: directory)
            if fileManager.fileExists(atPath: destination.path) { continue }
            do {
                try fileManager.moveItem(at: source, to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Moves the existing item to the Trash and saves in its place. If the Trash
    /// cannot be used, keeps both instead so nothing is lost.
    func moveReplacing(_ source: URL, into directory: URL, name: String) throws -> URL {
        let fileManager = FileManager()
        let destination = try PathValidator.url(for: [name], in: directory)
        if fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.trashItem(at: destination, resultingItemURL: nil)
            } catch {
                Log.files.notice("Could not trash existing item; keeping both")
                return try moveKeepingBoth(source, into: directory, name: name)
            }
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
            return destination
        } catch CocoaError.fileWriteFileExists {
            return try moveKeepingBoth(source, into: directory, name: name)
        }
    }

    func move(_ source: URL, into directory: URL, name: String, handling: DuplicateHandling) throws -> URL {
        switch handling {
        case .keepBoth: try moveKeepingBoth(source, into: directory, name: name)
        case .replace: try moveReplacing(source, into: directory, name: name)
        }
    }
}
