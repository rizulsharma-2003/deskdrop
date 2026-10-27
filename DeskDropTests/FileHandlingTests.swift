import CryptoKit
import Foundation
import Testing
@testable import DeskDrop

@Suite("Conflict resolution")
struct ConflictResolverTests {
    @Test("Names split around the extension, keeping compound archive extensions", arguments: [
        ("report.pdf", "report", ".pdf"),
        ("archive.tar.gz", "archive", ".tar.gz"),
        ("Makefile", "Makefile", ""),
        (".env", ".env", ""),
        ("v1.2.final.key", "v1.2.final", ".key"),
    ])
    func split(name: String, base: String, ext: String) {
        let result = FileConflictResolver.split(name)
        #expect(result.base == base)
        #expect(result.ext == ext)
    }

    @Test("Candidate names count up like Finder")
    func candidates() {
        #expect(FileConflictResolver.candidateName(for: "report.pdf", attempt: 1) == "report.pdf")
        #expect(FileConflictResolver.candidateName(for: "report.pdf", attempt: 2) == "report 2.pdf")
        #expect(FileConflictResolver.candidateName(for: "backup.tar.gz", attempt: 3) == "backup 3.tar.gz")
    }

    @Test("Keep-both never overwrites an existing file")
    func keepBoth() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let destination = root.subdirectory("Downloads")
        try root.file("Downloads/notes.txt", contents: Data("original".utf8))
        try root.file("Downloads/notes 2.txt", contents: Data("second".utf8))
        let incoming = try root.file("incoming.txt", contents: Data("new".utf8))

        let saved = try FileConflictResolver().move(incoming, into: destination, name: "notes.txt", handling: .keepBoth)

        #expect(saved.lastPathComponent == "notes 3.txt")
        #expect(try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8) == "original")
        #expect(try String(contentsOf: saved, encoding: .utf8) == "new")
    }

    @Test("Replace saves under the original name when nothing is there")
    func replaceWithoutConflict() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let destination = root.subdirectory("Downloads")
        let incoming = try root.file("incoming.txt", contents: Data("new".utf8))
        let saved = try FileConflictResolver().move(incoming, into: destination, name: "fresh.txt", handling: .replace)
        #expect(saved.lastPathComponent == "fresh.txt")
    }

    @Test("Replace never deletes the existing file outright")
    func replaceKeepsOldContentRecoverable() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let destination = root.subdirectory("Downloads")
        try root.file("Downloads/notes.txt", contents: Data("original".utf8))
        let incoming = try root.file("incoming.txt", contents: Data("new".utf8))

        let saved = try FileConflictResolver().move(incoming, into: destination, name: "notes.txt", handling: .replace)

        #expect(try String(contentsOf: saved, encoding: .utf8) == "new")
        // Either the old file went to the Trash (saved as notes.txt), or the Trash was
        // unavailable and both were kept. In no case is the original silently destroyed.
        if saved.lastPathComponent != "notes.txt" {
            #expect(try String(contentsOf: destination.appendingPathComponent("notes.txt"), encoding: .utf8) == "original")
        }
    }
}

@Suite("Receiving destination")
@MainActor
struct DestinationTests {
    @Test("Missing folders and plain files are not valid destinations")
    func validation() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        #expect(throws: DestinationError.folderUnavailable("missing")) {
            try FileDestinationManager.validateDirectory(root.url.appendingPathComponent("missing"))
        }
        let file = try root.file("plain.txt", contents: Data())
        #expect(throws: DestinationError.folderUnavailable("plain.txt")) {
            try FileDestinationManager.validateDirectory(file)
        }
        try FileDestinationManager.validateDirectory(root.url)
    }

    @Test("Transfers larger than the free space are refused before anything is written")
    func capacity() {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        #expect(throws: DestinationError.self) {
            try FileDestinationManager.ensureCapacity(Int64.max / 2, at: [root.url])
        }
        #expect(throws: Never.self) {
            try FileDestinationManager.ensureCapacity(1024, at: [root.url])
        }
    }

    @Test("Downloads is the default and a custom folder can be chosen and reset")
    func customFolder() throws {
        let suite = "DeskDropTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = TemporaryDirectory()
        defer { root.cleanUp() }

        let manager = FileDestinationManager(defaults: defaults, stagingRoot: root.subdirectory("Staging")) { .keepBoth }
        #expect(manager.isUsingDefaultDirectory)
        #expect(manager.receivingDirectory.lastPathComponent == "Downloads")

        let custom = root.subdirectory("Inbox")
        try manager.setCustomDirectory(custom)
        #expect(manager.receivingDirectory == custom)
        #expect(try manager.prepareDestination(requiredBytes: 10) == custom)

        manager.resetToDefaultDirectory()
        #expect(manager.isUsingDefaultDirectory)
        #expect(defaults.data(forKey: SettingsKey.receivingDirectoryBookmark) == nil)
    }
}

