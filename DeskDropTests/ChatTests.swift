import Foundation
import Testing
@testable import DeskDrop

@Suite("Chat text validation")
struct ChatValidatorTests {
    @Test("Text keeps newlines and tabs but loses control and bidi characters")
    func sanitize() {
        #expect(ChatValidator.sanitizeText("  Hello\nworld\t!  ") == "Hello\nworld\t!")
        #expect(ChatValidator.sanitizeText("line\r\nbreak") == "line\nbreak")
        #expect(ChatValidator.sanitizeText("bell\u{07}ring") == "bellring")
        #expect(ChatValidator.sanitizeText("open \u{202E}gnp.exe") == "open gnp.exe")
        #expect(ChatValidator.sanitizeText("   \n\t ") == nil)
        #expect(ChatValidator.sanitizeText(String(repeating: "a", count: 5000))?.count == ProtocolLimits.maxChatCharacters)
    }

    @Test("Reactions must be a single emoji")
    func emoji() {
        #expect(ChatValidator.sanitizeEmoji("❤️") == "❤️")
        #expect(ChatValidator.sanitizeEmoji(" 👍 ") == "👍")
        #expect(ChatValidator.sanitizeEmoji("‼️") == "‼️")
        #expect(ChatValidator.sanitizeEmoji("👩‍💻") == "👩‍💻")
        #expect(ChatValidator.sanitizeEmoji("👍👍") == nil)
        #expect(ChatValidator.sanitizeEmoji("a") == nil)
        #expect(ChatValidator.sanitizeEmoji("1") == nil)
        #expect(ChatValidator.sanitizeEmoji("") == nil)
    }

    @Test("Incoming messages are checked and cleaned")
    func validate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let good = ChatPayload(id: UUID(), scope: .direct, senderID: UUID().uuidString, senderName: "  Alex\u{202E} ",
                               text: "hi", sentAt: now.addingTimeInterval(-30))
        #expect(ChatValidator.validate(good, now: now)?.senderName == "Alex")

        let future = ChatPayload(id: UUID(), scope: .direct, senderID: UUID().uuidString, senderName: "A",
                                 text: "from the future", sentAt: now.addingTimeInterval(86_400))
        #expect(ChatValidator.validate(future, now: now)?.sentAt == now.addingTimeInterval(60))

        let badSender = ChatPayload(id: UUID(), scope: .direct, senderID: "../x", senderName: "A", text: "hi", sentAt: now)
        #expect(ChatValidator.validate(badSender, now: now) == nil)
        let empty = ChatPayload(id: UUID(), scope: .direct, senderID: UUID().uuidString, senderName: "A", text: " ", sentAt: now)
        #expect(ChatValidator.validate(empty, now: now) == nil)
        let huge = ChatPayload(id: UUID(), scope: .direct, senderID: UUID().uuidString, senderName: "A",
                               text: String(repeating: "x", count: ProtocolLimits.maxChatCharacters + 1), sentAt: now)
        #expect(ChatValidator.validate(huge, now: now) == nil)
    }
}

@Suite("Chat history storage")
@MainActor
struct ChatStoreTests {
    private func message(_ text: String, in conversation: ConversationID = .community, at seconds: TimeInterval,
                         outgoing: Bool = false, delivery: ChatMessage.Delivery? = nil) -> ChatMessage {
        let date = Date(timeIntervalSince1970: 1_800_000_000 + seconds)
        return ChatMessage(id: UUID(), conversation: conversation, senderID: UUID().uuidString, senderName: "Alex",
                           text: text, sentAt: date, receivedAt: date, isOutgoing: outgoing, delivery: delivery)
    }

    @Test("History survives relaunch, in time order, without duplicates")
    func persistence() async throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let url = root.url.appendingPathComponent("chat.json")
        let store = ChatStore(fileURL: url)
        let first = message("first", at: 10)
        #expect(store.insert(message("third", at: 30)))
        #expect(store.insert(first))
        #expect(store.insert(message("second", at: 20)))
        #expect(!store.insert(first), "Duplicates are ignored")
        store.remember(name: "Alex’s Mac", for: "peer-1")
        store.flush()

