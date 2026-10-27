import Foundation
import Testing
@testable import DeskDrop

/// Two `TransferService`s — "Alice" sending, "Bob" receiving — connected by an
/// in-process loopback. Everything above the network runs for real: the codec,
/// validation, staging, hashing, conflict handling and saving to disk.
/// These tests do not exercise Multipeer Connectivity; see docs/TESTING.md for the
/// two-Mac checklist that does.
@MainActor
private final class Harness {
    let root = TemporaryDirectory("DeskDropIntegration")
    let aliceWire: LoopbackTransport
    let bobWire: LoopbackTransport
    let alice: TransferService
    let bob: TransferService
    let bobDestination: TestDestination
    var bobOffers: [Transfer] = []

    init() {
        let (aliceWire, bobWire) = LoopbackTransport.pair(in: root)
        self.aliceWire = aliceWire
        self.bobWire = bobWire
        bobDestination = TestDestination(root: root)
        alice = TransferService(transport: aliceWire, destination: TestDestination(root: TemporaryDirectory("unused")))
        bob = TransferService(transport: bobWire, destination: bobDestination)
        bob.onIncomingOffer = { [unowned self] in bobOffers.append($0) }
    }

    var bobAsSeenByAlice: PeerDevice { aliceWire.remotePeer! }

    func source(_ name: String, bytes: Int = 64 * 1024) throws -> (URL, Data) {
        let data = randomData(bytes)
        return (try root.file("Source/\(name)", contents: data), data)
    }

    /// Sends and waits until Bob is asked.
    func offer(_ urls: [URL]) async -> (outgoing: UUID, incoming: UUID?) {
        let before = bobOffers.count
        let id = alice.send(urls, to: bobAsSeenByAlice)
        await waitUntil("offer reaches Bob") { bobOffers.count > before }
        return (id, bobOffers.last?.id)
    }

    func phase(_ service: TransferService, _ id: UUID?) -> TransferPhase? {
        id.flatMap { service.transfer($0)?.phase }
    }

    deinit {
        root.cleanUp()
    }
}

@Suite("Transfer protocol, end to end over loopback", .serialized)
@MainActor
struct TransferServiceIntegrationTests {
    @Test("Accepted files arrive byte-for-byte and both sides report completion")
    func acceptAndDeliver() async throws {
        let harness = Harness()
        let (url, data) = try harness.source("Design Review.key", bytes: 300_000)

        let (outgoing, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)
        #expect(outgoing == incoming)
        #expect(harness.phase(harness.alice, outgoing) == .awaitingAcceptance)
        #expect(harness.phase(harness.bob, incoming) == .awaitingDecision)
        // Nothing is written before the recipient accepts.
        #expect(harness.bobDestination.receivedItems.isEmpty)

        let offered = try #require(harness.bob.transfer(incoming))
        #expect(offered.title == "Design Review.key")
        #expect(offered.totalBytes == 300_000)
        #expect(offered.peerName == "Alice’s Mac")

        harness.bob.accept(incoming)
        await waitUntil("both complete") {
            harness.phase(harness.alice, outgoing) == .completed && harness.phase(harness.bob, incoming) == .completed
        }

        let saved = try #require(harness.bob.transfer(incoming)?.savedURLs.first)
        #expect(saved.lastPathComponent == "Design Review.key")
        #expect(try Data(contentsOf: saved) == data)
        #expect(harness.alice.transfer(outgoing)?.bytesTransferred == 300_000)
        #expect(harness.aliceWire.sentMessages.contains { $0.kind == .offer })
        #expect(harness.bobWire.sentMessages.map(\.kind) == [.accept, .complete])
    }

    @Test("Declining writes nothing and tells the sender")
    func decline() async throws {
        let harness = Harness()
        let (url, _) = try harness.source("private.txt")
        let (outgoing, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)

        harness.bob.decline(incoming)
        await waitUntil("sender sees decline") { harness.phase(harness.alice, outgoing) == .declined(.userDeclined) }

        #expect(harness.phase(harness.bob, incoming) == .declined(.userDeclined))
        #expect(harness.bobDestination.receivedItems.isEmpty)
        #expect(harness.aliceWire.heldResourceCount == 0)
        #expect(!harness.aliceWire.sentMessages.isEmpty)
    }

