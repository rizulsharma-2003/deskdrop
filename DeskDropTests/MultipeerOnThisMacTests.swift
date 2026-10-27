import Foundation
import Testing
@testable import DeskDrop

/// Real Multipeer Connectivity, two peers inside one process on this Mac:
/// Bonjour discovery, invitation tie-breaking, an encrypted session, the hello
/// handshake, and a real resource transfer between two `TransferService`s.
///
/// Opt-in, because it needs local-network permission and a working network stack:
///     TEST_RUNNER_DESKDROP_NETWORK_TESTS=1 xcodebuild test … -only-testing:DeskDropTests/MultipeerOnThisMacTests
///
/// Both peers share one machine, so this does not replace the two-Mac checklist in
/// docs/TESTING.md (Wi-Fi range, AWDL, firewalls, sleep and roaming are not covered).
@Suite("Multipeer Connectivity on this Mac",
       .enabled(if: ProcessInfo.processInfo.environment["DESKDROP_NETWORK_TESTS"] == "1"),
       .serialized)
@MainActor
struct MultipeerOnThisMacTests {
    private final class OfferLog {
        var offers: [Transfer] = []
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "DeskDropNetworkTests.\(UUID().uuidString)"))
    }

    @Test("Two peers discover each other, connect securely, transfer a file, chat, react, send read receipts, show typing and exchange images", .timeLimit(.minutes(2)))
    func discoverConnectTransfer() async throws {
        let root = TemporaryDirectory("DeskDropMC")
        defer { root.cleanUp() }
        let alice = PeerConnectionService(defaults: try defaults(), inboxDirectory: root.subdirectory("InboxA"))
        let bob = PeerConnectionService(defaults: try defaults(), inboxDirectory: root.subdirectory("InboxB"))
        let bobDestination = TestDestination(root: root)
        let aliceTransfers = TransferService(transport: alice, destination: TestDestination(root: root))
        let bobTransfers = TransferService(transport: bob, destination: bobDestination)
        let log = OfferLog()
        bobTransfers.onIncomingOffer = { log.offers.append($0) }

        let aliceID = UUID().uuidString
        let bobID = UUID().uuidString
        alice.start(identity: LocalIdentity(installationID: aliceID, displayName: "DeskDrop Test A", deviceKind: .laptop, appVersion: "test"))
        bob.start(identity: LocalIdentity(installationID: bobID, displayName: "DeskDrop Test B", deviceKind: .desktop, appVersion: "test"))
        defer {
            alice.stop()
            bob.stop()
        }

        await waitUntil(timeout: .seconds(60), "both peers ready") {
            alice.peer(for: bobID)?.presence == .ready && bob.peer(for: aliceID)?.presence == .ready
        }
        let bobPeer = try #require(alice.peer(for: bobID))
        #expect(bobPeer.displayName == "DeskDrop Test B")

        let data = randomData(8 * 1024 * 1024)
        let source = try root.file("Source/payload.bin", contents: data)
        let outgoing = aliceTransfers.send([source], to: bobPeer)
        await waitUntil(timeout: .seconds(20), "offer arrives") { !log.offers.isEmpty }
        let incoming = try #require(log.offers.first?.id)
        #expect(bobDestination.receivedItems.isEmpty)

        bobTransfers.accept(incoming)
        await waitUntil(timeout: .seconds(60), "transfer completes") {
            aliceTransfers.transfer(outgoing)?.phase == .completed && bobTransfers.transfer(incoming)?.phase == .completed
        }
        let saved = try #require(bobTransfers.transfer(incoming)?.savedURLs.first)
        #expect(try Data(contentsOf: saved) == data)

        // Chat over the same encrypted sessions.
        let aliceLibrary = MediaLibrary(directory: root.subdirectory("MediaA"))
        let bobLibrary = MediaLibrary(directory: root.subdirectory("MediaB"))
        let aliceChat = ChatService(transport: alice, store: ChatStore(fileURL: root.url.appendingPathComponent("a-chat.json")),
                                    media: MediaExchange(transport: alice, library: aliceLibrary)) {
            (aliceID, "DeskDrop Test A")
        }
        let bobChat = ChatService(transport: bob, store: ChatStore(fileURL: root.url.appendingPathComponent("b-chat.json")),
                                  media: MediaExchange(transport: bob, library: bobLibrary)) {
            (bobID, "DeskDrop Test B")
        }
        #expect(aliceChat.availability(of: bobID) == .available)
        aliceChat.send("Hello over Multipeer", to: .direct(bobID))
        await waitUntil(timeout: .seconds(20), "chat delivered") {
            bobChat.store.messages(in: .direct(aliceID)).first?.text == "Hello over Multipeer"
                && aliceChat.store.messages(in: .direct(bobID)).first?.delivery == .delivered
        }
        bobChat.send("Hi everyone", to: .community)
        await waitUntil(timeout: .seconds(20), "community message") {
            aliceChat.store.messages(in: .community).first?.text == "Hi everyone"
        }

        // A tapback and a read receipt.
        let hello = try #require(bobChat.store.messages(in: .direct(aliceID)).first)
        bobChat.toggleReaction("❤️", on: hello)
        bobChat.activeConversation = .direct(aliceID)
        await waitUntil(timeout: .seconds(20), "reaction and read receipt") {
            aliceChat.store.reactionGroups(for: hello.id, me: aliceID).first?.emoji == "❤️"
                && aliceChat.store.messages(in: .direct(bobID)).first?.delivery == .read
        }

        // Both announce "typing" in their hello, so the indicator travels.
        aliceChat.draftChanged(in: .direct(bobID), isEmpty: false)
        await waitUntil(timeout: .seconds(20), "typing indicator") { bobChat.isTyping(aliceID) }

        // A profile photo, then a sticker close to the size limit, fetched by hash.
        let photo = try #require(aliceLibrary.setMyAvatar(makePNG(width: 256, height: 256)))
        aliceChat.media?.announceAvatar()
        await waitUntil(timeout: .seconds(20), "profile photo") { bobLibrary.avatarHashes[aliceID] == photo }

        let big = makeNoisePNG(side: 420)
        #expect(big.count > 500_000 && big.count <= ProtocolLimits.maxMediaBytes)
        let sticker = try #require(aliceLibrary.addSticker(big))
        aliceChat.send(ChatMedia(kind: .sticker, url: nil, hash: sticker, width: 420, height: 420), to: .direct(bobID))
        await waitUntil(timeout: .seconds(30), "sticker image") { bobLibrary.contains(sticker) }
        #expect(bobLibrary.data(for: sticker) == big)
    }
}