@Suite("Sender preparation")
struct PreparationTests {
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("A single file is described by name, size and digest")
    func singleFile() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let data = randomData(4096)
        let url = try root.file("Quarterly Report.pdf", contents: data)

        let prepared = try FileTransferManager.prepareSynchronously([url])

        #expect(prepared.files.count == 1)
        let offered = prepared.files[0].offered
        #expect(offered.path == "Quarterly Report.pdf")
        #expect(offered.size == 4096)
        #expect(offered.sha256 == sha256(data))
        #expect(offered.typeIdentifier == "com.adobe.pdf")
        #expect(prepared.totalBytes == 4096)
    }

    @Test("Folders expand to relative paths; links and .DS_Store are skipped")
    func folder() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        try root.file("Project/README.md", contents: Data("hi".utf8))
        try root.file("Project/src/main.swift", contents: Data("print(1)".utf8))
        try root.file("Project/.DS_Store", contents: Data([0]))
        try root.file("Project/empty.txt", contents: Data())
        let outside = try root.file("secret.txt", contents: Data("outside".utf8))
        try FileManager.default.createSymbolicLink(at: root.url.appendingPathComponent("Project/link.txt"), withDestinationURL: outside)

        let prepared = try FileTransferManager.prepareSynchronously([root.url.appendingPathComponent("Project")])
        let paths = Set(prepared.files.map(\.offered.path))

        #expect(paths == ["Project/README.md", "Project/src/main.swift", "Project/empty.txt"])
        let empty = try #require(prepared.files.first { $0.offered.path == "Project/empty.txt" })
        #expect(empty.offered.sha256 == FileDigest.emptySHA256)
        try OfferValidator.validate(TransferOffer(transferID: UUID(), files: prepared.files.map(\.offered), totalBytes: prepared.totalBytes))
    }

    @Test("Items with the same name from different places are numbered")
    func duplicateNames() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let a = try root.file("one/notes.txt", contents: Data("a".utf8))
        let b = try root.file("two/Notes.txt", contents: Data("b".utf8))
        let prepared = try FileTransferManager.prepareSynchronously([a, b])
        #expect(prepared.files.map(\.offered.path) == ["notes.txt", "Notes 2.txt"])
    }

    @Test("Missing items and empty folders are reported clearly")
    func failures() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        #expect(throws: PreparationError.itemMissing("gone.txt")) {
            try FileTransferManager.prepareSynchronously([root.url.appendingPathComponent("gone.txt")])
        }
        let empty = root.subdirectory("Empty")
        #expect(throws: PreparationError.emptyFolder("Empty")) {
            try FileTransferManager.prepareSynchronously([empty])
        }
        #expect(throws: PreparationError.nothingToSend) {
            try FileTransferManager.prepareSynchronously([])
        }
    }

    @Test("Streaming digest matches CryptoKit for multi-chunk files")
    func digest() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let data = randomData(3 * 1024 + 17)
        let url = try root.file("blob.bin", contents: data)
        #expect(try FileDigest.sha256Hex(of: url, chunkSize: 1024) == sha256(data))
    }
}

