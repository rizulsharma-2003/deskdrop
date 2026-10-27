import Foundation
import Observation

/// The part of the network chat needs. `PeerConnectionService` provides it; tests
/// use the in-process loopback.
@MainActor
protocol ChatTransport: AnyObject {
    var chatDelegate: (any ChatTransportDelegate)? { get set }
    var readyPeers: [PeerDevice] { get }
    func peer(for id: String) -> PeerDevice?
    func send(_ message: ProtocolMessage, to peerID: String) throws
}

@MainActor
protocol ChatTransportDelegate: AnyObject {
    func chatTransport(didReceive message: ProtocolMessage, from peerID: String)
    func chatTransportPeerBecameReady(_ peerID: String)
}

/// Whether a one-on-one message can go out right now.
enum ChatAvailability: Equatable {
    case available
    /// Messages wait in the outbox until the colleague connects.
    case offline
    /// The colleague's DeskDrop is too old to chat.
    case needsUpdate
}

/// Runs chat between nearby Macs.
///
/// - **One-on-one:** sent straight to the colleague. If they aren't connected, the
///   message waits (shown as pending) and goes out as soon as they are. Their Mac
///   acknowledges each message once stored.
/// - **Community ("Everyone nearby"):** sent to everyone connected. When two Macs
///   connect, each asks the other for community messages it may have missed, so
///   people who were away catch up.
///
/// Everything received is validated and rate-limited. As with file transfers,
/// display names are not verified identities.
@MainActor
@Observable
final class ChatService {
    let store: ChatStore

    /// The conversation on screen in a focused window; its messages count as read.
    var activeConversation: ConversationID? {
        didSet {
            guard let activeConversation else { return }
            store.markRead(activeConversation)
            sendReadReceiptIfNeeded(for: activeConversation)
        }
    }

    @ObservationIgnored var onMessageReceived: ((ChatMessage) -> Void)?

    /// Colleagues typing a one-on-one message to you right now.
    private(set) var typingPeers: Set<String> = []

    func isTyping(_ peerID: String) -> Bool { typingPeers.contains(peerID) }

    /// Your messages waiting for their link preview before they go out.
    private(set) var preparingPreviews: Set<UUID> = []

    func isPreparingPreview(_ id: UUID) -> Bool { preparingPreviews.contains(id) }

    /// Replying from a notification counts as reading the conversation, as in Messages.
    @discardableResult
    func reply(_ text: String, in conversation: ConversationID) -> Bool {
        store.markRead(conversation)
        sendReadReceiptIfNeeded(for: conversation)
        return send(text, to: conversation)
    }

    /// Profile photos and sticker images (nil in tests that don't need them).
    @ObservationIgnored let media: MediaExchange?
    /// Makes a preview for a link you send, or nil (previews off, or the page
    /// had nothing to show). Nil in tests that don't need previews.
    @ObservationIgnored private let makeLinkPreview: (@MainActor (URL) async -> LinkPreview?)?
    @ObservationIgnored private let transport: any ChatTransport
    @ObservationIgnored private let identity: () -> (id: String, name: String)
    @ObservationIgnored private let sendsReadReceipts: () -> Bool
    @ObservationIgnored private let sendsTyping: () -> Bool
    /// When each colleague was last told you're typing; nil once told you stopped.
    @ObservationIgnored private var typingSentAt: [String: TimeInterval] = [:]
    /// Clears a colleague's typing state if no update arrives in time.
    @ObservationIgnored private var typingExpiry: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var arrivals: [String: [TimeInterval]] = [:]
    /// One-on-one reactions waiting for their colleague to connect.
    @ObservationIgnored private var pendingReactions: [String: [ChatReaction]] = [:]
    /// The last message each colleague has been told you read.
    @ObservationIgnored private var receiptSent: [String: UUID] = [:]

    init(transport: any ChatTransport, store: ChatStore, media: MediaExchange? = nil,
         linkPreviews: (@MainActor (URL) async -> LinkPreview?)? = nil,
         sendsReadReceipts: @escaping () -> Bool = { true },
         sendsTyping: @escaping () -> Bool = { true },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         identity: @escaping () -> (id: String, name: String)) {
        self.transport = transport
        self.store = store
        self.media = media
        self.makeLinkPreview = linkPreviews
        self.identity = identity
        self.sendsReadReceipts = sendsReadReceipts
        self.sendsTyping = sendsTyping
        self.clock = clock
        transport.chatDelegate = self
    }

