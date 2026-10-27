import Foundation
import Observation

/// Every chat conversation, saved as JSON in Application Support so history is
/// there each time DeskDrop opens. Writes are batched and atomic.
@MainActor
@Observable
final class ChatStore {
    /// Messages per conversation, oldest first.
    private(set) var messages: [ConversationID: [ChatMessage]] = [:]
    private(set) var lastRead: [ConversationID: Date] = [:]
    /// Last known display name for each colleague, so offline conversations still read well.
    private(set) var contacts: [String: String] = [:]
    /// Reactions per message: reactor installation ID → reaction.
    private(set) var reactions: [UUID: [String: StoredReaction]] = [:]

    struct StoredReaction: Codable, Equatable, Sendable {
        let emoji: String
        let name: String
        let at: Date
    }

    /// Reactions on one message, grouped by emoji in the order they first appeared.
    struct ReactionGroup: Identifiable, Equatable {
        let emoji: String
        let names: [String]
        let includesMe: Bool
        var id: String { emoji }
    }

    @ObservationIgnored private var knownIDs: Set<UUID> = []
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let timers = ScheduledTasks<Int>()

    /// Oldest messages beyond this are dropped from a conversation.
    static let perConversationLimit = 2000

    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DeskDrop", isDirectory: true)
            .appendingPathComponent("chat.json", isDirectory: false)
    }

    private struct Archive: Codable {
        var version = 2
        var messages: [ChatMessage]
        var lastRead: [String: Date]
        var contacts: [String: String]
        /// Added in version 2; absent from older files.
        var reactions: [String: [String: StoredReaction]]?
    }

    init(fileURL: URL = ChatStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Reading

    func contains(_ id: UUID) -> Bool {
        knownIDs.contains(id)
    }

    func messages(in conversation: ConversationID) -> [ChatMessage] {
        messages[conversation] ?? []
    }

    func lastMessage(in conversation: ConversationID) -> ChatMessage? {
        messages[conversation]?.last
    }

    func unreadCount(in conversation: ConversationID) -> Int {
        let since = lastRead[conversation] ?? .distantPast
        return messages[conversation]?.reduce(0) { count, message in
            count + (!message.isOutgoing && message.receivedAt > since ? 1 : 0)
        } ?? 0
    }

    var totalUnread: Int {
        messages.keys.reduce(0) { $0 + unreadCount(in: $1) }
    }

    /// One-on-one messages still waiting for `peerID` to connect, oldest first.
    func pending(for peerID: String) -> [ChatMessage] {
        messages(in: .direct(peerID)).filter { $0.isOutgoing && $0.delivery == .pending }
    }

    var latestCommunityDate: Date? {
        messages[.community]?.last?.sentAt
    }

    func message(_ id: UUID) -> ChatMessage? {
        guard knownIDs.contains(id) else { return nil }
        for list in messages.values {
            if let found = list.last(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// The newest message the other side sent in a conversation.
    func latestIncoming(in conversation: ConversationID) -> ChatMessage? {
        messages[conversation]?.last { !$0.isOutgoing }
    }

    func reactionGroups(for messageID: UUID, me: String) -> [ReactionGroup] {
        guard let byReactor = reactions[messageID], !byReactor.isEmpty else { return [] }
        let ordered = byReactor.sorted { $0.value.at < $1.value.at }
        var groups: [ReactionGroup] = []
        for (reactorID, reaction) in ordered {
            let name = reactorID == me ? String(localized: "You") : reaction.name
            if let index = groups.firstIndex(where: { $0.emoji == reaction.emoji }) {
                let group = groups[index]
                groups[index] = ReactionGroup(emoji: group.emoji, names: group.names + [name],
                                              includesMe: group.includesMe || reactorID == me)
            } else {
                groups.append(ReactionGroup(emoji: reaction.emoji, names: [name], includesMe: reactorID == me))
            }
        }
        return groups
    }

    func myReaction(to messageID: UUID, me: String) -> String? {
        reactions[messageID]?[me]?.emoji
    }

    func reactionMarks(for messageID: UUID) -> [ReactionMark] {
        (reactions[messageID] ?? [:]).map { ReactionMark(reactorID: $0.key, reactorName: $0.value.name, emoji: $0.value.emoji) }
    }

    func communityMessages(after date: Date?) -> [ChatMessage] {
        let all = messages(in: .community)
        guard let date else { return all }
        return all.filter { $0.sentAt > date }
    }

    // MARK: - Writing

    /// Stores a message in time order. Returns false for a duplicate.
    @discardableResult
    func insert(_ message: ChatMessage) -> Bool {
        guard knownIDs.insert(message.id).inserted else { return false }
        var list = messages[message.conversation] ?? []
        // Usually newest; history from other Macs may be older, so keep time order.
        let index = list.lastIndex { $0.sentAt <= message.sentAt }.map { $0 + 1 } ?? 0
        list.insert(message, at: index)
        if list.count > Self.perConversationLimit {
            let dropped = list.prefix(list.count - Self.perConversationLimit)
            dropped.forEach { knownIDs.remove($0.id); reactions[$0.id] = nil }
            list.removeFirst(dropped.count)
        }
        messages[message.conversation] = list
        scheduleSave()
        return true
    }

    /// Sets, changes or (with nil) removes one person's reaction to a message.
    /// Reactions to messages this Mac doesn't have are ignored.
    func setReaction(_ emoji: String?, by reactorID: String, name: String, on messageID: UUID, at date: Date = .now) {
        var byReactor = reactions[messageID] ?? [:]
        if let emoji {
            guard knownIDs.contains(messageID) else { return }
            if byReactor[reactorID] == nil, byReactor.count >= ProtocolLimits.maxReactionsPerMessage { return }
            guard byReactor[reactorID]?.emoji != emoji else { return }
            byReactor[reactorID] = StoredReaction(emoji: emoji, name: name, at: date)
        } else {
            guard byReactor.removeValue(forKey: reactorID) != nil else { return }
        }
        reactions[messageID] = byReactor.isEmpty ? nil : byReactor
        scheduleSave()
    }

    /// The colleague read your one-on-one messages up to `messageID`.
    func markReadByRecipient(in conversation: ConversationID, upTo messageID: UUID, at date: Date) {
        guard var list = messages[conversation],
              let target = list.first(where: { $0.id == messageID }) else { return }
        var changed = false
        for index in list.indices where list[index].isOutgoing && list[index].sentAt <= target.sentAt
            && list[index].delivery != .read {
            list[index].delivery = .read
            list[index].readAt = date
            changed = true
        }
        guard changed else { return }
        messages[conversation] = list
        scheduleSave()
    }

    /// Attaches a link preview to a message (once it's made, or when it arrives late).
    func setLink(_ link: LinkPreview, on id: UUID, in conversation: ConversationID) {
        guard var list = messages[conversation], let index = list.firstIndex(where: { $0.id == id }),
              list[index].link != link else { return }
        list[index].link = link
        messages[conversation] = list
        scheduleSave()
    }

    func updateDelivery(of id: UUID, in conversation: ConversationID, to delivery: ChatMessage.Delivery) {
        guard var list = messages[conversation], let index = list.firstIndex(where: { $0.id == id }),
              list[index].isOutgoing else { return }
        // Never go backwards (e.g. a late "sent" after "delivered").
        let order: [ChatMessage.Delivery] = [.pending, .sent, .delivered, .read]
        let current = list[index].delivery.flatMap { order.firstIndex(of: $0) } ?? 0
        guard let next = order.firstIndex(of: delivery), next > current else { return }
        list[index].delivery = delivery
        messages[conversation] = list
        scheduleSave()
    }

    func markRead(_ conversation: ConversationID) {
        guard unreadCount(in: conversation) > 0 || lastRead[conversation] == nil else { return }
        lastRead[conversation] = .now
        scheduleSave()
    }

    func remember(name: String, for peerID: String) {
        guard contacts[peerID] != name else { return }
        contacts[peerID] = name
        scheduleSave()
    }

    func deleteConversation(_ conversation: ConversationID) {
        messages[conversation]?.forEach {
            knownIDs.remove($0.id)
            reactions[$0.id] = nil
        }
        messages[conversation] = nil
        lastRead[conversation] = nil
        scheduleSave()
    }

    func clearAll() {
        messages.removeAll()
        lastRead.removeAll()
        reactions.removeAll()
        knownIDs.removeAll()
        scheduleSave()
    }

    /// Writes immediately, e.g. when the app quits.
    func flush() {
        timers.cancel(0)
        save()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        timers.schedule(0, after: .milliseconds(400)) { [weak self] in
            self?.save()
        }
    }

    private func save() {
        let archive = Archive(messages: messages.values.flatMap { $0 },
                              lastRead: Dictionary(uniqueKeysWithValues: lastRead.map { ($0.key.rawValue, $0.value) }),
                              contacts: contacts,
                              reactions: Dictionary(uniqueKeysWithValues: reactions.map { ($0.key.uuidString, $0.value) }))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(archive).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Chat history could not be saved: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let archive = try decoder.decode(Archive.self, from: data)
            var grouped: [ConversationID: [ChatMessage]] = [:]
            for message in archive.messages where knownIDs.insert(message.id).inserted {
                grouped[message.conversation, default: []].append(message)
            }
            messages = grouped.mapValues { $0.sorted { $0.sentAt < $1.sentAt } }
            lastRead = Dictionary(uniqueKeysWithValues: archive.lastRead.map { (ConversationID(rawValue: $0.key), $0.value) })
            contacts = archive.contacts
            for (key, value) in archive.reactions ?? [:] {
                if let id = UUID(uuidString: key), knownIDs.contains(id), !value.isEmpty { reactions[id] = value }
            }
        } catch {
            // Keep the unreadable file for inspection rather than silently losing it.
            Log.app.error("Chat history could not be read; starting fresh")
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }
}
