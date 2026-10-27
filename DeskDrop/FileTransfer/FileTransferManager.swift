import Foundation
import UniformTypeIdentifiers

/// A file ready to be offered: where it is on disk and what the recipient will see.
struct PreparedFile: Equatable, Sendable {
    let sourceURL: URL
    let offered: OfferedFile
}

struct PreparedTransfer: Equatable, Sendable {
    let files: [PreparedFile]

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.offered.size } }
}

enum PreparationError: Error, Equatable {
    case nothingToSend
    case itemMissing(String)
    case unreadable(String)
    case unsupportedItem(String)
    case emptyFolder(String)
    case tooManyFiles(Int)
    case pathTooLong(String)
    case fileTooLarge(String)
}

/// Turns dropped Finder items into a `PreparedTransfer`: expands folders into
/// relative paths, sanitizes names exactly as the recipient will validate them,
/// and hashes every file so the recipient can verify what arrives.
enum FileTransferManager {
    /// Runs on a background thread; cancelling the calling task stops hashing.
    static func prepare(_ urls: [URL]) async throws -> PreparedTransfer {
        let task = Task.detached(priority: .userInitiated) { try prepareSynchronously(urls) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func prepareSynchronously(_ urls: [URL]) throws -> PreparedTransfer {
        guard !urls.isEmpty else { throw PreparationError.nothingToSend }

        var entries: [(source: URL, components: [String])] = []
        var topLevelNames = Set<String>()

        for url in urls {
            try Task.checkCancellation()
            let top = uniqueName(NameSanitizer.sanitizeComponent(url.lastPathComponent), avoiding: &topLevelNames)
            try collect(url, topLevelName: top, into: &entries)
        }
        guard !entries.isEmpty else { throw PreparationError.nothingToSend }

        var usedPaths = Set<String>()
        var files: [PreparedFile] = []
        files.reserveCapacity(entries.count)

        for entry in entries {
            try Task.checkCancellation()
            var components = entry.components
            // Sanitizing can make two names identical ("a:b" and "a-b"); number the later one.
            if usedPaths.contains(components.joined(separator: "/").lowercased()), let last = components.popLast() {
                var attempt = 2
                var candidate = FileConflictResolver.candidateName(for: last, attempt: attempt)
                while usedPaths.contains((components + [candidate]).joined(separator: "/").lowercased()) {
                    attempt += 1
                    candidate = FileConflictResolver.candidateName(for: last, attempt: attempt)
                }
                components.append(candidate)
            }
            let path = components.joined(separator: "/")
            usedPaths.insert(path.lowercased())
            files.append(try prepareFile(entry.source, path: path))
        }
        return PreparedTransfer(files: files)
    }

    // MARK: - Private

    private static func collect(_ url: URL, topLevelName: String,
                                into entries: inout [(source: URL, components: [String])]) throws {
        let displayName = url.lastPathComponent
        // A dropped alias or symlink means "send what it points to".
        let resolved = url.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        guard FileManager.default.fileExists(atPath: resolved.path) else { throw PreparationError.itemMissing(displayName) }
        guard let values = try? resolved.resourceValues(forKeys: keys) else { throw PreparationError.unreadable(displayName) }

        if values.isRegularFile == true {
            entries.append((resolved, [topLevelName]))
            try checkCount(entries.count)
            return
        }
        guard values.isDirectory == true else { throw PreparationError.unsupportedItem(displayName) }

        let childKeys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: resolved, includingPropertiesForKeys: childKeys,
                                                              options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw PreparationError.unreadable(displayName) }

        let rootComponents = resolved.standardizedFileURL.pathComponents
        let countBefore = entries.count

        for case let child as URL in enumerator {
            try Task.checkCancellation()
            let childValues = try? child.resourceValues(forKeys: Set(childKeys))
            // Links inside a folder are skipped so nothing outside the folder is sent.
            if childValues?.isSymbolicLink == true { continue }
            guard childValues?.isRegularFile == true else { continue }
            if child.lastPathComponent == ".DS_Store" { continue }

            let childComponents = child.standardizedFileURL.pathComponents
            guard childComponents.count > rootComponents.count,
                  Array(childComponents.prefix(rootComponents.count)) == rootComponents else { continue }
            let relative = childComponents.dropFirst(rootComponents.count).map(NameSanitizer.sanitizeComponent)
            let components = [topLevelName] + relative
            let path = components.joined(separator: "/")
            guard components.count <= ProtocolLimits.maxPathDepth, path.utf8.count <= ProtocolLimits.maxPathBytes else {
                throw PreparationError.pathTooLong(child.lastPathComponent)
            }
            entries.append((child, components))
            try checkCount(entries.count)
        }
        if enumerationError != nil { throw PreparationError.unreadable(displayName) }
        if entries.count == countBefore { throw PreparationError.emptyFolder(displayName) }
    }

    private static func prepareFile(_ url: URL, path: String) throws -> PreparedFile {
        let name = url.lastPathComponent
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw PreparationError.unreadable(name)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= ProtocolLimits.maxFileSize else { throw PreparationError.fileTooLarge(name) }

        let digest: String
        if size == 0 {
            digest = FileDigest.emptySHA256
        } else {
            do {
                digest = try FileDigest.sha256Hex(of: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PreparationError.unreadable(name)
            }
        }

        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        let identifier = type?.identifier
        return PreparedFile(sourceURL: url,
                            offered: OfferedFile(path: path, size: size, sha256: digest,
                                                 typeIdentifier: identifier.flatMap {
                                                     OfferValidator.isValidTypeIdentifier($0) ? $0 : nil
                                                 }))
    }

    private static func checkCount(_ count: Int) throws {
        if count > ProtocolLimits.maxFilesPerTransfer { throw PreparationError.tooManyFiles(count) }
    }

    private static func uniqueName(_ name: String, avoiding used: inout Set<String>) -> String {
        var candidate = name
        var attempt = 2
        while used.contains(candidate.lowercased()) {
            candidate = FileConflictResolver.candidateName(for: name, attempt: attempt)
            attempt += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }
}