    var myID: String { identity().id }

    // MARK: - Sending

    /// Sends `text` to a conversation. Returns false if there was nothing to send.
    @discardableResult
    func send(_ text: String, to conversation: ConversationID) -> Bool {
        guard let text = ChatValidator.sanitizeText(text) else { return false }
        post(text, media: nil, to: conversation)
        return true
    }

    /// Sends a GIF or sticker. Macs too old to show it get a description instead.
    @discardableResult
    func send(_ media: ChatMedia, to conversation: ConversationID) -> Bool {
        guard let media = media.validated() else { return false }
        post(media.fallbackText, media: media, to: conversation)
        return true
    }

    /// How long a message waits for its link preview before going without one.
    static let linkPreviewTimeout: Duration = .seconds(8)

    private func post(_ text: String, media: ChatMedia?, to conversation: ConversationID) {
        let me = identity()
        let now = Date.now
        let message = ChatMessage(id: UUID(), conversation: conversation, senderID: me.id, senderName: me.name,
                                  text: text, sentAt: now, receivedAt: now, isOutgoing: true,
                                  delivery: conversation.isCommunity ? nil : .pending, media: media)
        store.insert(message)
        store.markRead(conversation)
        if media == nil, let makeLinkPreview, let url = LinkPreview.firstLink(in: text) {
            // Shown at once, sent once the preview is ready (or the wait runs out).
            preparingPreviews.insert(message.id)
            Task { @MainActor [weak self] in
                let preview = await Self.withTimeout(Self.linkPreviewTimeout) { await makeLinkPreview(url) }
                guard let self else { return }
                if let preview = preview?.validated(for: text) {
                    self.store.setLink(preview, on: message.id, in: conversation)
                }
                self.preparingPreviews.remove(message.id)
                self.dispatch(message.id, in: conversation)
            }
            return
        }
        dispatch(message.id, in: conversation)
        // The message itself ends the typing indicator on their side.
        if let peerID = conversation.peerID { typingSentAt[peerID] = nil }
    }

    /// Sends a message you wrote: to the colleague, or to everyone connected.
    private func dispatch(_ id: UUID, in conversation: ConversationID) {
        guard let message = store.messages(in: conversation).last(where: { $0.id == id }) else { return }
        if let peerID = conversation.peerID {
            deliver(message, to: peerID)
        } else {
            // Colleagues who aren't here now get it when they connect (see `chatSync`).
            for peer in transport.readyPeers where peer.supportsChat {
                try? transport.send(.chat(message.payload()), to: peer.id)
            }
        }
    }

    /// The result of `operation`, or nil if it takes longer than `limit`.
    private static func withTimeout<T: Sendable>(_ limit: Duration,
                                                 _ operation: @escaping @MainActor () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Typing

    /// How often "still typing" is repeated, and how long the indicator lasts
    /// without one (so it never sticks if "stopped" is lost).
    static let typingRefresh: TimeInterval = 3
    static let typingTimeout: Duration = .seconds(6)

    /// Call whenever the draft in a one-on-one conversation changes. Tells the
    /// colleague you're typing (at most every few seconds), or that you stopped
    /// once the draft is empty again.
    func draftChanged(in conversation: ConversationID, isEmpty: Bool) {
        guard let peerID = conversation.peerID else { return }
        if isEmpty {
            guard typingSentAt.removeValue(forKey: peerID) != nil else { return }
            sendTyping(false, to: peerID)
            return
        }
        guard sendsTyping() else { return }
        let now = clock()
        if let last = typingSentAt[peerID], now - last < Self.typingRefresh { return }
        if sendTyping(true, to: peerID) { typingSentAt[peerID] = now }
    }

    @discardableResult
    private func sendTyping(_ isTyping: Bool, to peerID: String) -> Bool {
        guard let peer = transport.peer(for: peerID), peer.presence == .ready, peer.supportsTyping else { return false }
        do {
            try transport.send(.chatTyping(isTyping), to: peerID)
            return true
        } catch {
            return false
        }
    }

    private func setTyping(_ isTyping: Bool, for peerID: String) {
        typingExpiry.removeValue(forKey: peerID)?.cancel()
        guard isTyping else {
            typingPeers.remove(peerID)
            return
        }
        typingPeers.insert(peerID)
        typingExpiry[peerID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.typingTimeout)
            guard !Task.isCancelled else { return }
            self?.typingPeers.remove(peerID)
        }
    }