    @Test("Accept and decline are idempotent")
    func idempotentDecisions() async throws {
        let harness = Harness()
        let (url, _) = try harness.source("twice.txt")
        let (outgoing, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)

        harness.bob.accept(incoming)
        harness.bob.accept(incoming)
        harness.bob.decline(incoming)
        await waitUntil("complete") { harness.phase(harness.alice, outgoing) == .completed }

        #expect(harness.bobWire.sentMessages.filter { $0.kind == .accept }.count == 1)
        #expect(!harness.bobWire.sentMessages.contains { $0.kind == .decline })
        #expect(harness.bobDestination.receivedItems == ["twice.txt"])
    }

    @Test("Folders keep their structure, including empty files")
    func folderTransfer() async throws {
        let harness = Harness()
        let readme = randomData(100)
        try harness.root.file("Source/Site/index.html", contents: readme)
        try harness.root.file("Source/Site/assets/logo.png", contents: randomData(5000))
        try harness.root.file("Source/Site/.keep", contents: Data())
        let folder = harness.root.url.appendingPathComponent("Source/Site")

        let (outgoing, incomingID) = await harness.offer([folder])
        let incoming = try #require(incomingID)
        #expect(harness.bob.transfer(incoming)?.isSingleFolder == true)
        harness.bob.accept(incoming)
        await waitUntil("complete") { harness.phase(harness.bob, incoming) == .completed }
        #expect(harness.phase(harness.alice, outgoing) != nil)

        let saved = harness.bobDestination.directory.appendingPathComponent("Site")
        #expect(try Data(contentsOf: saved.appendingPathComponent("index.html")) == readme)
        #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent("assets/logo.png").path))
        #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent(".keep").path))
    }