        let reloaded = ChatStore(fileURL: url)
        #expect(reloaded.messages(in: .community).map(\.text) == ["first", "second", "third"])
        #expect(reloaded.contacts["peer-1"] == "Alex’s Mac")
        #expect(reloaded.contains(first.id))
    }

    @Test("Reactions are grouped, persisted and removable")
    func storedReactions() {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let url = root.url.appendingPathComponent("chat.json")
        let store = ChatStore(fileURL: url)
        let target = message("nice work", at: 0)
        store.insert(target)
        store.setReaction("❤️", by: "me", name: "Me", on: target.id, at: Date(timeIntervalSince1970: 1))
        store.setReaction("❤️", by: "alex", name: "Alex", on: target.id, at: Date(timeIntervalSince1970: 2))
        store.setReaction("😂", by: "priya", name: "Priya", on: target.id, at: Date(timeIntervalSince1970: 3))
        store.flush()

        let reloaded = ChatStore(fileURL: url)
        let groups = reloaded.reactionGroups(for: target.id, me: "me")
        #expect(groups.map(\.emoji) == ["❤️", "😂"])
        #expect(groups.first?.names == ["You", "Alex"])
        #expect(groups.first?.includesMe == true)

        reloaded.setReaction(nil, by: "priya", name: "Priya", on: target.id)
        #expect(reloaded.reactionGroups(for: target.id, me: "me").map(\.emoji) == ["❤️"])
    }

    @Test("Unread counts only incoming messages since the conversation was last read")
    func unread() {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let store = ChatStore(fileURL: root.url.appendingPathComponent("chat.json"))
        let alex = ConversationID.direct("alex")
        store.insert(ChatMessage(id: UUID(), conversation: alex, senderID: "alex", senderName: "Alex", text: "hi",
                                 sentAt: .now, receivedAt: .now, isOutgoing: false, delivery: nil))
        store.insert(ChatMessage(id: UUID(), conversation: alex, senderID: "me", senderName: "Me", text: "hello",
                                 sentAt: .now, receivedAt: .now, isOutgoing: true, delivery: .sent))
        store.insert(message("everyone", at: 0))
        #expect(store.unreadCount(in: alex) == 1)
        #expect(store.totalUnread == 2)
        store.markRead(alex)
        #expect(store.unreadCount(in: alex) == 0)
        #expect(store.totalUnread == 1)
    }

    @Test("Delivery only moves forward, and only for messages you sent")
    func delivery() {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let store = ChatStore(fileURL: root.url.appendingPathComponent("chat.json"))
        let mine = message("hi", in: .direct("p"), at: 0, outgoing: true, delivery: .pending)
        store.insert(mine)
        #expect(store.pending(for: "p").count == 1)
        store.updateDelivery(of: mine.id, in: .direct("p"), to: .delivered)
        store.updateDelivery(of: mine.id, in: .direct("p"), to: .sent)
        #expect(store.messages(in: .direct("p")).first?.delivery == .delivered)
        #expect(store.pending(for: "p").isEmpty)
    }

    @Test("Conversations can be deleted or all history cleared")
    func clearing() {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let store = ChatStore(fileURL: root.url.appendingPathComponent("chat.json"))
        let kept = message("kept", at: 0)
        store.insert(kept)
        store.insert(message("gone", in: .direct("p"), at: 0))
        store.deleteConversation(.direct("p"))
        #expect(store.messages(in: .direct("p")).isEmpty)
        #expect(store.contains(kept.id))
        store.clearAll()
        #expect(store.messages.isEmpty)
        #expect(!store.contains(kept.id))
    }

    @Test("A corrupt history file is set aside instead of crashing")
    func corrupt() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let url = try root.file("chat.json", contents: Data("{oops".utf8))
        let store = ChatStore(fileURL: url)
        #expect(store.messages.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("chat.corrupt.json").path))
    }
}