    #if DEBUG
    /// UI tests only: show a colleague as typing (no expiry).
    func showTypingForUITesting(_ peerID: String) {
        typingPeers.insert(peerID)
    }
    #endif

    func availability(of peerID: String) -> ChatAvailability {
        guard let peer = transport.peer(for: peerID), peer.presence == .ready else { return .offline }
        return peer.supportsChat ? .available : .needsUpdate
    }

    var nearbyChatPeers: [PeerDevice] {
        transport.readyPeers.filter(\.supportsChat)
    }

    private func deliver(_ message: ChatMessage, to peerID: String) {
        guard availability(of: peerID) == .available else { return }
        do {
            try transport.send(.chat(message.payload()), to: peerID)
            store.updateDelivery(of: message.id, in: message.conversation, to: .sent)
        } catch {
            Log.transfer.info("Chat message stays queued: peer not reachable")
        }
    }

    // MARK: - Reactions

    /// Reacts to a message, or removes your reaction with nil. Choosing the reaction
    /// you already have removes it, as in Messages.
    func toggleReaction(_ emoji: String, on message: ChatMessage) {
        let current = store.myReaction(to: message.id, me: myID)
        react(current == emoji ? nil : emoji, to: message)
    }

    func react(_ emoji: String?, to message: ChatMessage) {
        let clean = emoji.flatMap(ChatValidator.sanitizeEmoji)
        guard emoji == nil || clean != nil else { return }
        let me = identity()
        let now = Date.now
        store.setReaction(clean, by: me.id, name: me.name, on: message.id, at: now)
        let reaction = ChatReaction(messageID: message.id, scope: message.conversation.isCommunity ? .community : .direct,
                                    emoji: clean, reactorID: me.id, reactorName: me.name, at: now)
        if let peerID = message.conversation.peerID {
            if availability(of: peerID) == .available {
                try? transport.send(.chatReaction(reaction), to: peerID)
            } else {
                pendingReactions[peerID, default: []].append(reaction)
            }
        } else {
            // Colleagues who aren't here pick reactions up with the history.
            for peer in nearbyChatPeers {
                try? transport.send(.chatReaction(reaction), to: peer.id)
            }
        }
    }

    private func receiveReaction(_ reaction: ChatReaction, from peerID: String) {
        guard reaction.reactorID == peerID, allowArrival(from: peerID) else { return }
        let emoji = reaction.emoji.flatMap(ChatValidator.sanitizeEmoji)
        guard reaction.emoji == nil || emoji != nil else { return }
        // A reaction can only touch a message you have, in the conversation it belongs to.
        let expected: ConversationID = reaction.scope == .direct ? .direct(peerID) : .community
        guard store.message(reaction.messageID)?.conversation == expected else { return }
        let name = NameSanitizer.sanitizeDisplayName(reaction.reactorName) ?? "Mac"
        store.setReaction(emoji, by: peerID, name: name, on: reaction.messageID, at: min(reaction.at, .now))
    }

    // MARK: - Read receipts

    /// Tells the colleague you've read their latest message, once per message,
    /// when read receipts are on and they're connected.
    private func sendReadReceiptIfNeeded(for conversation: ConversationID) {
        guard sendsReadReceipts(), let peerID = conversation.peerID,
              let latest = store.latestIncoming(in: conversation),
              store.unreadCount(in: conversation) == 0,
              receiptSent[peerID] != latest.id,
              availability(of: peerID) == .available else { return }
        do {
            try transport.send(.chatRead(ChatReadReceipt(lastReadMessageID: latest.id, readAt: .now)), to: peerID)
            receiptSent[peerID] = latest.id
        } catch {
            Log.transfer.info("Read receipt not sent: peer not reachable")
        }
    }

    // MARK: - Receiving