@Suite("Receiving assembly")
@MainActor
struct AssemblerTests {
    private func offer(for data: Data, path: String = "file.bin") -> TransferOffer {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return TransferOffer(transferID: UUID(),
                             files: [OfferedFile(path: path, size: Int64(data.count), sha256: digest, typeIdentifier: nil)],
                             totalBytes: Int64(data.count))
    }

    @Test("A verified file is saved, quarantined and staging is cleaned up")
    func happyPath() async throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let data = randomData(2048)
        let offer = offer(for: data, path: "photo.jpg")
        let assembler = try IncomingTransferAssembler(offer: offer, stagingRoot: root.subdirectory("Staging"))
        let wire = try root.file("wire/blob", contents: data)

        #expect(assembler.expectsResource(at: 0))
        try await assembler.ingest(wire, index: 0)
        #expect(assembler.isComplete)
        #expect(!FileManager.default.fileExists(atPath: wire.path))

        let saved = try await assembler.finalize(into: root.subdirectory("Downloads"), handling: .keepBoth)
        #expect(saved.map(\.lastPathComponent) == ["photo.jpg"])
        #expect(try Data(contentsOf: saved[0]) == data)
        let quarantine = try saved[0].resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine != nil)
        assembler.discard()
        #expect(!FileManager.default.fileExists(atPath: assembler.directory.path))
    }

    @Test("Wrong size or contents are rejected and the bytes deleted")
    func rejectsTampering() async throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let data = randomData(512)
        let assembler = try IncomingTransferAssembler(offer: offer(for: data), stagingRoot: root.subdirectory("Staging"))

        let short = try root.file("wire/short", contents: data.prefix(100))
        await #expect(throws: FileValidationError.invalidSize) { try await assembler.ingest(short, index: 0) }
        #expect(!FileManager.default.fileExists(atPath: short.path))

        var flipped = data
        flipped[10] ^= 0xFF
        let corrupt = try root.file("wire/corrupt", contents: flipped)
        await #expect(throws: FileValidationError.invalidDigest) { try await assembler.ingest(corrupt, index: 0) }
        #expect(!assembler.isComplete)
    }

    @Test("Resources outside the offer are refused")
    func unexpectedIndex() async throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let data = randomData(16)
        let assembler = try IncomingTransferAssembler(offer: offer(for: data), stagingRoot: root.subdirectory("Staging"))
        #expect(!assembler.expectsResource(at: 1))
        #expect(!assembler.expectsResource(at: -1))
        let extra = try root.file("wire/extra", contents: data)
        await #expect(throws: FileValidationError.self) { try await assembler.ingest(extra, index: 5) }
        #expect(!FileManager.default.fileExists(atPath: extra.path))
    }
}

@Suite("History persistence")
@MainActor
struct HistoryStoreTests {
    private func entry(_ title: String, outcome: HistoryEntry.Outcome = .completed) -> HistoryEntry {
        HistoryEntry(id: UUID(), title: title, fileCount: 1, totalBytes: 10, direction: .incoming,
                     peerName: "Alex", date: .now, outcome: outcome, detail: nil, savedPath: nil)
    }

    @Test("Entries persist across instances, newest first")
    func persistence() {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let url = root.url.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: url)
        store.record(entry("first"))
        store.record(entry("second", outcome: .declined))

        let reloaded = HistoryStore(fileURL: url)
        #expect(reloaded.entries.map(\.title) == ["second", "first"])
        #expect(reloaded.entries.first?.outcome == .declined)
    }

    @Test("History is capped and can be cleared")
    func limitAndClear() {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let url = root.url.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: url, limit: 3)
        for index in 0..<5 { store.record(entry("item \(index)")) }
        #expect(store.entries.map(\.title) == ["item 4", "item 3", "item 2"])
        store.clear()
        #expect(HistoryStore(fileURL: url).entries.isEmpty)
    }

    @Test("A corrupt history file is set aside instead of crashing")
    func corrupt() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let url = try root.file("history.json", contents: Data("{ not json".utf8))
        let store = HistoryStore(fileURL: url)
        #expect(store.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("history.corrupt.json").path))
    }
}