/// Two chat services ("Alice" and "Bob") over the in-process loopback, with real
/// encoding and validation. Not Multipeer Connectivity — see MultipeerOnThisMacTests.
@MainActor
private final class ChatHarness {
    let root = TemporaryDirectory("DeskDropChat")
    let aliceWire: LoopbackTransport
    let bobWire: LoopbackTransport
    let alice: ChatService
    let bob: ChatService
    var bobReceived: [ChatMessage] = []

    init(connected: Bool = true, bobSendsReceipts: Bool = true, aliceSendsTyping: Bool = true) {
        let (aliceWire, bobWire) = LoopbackTransport.pair(in: root)
        self.aliceWire = aliceWire
        self.bobWire = bobWire
        aliceWire.isConnected = connected
        bobWire.isConnected = connected
        let aliceID = aliceWire.localPeer.id
        let bobID = bobWire.localPeer.id
        alice = ChatService(transport: aliceWire, store: ChatStore(fileURL: root.url.appendingPathComponent("alice.json")),
                            sendsTyping: { aliceSendsTyping }) {
            (aliceID, "Alice’s Mac")
        }
        bob = ChatService(transport: bobWire, store: ChatStore(fileURL: root.url.appendingPathComponent("bob.json")),
                          sendsReadReceipts: { bobSendsReceipts }) {
            (bobID, "Bob’s Mac")
        }
        bob.onMessageReceived = { [unowned self] in bobReceived.append($0) }
    }

    var aliceID: String { aliceWire.localPeer.id }
    var bobID: String { bobWire.localPeer.id }

    deinit {
        root.cleanUp()
    }
}

@Suite("Chat between Macs, over loopback", .serialized)
@MainActor
struct ChatServiceTests {
    @Test("A one-on-one message is delivered, stored on both sides and acknowledged")
    func direct() async throws {
        let harness = ChatHarness()
        #expect(harness.alice.send("  Hi Bob!  ", to: .direct(harness.bobID)))

        await waitUntil("Bob receives") { harness.bobReceived.count == 1 }
        let received = try #require(harness.bob.store.messages(in: .direct(harness.aliceID)).first)
        #expect(received.text == "Hi Bob!")
        #expect(received.senderName == "Alice’s Mac")
        #expect(!received.isOutgoing)
        #expect(harness.bob.store.unreadCount(in: .direct(harness.aliceID)) == 1)

        await waitUntil("delivered receipt") {
            harness.alice.store.messages(in: .direct(harness.bobID)).first?.delivery == .delivered
        }
        #expect(!harness.alice.send("   ", to: .direct(harness.bobID)), "Blank messages aren't sent")
    }