    private func receiveLive(_ payload: ChatPayload, from peerID: String) {
        // Live messages must come from the Mac that wrote them.
        guard payload.senderID == peerID, allowArrival(from: peerID),
              let clean = ChatValidator.validate(payload) else {
            Log.transfer.error("Dropped an invalid or excessive chat message")
            return
        }
        let conversation: ConversationID = clean.scope == .direct ? .direct(peerID) : .community
        if clean.scope == .direct {
            // Acknowledge duplicates too: the sender may have missed the first receipt.
            try? transport.send(.chatAck(messageID: clean.id), to: peerID)
        }
        store.remember(name: clean.senderName, for: peerID)
        let message = ChatMessage(id: clean.id, conversation: conversation, senderID: clean.senderID,
                                  senderName: clean.senderName, text: clean.text, sentAt: clean.sentAt,
                                  receivedAt: .now, isOutgoing: false, delivery: nil, media: clean.media, link: clean.link)
        let hashes = (clean.media?.hash.map { [$0] } ?? []) + (clean.link?.imageHashes ?? [])
        guard store.insert(message) else {
            // Already here without its preview (e.g. from a catch-up while the sender
            // was still making it): take the preview from the author's own copy.
            if let link = clean.link, let existing = store.message(clean.id), existing.conversation == conversation,
               existing.senderID == peerID, existing.link == nil {
                store.setLink(link, on: clean.id, in: conversation)
                link.imageHashes.forEach { media?.want($0, from: peerID) }
            }
            return
        }
        hashes.forEach { media?.want($0, from: peerID) }
        if activeConversation == conversation {
            store.markRead(conversation)
            sendReadReceiptIfNeeded(for: conversation)
        }
        onMessageReceived?(message)
    }

    /// Community messages relayed from another Mac's history. They may have been
    /// written by someone who isn't connected now.
    private func receiveHistory(_ payloads: [ChatPayload], from peerID: String) {
        guard payloads.count <= ProtocolLimits.chatHistoryBatch else { return }
        let me = identity().id
        for payload in payloads where payload.scope == .community {
            if !store.contains(payload.id) {
                guard let clean = ChatValidator.validate(payload) else { continue }
                let mine = clean.senderID == me
                if !mine { store.remember(name: clean.senderName, for: clean.senderID) }
                store.insert(ChatMessage(id: clean.id, conversation: .community, senderID: clean.senderID,
                                         senderName: clean.senderName, text: clean.text, sentAt: clean.sentAt,
                                         receivedAt: mine ? clean.sentAt : .now, isOutgoing: mine, delivery: nil,
                                         media: clean.media, link: clean.link))
                // The Mac relaying history may have the sticker or preview images too.
                let hashes = (clean.media?.hash.map { [$0] } ?? []) + (clean.link?.imageHashes ?? [])
                hashes.forEach { media?.want($0, from: peerID) }
            }
            // Pick up reactions others made while you were away (never overwrite your own).
            guard store.message(payload.id)?.conversation == .community else { continue }
            for mark in (payload.reactions ?? []).prefix(ProtocolLimits.maxReactionsPerMessage) where mark.reactorID != me {
                guard UUID(uuidString: mark.reactorID) != nil,
                      let emoji = ChatValidator.sanitizeEmoji(mark.emoji),
                      store.reactions[payload.id]?[mark.reactorID] == nil else { continue }
                store.setReaction(emoji, by: mark.reactorID,
                                  name: NameSanitizer.sanitizeDisplayName(mark.reactorName) ?? "Mac", on: payload.id)
            }
        }
        if activeConversation == .community { store.markRead(.community) }
    }

    private func answerSync(_ request: ChatSyncRequest, to peerID: String) {
        let history = store.communityMessages(after: request.communitySince)
            .suffix(ProtocolLimits.maxChatHistoryOnSync)
            .map { message in
                var payload = message.payload()
                let marks = store.reactionMarks(for: message.id)
                payload.reactions = marks.isEmpty ? nil : marks
                return payload
            }
        var batch: [ChatPayload] = []
        for payload in history {
            batch.append(payload)
            if batch.count == ProtocolLimits.chatHistoryBatch {
                try? transport.send(.chatHistory(batch), to: peerID)
                batch.removeAll()
            }
        }
        if !batch.isEmpty { try? transport.send(.chatHistory(batch), to: peerID) }
    }

    private func allowArrival(from peerID: String) -> Bool {
        let now = clock()
        var recent = (arrivals[peerID] ?? []).filter { now - $0 < ProtocolLimits.chatRateWindow }
        guard recent.count < ProtocolLimits.maxChatMessagesPerWindow else {
            arrivals[peerID] = recent
            return false
        }
        recent.append(now)
        arrivals[peerID] = recent
        return true
    }
}

