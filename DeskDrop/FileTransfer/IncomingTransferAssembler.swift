import CoreServices
import Foundation

/// Collects the files of one accepted incoming transfer in a private staging
/// folder, verifies each against the offer (size and SHA-256), and finally moves
/// the finished items into the receiving folder.
///
/// Nothing reaches the receiving folder until every file has been verified.
@MainActor
final class IncomingTransferAssembler {
    let offer: TransferOffer
    let directory: URL
    private let components: [[String]]
    private(set) var verifiedIndices: Set<Int> = []
    private var ingesting: Set<Int> = []
    private(set) var verifiedBytes: Int64 = 0

    init(offer: TransferOffer, stagingRoot: URL) throws {
        self.offer = offer
        self.components = try offer.files.map { try PathValidator.components(of: $0.path) }
        self.directory = stagingRoot.appendingPathComponent(offer.transferID.uuidString, isDirectory: true)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Empty files never travel as resources; create them here.
        for (index, file) in offer.files.enumerated() where file.size == 0 {
            guard file.sha256 == FileDigest.emptySHA256 else { throw FileValidationError.invalidDigest }
            let url = try PathValidator.url(for: components[index], in: directory)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fileManager.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            verifiedIndices.insert(index)
        }
    }

    var isComplete: Bool { verifiedIndices.count == offer.files.count }

    var pendingVerificationCount: Int { ingesting.count }

    func expectsResource(at index: Int) -> Bool {
        offer.files.indices.contains(index)
            && offer.files[index].size > 0
            && !verifiedIndices.contains(index)
            && !ingesting.contains(index)
    }

    /// Verifies a received file and moves it to its place in the staging folder.
    /// `url` is consumed whatever the outcome.
    func ingest(_ url: URL, index: Int) async throws {
        guard expectsResource(at: index) else {
            try? FileManager.default.removeItem(at: url)
            throw FileValidationError.invalidPath(String(index))
        }
        let file = offer.files[index]
        let destination = try PathValidator.url(for: components[index], in: directory)
        ingesting.insert(index)
        defer { ingesting.remove(index) }
        try await Task.detached(priority: .utility) {
            try Self.verifyAndPlace(url, size: file.size, sha256: file.sha256, at: destination)
        }.value
        verifiedIndices.insert(index)
        verifiedBytes += file.size
    }

    /// Moves every top-level item into `destinationDirectory`, resolving name
    /// conflicts, and returns where each one ended up.
    func finalize(into destinationDirectory: URL, handling: DuplicateHandling) async throws -> [URL] {
        guard isComplete else { throw FileValidationError.invalidSize }
        let names = offer.topLevelNames
        let staging = directory
        return try await Task.detached(priority: .userInitiated) {
            let resolver = FileConflictResolver()
            var saved: [URL] = []
            for name in names {
                let source = try PathValidator.url(for: [name], in: staging)
                let final = try resolver.move(source, into: destinationDirectory, name: name, handling: handling)
                Self.markQuarantined(final)
                saved.append(final)
            }
            return saved
        }.value
    }

    func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Background work

    private nonisolated static func verifyAndPlace(_ source: URL, size: Int64, sha256: String, at destination: URL) throws {
        let fileManager = FileManager()
        do {
            let attributes = try fileManager.attributesOfItem(atPath: source.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == size else { throw FileValidationError.invalidSize }
            guard try FileDigest.sha256Hex(of: source) == sha256 else { throw FileValidationError.invalidDigest }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            try? fileManager.removeItem(at: source)
            throw error
        }
    }

    /// Received files are marked as downloaded so Gatekeeper checks them before
    /// anything executable can run. Sandboxed apps usually get this automatically;
    /// setting it explicitly makes the behaviour independent of that.
    private nonisolated static func markQuarantined(_ url: URL) {
        let properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "DeskDrop",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        var items = [url]
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let child as URL in enumerator { items.append(child) }
        }
        for item in items {
            var target = item
            var values = URLResourceValues()
            values.quarantineProperties = properties
            try? target.setResourceValues(values)
        }
    }
}