    @Test("Messages to an offline colleague wait and go out when they connect")
    func outbox() async throws {
        let harness = ChatHarness(connected: false)
        harness.alice.send("Are you in today?", to: .direct(harness.bobID))
        harness.alice.send("Ping me when you're back", to: .direct(harness.bobID))
        #expect(harness.alice.store.pending(for: harness.bobID).count == 2)
        #expect(harness.alice.availability(of: harness.bobID) == .offline)

        harness.aliceWire.connectAndAnnounce()

        await waitUntil("both delivered") {
            harness.alice.store.messages(in: .direct(harness.bobID)).allSatisfy { $0.delivery == .delivered }
                && harness.bob.store.messages(in: .direct(harness.aliceID)).count == 2
        }
        #expect(harness.bob.store.messages(in: .direct(harness.aliceID)).map(\.text)
                == ["Are you in today?", "Ping me when you're back"])
    }

    @Test("Community messages reach everyone connected")
    func community() async throws {
        let harness = ChatHarness()
        harness.alice.send("Standup in 5", to: .community)
        await waitUntil("Bob receives") { !harness.bob.store.messages(in: .community).isEmpty }
        let message = try #require(harness.bob.store.messages(in: .community).first)
        #expect(message.text == "Standup in 5")
        #expect(message.senderID == harness.aliceID)
        #expect(harness.alice.store.messages(in: .community).first?.isOutgoing == true)
    }

    @Test("Colleagues who were away catch up on the community conversation when they connect")
    func catchUp() async throws {
        let harness = ChatHarness(connected: false)
        harness.alice.send("Pizza in the kitchen", to: .community)
        harness.alice.send("Nobody else here yet?", to: .community)
        #expect(harness.bob.store.messages(in: .community).isEmpty)

        harness.aliceWire.connectAndAnnounce()

        await waitUntil("Bob catches up") { harness.bob.store.messages(in: .community).count == 2 }
        #expect(harness.bob.store.messages(in: .community).map(\.text) == ["Pizza in the kitchen", "Nobody else here yet?"])
        #expect(harness.bob.store.unreadCount(in: .community) == 2)
        #expect(harness.bobReceived.isEmpty, "Catch-up doesn't fire a notification per message")
        // Alice also asked Bob; he had nothing new, and her copies aren't duplicated.
        #expect(harness.alice.store.messages(in: .community).count == 2)
    }

    @Test("Reactions reach the other Mac, change, and can be removed")
    func reactions() async throws {
        let harness = ChatHarness()
        harness.alice.send("Ship it?", to: .direct(harness.bobID))
        await waitUntil("Bob receives") { harness.bobReceived.count == 1 }
        let onBob = try #require(harness.bob.store.messages(in: .direct(harness.aliceID)).first)

        harness.bob.toggleReaction("👍", on: onBob)
        await waitUntil("Alice sees 👍") {
            harness.alice.store.reactionGroups(for: onBob.id, me: harness.aliceID).first?.emoji == "👍"
        }
        #expect(harness.alice.store.reactionGroups(for: onBob.id, me: harness.aliceID).first?.names == ["Bob’s Mac"])
        #expect(harness.bob.store.reactionGroups(for: onBob.id, me: harness.bobID).first?.includesMe == true)

        harness.bob.toggleReaction("❤️", on: onBob)
        await waitUntil("changed to ❤️") { harness.alice.store.myReaction(to: onBob.id, me: harness.bobID) == "❤️" }

        harness.bob.toggleReaction("❤️", on: onBob)
        await waitUntil("removed") { harness.alice.store.reactionGroups(for: onBob.id, me: harness.aliceID).isEmpty }
    }

    @Test("Reactions to messages in another conversation, or from someone else, are refused")
    func forgedReactions() async throws {
        let harness = ChatHarness()
        harness.alice.send("Group hello", to: .community)
        await waitUntil("Bob receives") { !harness.bob.store.messages(in: .community).isEmpty }
        let message = try #require(harness.bob.store.messages(in: .community).first)

        let impostor = ChatReaction(messageID: message.id, scope: .community, emoji: "👎", reactorID: UUID().uuidString,
                                    reactorName: "Someone", at: .now)
        harness.bobWire.deliverRaw(.chatReaction(impostor), from: harness.aliceID)
        let wrongConversation = ChatReaction(messageID: message.id, scope: .direct, emoji: "👎",
                                             reactorID: harness.aliceID, reactorName: "Alice", at: .now)
        harness.bobWire.deliverRaw(.chatReaction(wrongConversation), from: harness.aliceID)
        let notEmoji = ChatReaction(messageID: message.id, scope: .community, emoji: "lol",
                                    reactorID: harness.aliceID, reactorName: "Alice", at: .now)
        harness.bobWire.deliverRaw(.chatReaction(notEmoji), from: harness.aliceID)
        let unknownID = UUID()
        let unknownMessage = ChatReaction(messageID: unknownID, scope: .community, emoji: "👍",
                                          reactorID: harness.aliceID, reactorName: "Alice", at: .now)
        harness.bobWire.deliverRaw(.chatReaction(unknownMessage), from: harness.aliceID)

        #expect(harness.bob.store.reactionGroups(for: message.id, me: harness.bobID).isEmpty)
        #expect(harness.bob.store.reactions[unknownID] == nil, "Reactions to messages Bob doesn't have aren't kept")
    }

    @Test("Reactions made while you were away arrive with the catch-up")
    func reactionsCatchUp() async throws {
        let harness = ChatHarness(connected: false)
        harness.alice.send("Lunch at 1?", to: .community)
        let message = try #require(harness.alice.store.messages(in: .community).first)
        harness.alice.toggleReaction("😂", on: message)

        harness.aliceWire.connectAndAnnounce()

        await waitUntil("Bob catches up with the reaction") {
            harness.bob.store.reactionGroups(for: message.id, me: harness.bobID).first?.emoji == "😂"
        }
    }

    @Test("Opening a conversation sends a read receipt; the sender sees Read")
    func readReceipts() async throws {
        let harness = ChatHarness()
        harness.alice.send("Did you see the brief?", to: .direct(harness.bobID))
        await waitUntil("delivered") {
            harness.alice.store.messages(in: .direct(harness.bobID)).first?.delivery == .delivered
        }

        harness.bob.activeConversation = .direct(harness.aliceID)

        await waitUntil("read") { harness.alice.store.messages(in: .direct(harness.bobID)).first?.delivery == .read }
        #expect(harness.alice.store.messages(in: .direct(harness.bobID)).first?.readAt != nil)

        // A later message is read straight away while the conversation stays open.
        harness.alice.send("Great, thanks", to: .direct(harness.bobID))
        await waitUntil("second read") {
            harness.alice.store.messages(in: .direct(harness.bobID)).last?.delivery == .read
        }
    }

    @Test("Typing shows on the other Mac, and stops when the draft is cleared or the message arrives")
    func typing() async throws {
        let harness = ChatHarness()
        let toBob = ConversationID.direct(harness.bobID)

        harness.alice.draftChanged(in: toBob, isEmpty: false)
        await waitUntil("Bob sees Alice typing") { harness.bob.isTyping(harness.aliceID) }
        harness.alice.draftChanged(in: toBob, isEmpty: true)
        await waitUntil("stopped") { !harness.bob.isTyping(harness.aliceID) }

        harness.alice.draftChanged(in: toBob, isEmpty: false)
        await waitUntil("typing again") { harness.bob.isTyping(harness.aliceID) }
        harness.alice.send("Done!", to: toBob)
        await waitUntil("the message replaces the indicator") {
            !harness.bob.isTyping(harness.aliceID) && harness.bobReceived.count == 1
        }
        #expect(!harness.alice.isTyping(harness.bobID))
    }

    @Test("No typing indicator when it's switched off, or for a Mac that doesn't understand it")
    func typingRespectsSettingAndCapability() async throws {
        let off = ChatHarness(aliceSendsTyping: false)
        off.alice.draftChanged(in: .direct(off.bobID), isEmpty: false)
        off.alice.send("ping", to: .direct(off.bobID))
        await waitUntil("message arrives") { off.bobReceived.count == 1 }
        #expect(!off.bob.isTyping(off.aliceID))

        let old = ChatHarness()
        old.bobWire.localPeer.supportsTyping = false
        old.alice.draftChanged(in: .direct(old.bobID), isEmpty: false)
        #expect(old.aliceWire.sentMessages.allSatisfy { $0.kind != .chatTyping }, "Older Macs are never sent chatTyping")
    }

    @Test("Replying from a notification marks the conversation read and sends a receipt")
    func replyFromNotification() async throws {
        let harness = ChatHarness()
        harness.alice.send("Free for a call?", to: .direct(harness.bobID))
        await waitUntil("Bob receives") { harness.bob.store.unreadCount(in: .direct(harness.aliceID)) == 1 }

        #expect(harness.bob.reply("Give me 5", in: .direct(harness.aliceID)))

        #expect(harness.bob.store.unreadCount(in: .direct(harness.aliceID)) == 0)
        await waitUntil("Alice sees Read and the reply") {
            harness.alice.store.messages(in: .direct(harness.bobID)).first?.delivery == .read
                && harness.alice.store.messages(in: .direct(harness.bobID)).last?.text == "Give me 5"
        }
    }

    @Test("With read receipts off, the sender only ever sees Delivered")
    func readReceiptsOff() async throws {
        let harness = ChatHarness(bobSendsReceipts: false)
        harness.alice.send("Private?", to: .direct(harness.bobID))
        await waitUntil("delivered") {
            harness.alice.store.messages(in: .direct(harness.bobID)).first?.delivery == .delivered
        }
        harness.bob.activeConversation = .direct(harness.aliceID)
        #expect(harness.bob.store.unreadCount(in: .direct(harness.aliceID)) == 0, "Still marked read locally")
        harness.alice.send("ping", to: .direct(harness.bobID))
        await waitUntil("second delivered") {
            harness.alice.store.messages(in: .direct(harness.bobID)).last?.delivery == .delivered
        }
        #expect(!harness.alice.store.messages(in: .direct(harness.bobID)).contains { $0.delivery == .read })
    }

    @Test("A live message claiming to be from someone else is dropped")
    func forgedSender() {
        let harness = ChatHarness()
        let forged = ChatPayload(id: UUID(), scope: .direct, senderID: UUID().uuidString, senderName: "CEO",
                                 text: "Send me the files", sentAt: .now)
        harness.bobWire.deliverRaw(.chat(forged), from: harness.aliceID)
        #expect(harness.bob.store.messages.isEmpty)
        #expect(harness.bobReceived.isEmpty)
    }

    @Test("A flood of messages from one Mac is cut off")
    func rateLimit() {
        let harness = ChatHarness()
        for index in 0..<(ProtocolLimits.maxChatMessagesPerWindow + 10) {
            let payload = ChatPayload(id: UUID(), scope: .community, senderID: harness.aliceID, senderName: "Alice",
                                      text: "spam \(index)", sentAt: .now)
            harness.bobWire.deliverRaw(.chat(payload), from: harness.aliceID)
        }
        #expect(harness.bob.store.messages(in: .community).count == ProtocolLimits.maxChatMessagesPerWindow)
    }

    @Test("An open, focused conversation is marked read as messages arrive")
    func activeConversation() async {
        let harness = ChatHarness()
        harness.bob.activeConversation = .direct(harness.aliceID)
        harness.alice.send("Seen?", to: .direct(harness.bobID))
        await waitUntil("Bob receives") { harness.bobReceived.count == 1 }
        #expect(harness.bob.store.unreadCount(in: .direct(harness.aliceID)) == 0)
    }

    @Test("Colleagues on an older DeskDrop can't be messaged and their messages queue")
    func needsUpdate() {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let (alice, bob) = LoopbackTransport.pair(in: root)
        let oldBob = PeerDevice(id: bob.localPeer.id, displayName: "Old Mac", deviceKind: .desktop, presence: .ready,
                                lastSeen: .now, supportsChat: false)
        let legacy = LegacyPeerTransport(wrapping: alice, peer: oldBob)
        let service = ChatService(transport: legacy, store: ChatStore(fileURL: root.url.appendingPathComponent("c.json"))) {
            (alice.localPeer.id, "Alice")
        }
        #expect(service.availability(of: oldBob.id) == .needsUpdate)
        service.send("hello?", to: .direct(oldBob.id))
        #expect(service.store.pending(for: oldBob.id).count == 1)
        #expect(legacy.sent.isEmpty)
    }
}

/// Reports the remote peer as an older DeskDrop without chat support.
@MainActor
private final class LegacyPeerTransport: ChatTransport {
    weak var chatDelegate: (any ChatTransportDelegate)?
    private let inner: LoopbackTransport
    private let legacyPeer: PeerDevice
    private(set) var sent: [ProtocolMessage] = []

    init(wrapping inner: LoopbackTransport, peer: PeerDevice) {
        self.inner = inner
        self.legacyPeer = peer
    }

    var readyPeers: [PeerDevice] { [legacyPeer] }
    func peer(for id: String) -> PeerDevice? { id == legacyPeer.id ? legacyPeer : nil }
    func send(_ message: ProtocolMessage, to peerID: String) throws { sent.append(message) }
}