extension ChatService: ChatTransportDelegate {
    func chatTransport(didReceive message: ProtocolMessage, from peerID: String) {
        switch message {
        case .chat(let payload):
            if payload.scope == .direct { setTyping(false, for: peerID) }
            receiveLive(payload, from: peerID)
        case .chatTyping(let isTyping):
            // Only one-on-one, and only from someone who could message you.
            guard transport.peer(for: peerID)?.supportsChat == true else { return }
            setTyping(isTyping, for: peerID)
        case .chatAck(let id):
            store.updateDelivery(of: id, in: .direct(peerID), to: .delivered)
        case .chatSync(let request):
            answerSync(request, to: peerID)
        case .chatHistory(let payloads):
            receiveHistory(payloads, from: peerID)
        case .chatReaction(let reaction):
            receiveReaction(reaction, from: peerID)
        case .chatRead(let receipt):
            store.markReadByRecipient(in: .direct(peerID), upTo: receipt.lastReadMessageID, at: min(receipt.readAt, .now))
        case .avatar, .mediaRequest, .media:
            media?.receive(message, from: peerID)
        default:
            break
        }
    }

    /// Flushes the outbox and catches up on community messages.
    func chatTransportPeerBecameReady(_ peerID: String) {
        guard let peer = transport.peer(for: peerID) else { return }
        store.remember(name: peer.displayName, for: peerID)
        media?.peerBecameReady(peerID)
        guard peer.supportsChat else { return }
        // Messages still waiting for a link preview go out when it's ready.
        for message in store.pending(for: peerID) where !preparingPreviews.contains(message.id) {
            deliver(message, to: peerID)
        }
        for reaction in pendingReactions.removeValue(forKey: peerID) ?? [] {
            try? transport.send(.chatReaction(reaction), to: peerID)
        }
        sendReadReceiptIfNeeded(for: .direct(peerID))
        // Overlap by an hour so clock differences between Macs can't hide messages;
        // duplicates are ignored by ID.
        let since = store.latestCommunityDate.map { $0.addingTimeInterval(-3600) }
        try? transport.send(.chatSync(ChatSyncRequest(communitySince: since)), to: peerID)
    }
}

/// Cleans chat text and checks incoming messages.
enum ChatValidator {
    /// NFC-normalized, no control characters except newlines and tabs, no bidi
    /// overrides, trimmed. Nil when nothing is left.
    static func sanitizeText(_ raw: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar {
            case "\n", "\t":
                scalars.append(scalar)
            case "\r":
                continue
            default:
                if scalar.properties.generalCategory == .control || NameSanitizer.isBidiControl(scalar) { continue }
                scalars.append(scalar)
            }
        }
        let text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(ProtocolLimits.maxChatCharacters))
    }

    /// A single emoji (one grapheme, at most 32 bytes), or nil.
    static func sanitizeEmoji(_ raw: String) -> String? {
        let emoji = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard emoji.count == 1, emoji.utf8.count <= 32, let first = emoji.unicodeScalars.first,
              first.properties.isEmoji,
              emoji.unicodeScalars.count > 1 || first.properties.isEmojiPresentation || first.value >= 0x2000 else { return nil }
        return emoji
    }

    /// A cleaned copy of an incoming message, or nil if it should be dropped.
    static func validate(_ payload: ChatPayload, now: Date = .now) -> ChatPayload? {
        guard UUID(uuidString: payload.senderID) != nil,
              payload.text.count <= ProtocolLimits.maxChatCharacters,
              let text = sanitizeText(payload.text),
              payload.sentAt > Date(timeIntervalSince1970: 1_600_000_000) else { return nil }
        // Clocks differ between Macs, but a message can't come from the future.
        let sentAt = min(payload.sentAt, now.addingTimeInterval(60))
        // Media that can't be shown safely is dropped; the text describes it. A link
        // preview must belong to the first link in the text.
        return ChatPayload(id: payload.id, scope: payload.scope, senderID: payload.senderID,
                           senderName: NameSanitizer.sanitizeDisplayName(payload.senderName) ?? "Mac",
                           text: text, sentAt: sentAt, media: payload.media?.validated(),
                           link: payload.media == nil ? payload.link?.validated(for: text) : nil)
    }
}