    @Test("An empty file is delivered without any resource transfer")
    func emptyFile() async throws {
        let harness = Harness()
        let url = try harness.root.file("Source/empty.log", contents: Data())
        let (outgoing, incomingID) = await harness.offer([url])
        harness.bob.accept(try #require(incomingID))
        await waitUntil("complete") { harness.phase(harness.alice, outgoing) == .completed }
        #expect(harness.bobDestination.receivedItems == ["empty.log"])
    }

    @Test("Existing files are never overwritten")
    func duplicateNames() async throws {
        let harness = Harness()
        try harness.root.file("Received/report.pdf", contents: Data("keep me".utf8))
        let (url, data) = try harness.source("report.pdf")
        let (_, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)
        harness.bob.accept(incoming)
        await waitUntil("complete") { harness.phase(harness.bob, incoming) == .completed }

        #expect(harness.bobDestination.receivedItems == ["report 2.pdf", "report.pdf"])
        #expect(try String(contentsOf: harness.bobDestination.directory.appendingPathComponent("report.pdf"), encoding: .utf8) == "keep me")
        #expect(try Data(contentsOf: harness.bobDestination.directory.appendingPathComponent("report 2.pdf")) == data)
    }

    @Test("Corrupted contents fail verification on both sides and are not saved")
    func corruption() async throws {
        let harness = Harness()
        harness.bobWire.tamperWithReceivedFile = { url in
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            try? handle.seek(toOffset: 5)
            try? handle.write(contentsOf: Data([0xDE, 0xAD]))
            try? handle.close()
        }
        let (url, _) = try harness.source("contract.pdf")
        let (outgoing, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)
        harness.bob.accept(incoming)

        await waitUntil("both fail") {
            harness.phase(harness.bob, incoming) == .failed(.validationFailed)
                && harness.phase(harness.alice, outgoing) == .failed(.validationFailed)
        }
        #expect(harness.bobDestination.receivedItems.isEmpty)
    }

    @Test("The sender can cancel while waiting for a decision")
    func senderCancelsOffer() async throws {
        let harness = Harness()
        let (url, _) = try harness.source("draft.txt")
        let (outgoing, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)

        harness.alice.cancel(outgoing)
        await waitUntil("recipient sees cancel") { harness.phase(harness.bob, incoming) == .cancelled(.remote) }
        #expect(harness.phase(harness.alice, outgoing) == .cancelled(.local))

        harness.bob.accept(incoming)
        #expect(harness.phase(harness.bob, incoming) == .cancelled(.remote))
        #expect(harness.bobDestination.receivedItems.isEmpty)
    }

    @Test("The recipient can cancel mid-transfer; staging is cleaned up")
    func recipientCancelsTransfer() async throws {
        let harness = Harness()
        harness.aliceWire.holdResources = true
        let (url, _) = try harness.source("big.mov")
        let (outgoing, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)
        harness.bob.accept(incoming)
        await waitUntil("sending") { harness.aliceWire.heldResourceCount == 1 }

        harness.bob.cancel(incoming)
        await waitUntil("sender sees cancel") { harness.phase(harness.alice, outgoing) == .cancelled(.remote) }
        harness.aliceWire.releaseResources()

        #expect(harness.phase(harness.bob, incoming) == .cancelled(.local))
        #expect(harness.bobDestination.receivedItems.isEmpty)
        let staging = try FileManager.default.contentsOfDirectory(atPath: harness.bobDestination.stagingRoot.path)
        #expect(staging.isEmpty)
    }

    @Test("Losing the connection mid-transfer fails both sides instead of hanging")
    func disconnect() async throws {
        let harness = Harness()
        harness.aliceWire.holdResources = true
        let (url, _) = try harness.source("video.mp4")
        let (outgoing, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)
        harness.bob.accept(incoming)
        await waitUntil("transferring") { harness.phase(harness.alice, outgoing) == .transferring }

        harness.aliceWire.disconnect()

        #expect(harness.phase(harness.alice, outgoing) == .failed(.peerDisconnected))
        #expect(harness.phase(harness.bob, incoming) == .failed(.peerDisconnected))
        harness.aliceWire.releaseResources()
        #expect(harness.bobDestination.receivedItems.isEmpty)
    }

    @Test("Unanswered offers expire on both sides")
    func expiry() async throws {
        let harness = Harness()
        harness.bob.offerTimeout = .milliseconds(150)
        harness.alice.offerTimeout = .seconds(30)
        let (url, _) = try harness.source("later.txt")
        let (outgoing, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)

        await waitUntil("both expire") {
            harness.phase(harness.bob, incoming) == .expired && harness.phase(harness.alice, outgoing) == .expired
        }
        harness.bob.accept(incoming)
        #expect(harness.phase(harness.bob, incoming) == .expired)
    }

    @Test("A repeated transfer ID is refused")
    func duplicateTransferID() async throws {
        let harness = Harness()
        let (url, _) = try harness.source("once.txt")
        let (_, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)
        let original = try #require(harness.bob.transfer(incoming))

        let replay = TransferOffer(transferID: incoming,
                                   files: [OfferedFile(path: "other.txt", size: 1, sha256: String(repeating: "a", count: 64), typeIdentifier: nil)],
                                   totalBytes: 1)
        harness.bobWire.deliverRaw(.offer(replay), from: harness.aliceWire.localPeer.id)

        #expect(harness.bobOffers.count == 1)
        #expect(harness.bob.transfer(incoming)?.title == original.title)
        #expect(harness.bobWire.sentMessages.last == .failure(transferID: incoming, reason: .duplicateTransfer))
    }

    @Test("Offers with traversal paths are refused before the user sees them")
    func maliciousOffer() async throws {
        let harness = Harness()
        let id = UUID()
        let evil = TransferOffer(transferID: id,
                                 files: [OfferedFile(path: "../../Library/LaunchAgents/x.plist", size: 1,
                                                     sha256: String(repeating: "a", count: 64), typeIdentifier: nil)],
                                 totalBytes: 1)
        harness.bobWire.deliverRaw(.offer(evil), from: harness.aliceWire.localPeer.id)

        #expect(harness.bobOffers.isEmpty)
        #expect(harness.bob.transfer(id) == nil)
        #expect(harness.bobWire.sentMessages.last == .failure(transferID: id, reason: .validationFailed))
    }

    @Test("Offers from unknown peers and resources nobody accepted are ignored")
    func unsolicited() async throws {
        let harness = Harness()
        let offer = TransferOffer(transferID: UUID(),
                                  files: [OfferedFile(path: "a.txt", size: 1, sha256: String(repeating: "a", count: 64), typeIdentifier: nil)],
                                  totalBytes: 1)
        harness.bobWire.deliverRaw(.offer(offer), from: UUID().uuidString)
        #expect(harness.bobOffers.isEmpty)

        let stray = try harness.root.file("stray.bin", contents: randomData(10))
        let progress = Progress(totalUnitCount: 10)
        let name = ResourceName.make(transferID: UUID(), index: 0)
        harness.bob.transport(didStartReceivingResourceNamed: name, from: harness.aliceWire.localPeer.id, progress: progress)
        harness.bob.transport(didFinishReceivingResourceNamed: name, from: harness.aliceWire.localPeer.id, at: stray, error: nil)

        #expect(progress.isCancelled)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(harness.bobDestination.receivedItems.isEmpty)
    }

    @Test("A peer cannot flood the recipient with pending offers")
    func pendingLimit() async throws {
        let harness = Harness()
        for index in 0..<(ProtocolLimits.maxPendingOffersPerPeer + 2) {
            let offer = TransferOffer(transferID: UUID(),
                                      files: [OfferedFile(path: "f\(index).txt", size: 1, sha256: String(repeating: "a", count: 64), typeIdentifier: nil)],
                                      totalBytes: 1)
            harness.bobWire.deliverRaw(.offer(offer), from: harness.aliceWire.localPeer.id)
        }
        #expect(harness.bobOffers.count == ProtocolLimits.maxPendingOffersPerPeer)
        #expect(harness.bobWire.sentMessages.filter { $0.kind == .decline }.count == 2)
    }

    @Test("No space at accept time declines with a reason and writes nothing")
    func noSpace() async throws {
        let harness = Harness()
        harness.bobDestination.failure = DestinationError.insufficientSpace(required: 100, available: 1)
        let (url, _) = try harness.source("huge.iso")
        let (outgoing, incomingID) = await harness.offer([url])
        let incoming = try #require(incomingID)

        harness.bob.accept(incoming)
        await waitUntil("sender told") { harness.phase(harness.alice, outgoing) == .declined(.insufficientSpace) }
        #expect(harness.phase(harness.bob, incoming) == .failed(.insufficientSpace))
        #expect(harness.bobDestination.receivedItems.isEmpty)
    }

    @Test("Simultaneous transfers stay separate")
    func concurrentTransfers() async throws {
        let harness = Harness()
        let (first, firstData) = try harness.source("one.bin", bytes: 40_000)
        let (second, secondData) = try harness.source("two.bin", bytes: 70_000)

        let a = await harness.offer([first])
        let b = await harness.offer([second])
        #expect(a.outgoing != b.outgoing)
        harness.bob.accept(try #require(b.incoming))
        harness.bob.accept(try #require(a.incoming))

        await waitUntil("both complete") {
            harness.phase(harness.alice, a.outgoing) == .completed && harness.phase(harness.alice, b.outgoing) == .completed
        }
        let dir = harness.bobDestination.directory
        #expect(try Data(contentsOf: dir.appendingPathComponent("one.bin")) == firstData)
        #expect(try Data(contentsOf: dir.appendingPathComponent("two.bin")) == secondData)
    }

    @Test("A sender that loses the file before acceptance fails cleanly")
    func sourceDeleted() async throws {
        let harness = Harness()
        let (url, _) = try harness.source("temporary.txt")
        let (outgoing, incomingID) = await harness.offer([url])
        try FileManager.default.removeItem(at: url)

        harness.bob.accept(try #require(incomingID))
        await waitUntil("sender fails") { harness.phase(harness.alice, outgoing) == .failed(.fileUnavailable) }
        await waitUntil("recipient told") { harness.phase(harness.bob, incomingID) == .failed(.fileUnavailable) }
        #expect(harness.bobDestination.receivedItems.isEmpty)
    }

    @Test("Retry sends the same items again as a new transfer")
    func retry() async throws {
        let harness = Harness()
        let (url, _) = try harness.source("again.txt")
        let (outgoing, incomingID) = await harness.offer([url])
        harness.bob.decline(try #require(incomingID))
        await waitUntil("declined") { harness.phase(harness.alice, outgoing) == .declined(.userDeclined) }

        let retried = try #require(harness.alice.retry(outgoing))
        #expect(retried != outgoing)
        #expect(harness.alice.transfer(outgoing) == nil)
        await waitUntil("second offer") { harness.bobOffers.count == 2 }
    }
}
