import Foundation

/// A conversation: everyone nearby, or one colleague.
struct ConversationID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let community = ConversationID(rawValue: "community")

    static func direct(_ peerID: String) -> ConversationID {
        ConversationID(rawValue: "direct:\(peerID)")
    }

    var isCommunity: Bool { self == .community }

    /// The colleague's installation ID for a one-on-one conversation.
    var peerID: String? {
        rawValue.hasPrefix("direct:") ? String(rawValue.dropFirst("direct:".count)) : nil
    }
}

/// A chat message as it travels between Macs.
struct ChatPayload: Codable, Equatable, Sendable {
    enum Scope: String, Codable, Sendable {
        case direct
        case community
    }

    let id: UUID
    let scope: Scope
    /// Installation ID of the Mac that wrote the message.
    let senderID: String
    let senderName: String
    let text: String
    let sentAt: Date
    /// Reactions known so far; only filled in when catching up on history.
    var reactions: [ReactionMark]? = nil
    /// A GIF or sticker (1.7 and later). `text` then holds a description that
    /// older versions show instead.
    var media: ChatMedia? = nil
    /// A preview of the first link in `text` (1.7 and later).
    var link: LinkPreview? = nil
}

/// One person's reaction to a message, as carried in history.
struct ReactionMark: Codable, Equatable, Sendable {
    let reactorID: String
    let reactorName: String
    let emoji: String
}

/// Someone reacted to a message (or removed their reaction when `emoji` is nil).
struct ChatReaction: Codable, Equatable, Sendable {
    let messageID: UUID
    let scope: ChatPayload.Scope
    let emoji: String?
    let reactorID: String
    let reactorName: String
    let at: Date
}

/// "I've read your messages up to this one" for one-on-one conversations.
struct ChatReadReceipt: Codable, Equatable, Sendable {
    let lastReadMessageID: UUID
    let readAt: Date
}

/// Sent when two Macs connect: "send me the community messages I may have missed".
struct ChatSyncRequest: Codable, Equatable, Sendable {
    /// Community messages written after this time are wanted; nil means all you have.
    let communitySince: Date?
}

/// A message kept on this Mac.
struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    /// Delivery of a one-on-one message this Mac sent.
    enum Delivery: String, Codable, Sendable {
        /// Waiting for the colleague to connect.
        case pending
        /// Handed to their Mac.
        case sent
        /// Their Mac confirmed it stored the message.
        case delivered
        /// They opened the conversation (only if they send read receipts).
        case read
    }

    let id: UUID
    let conversation: ConversationID
    let senderID: String
    var senderName: String
    let text: String
    let sentAt: Date
    /// When this Mac stored it; drives unread counts so clock differences don't matter.
    let receivedAt: Date
    let isOutgoing: Bool
    var delivery: Delivery?
    /// When the recipient read this message, for one-on-one messages you sent.
    var readAt: Date?
    /// A GIF or sticker, shown instead of `text`.
    var media: ChatMedia? = nil
    /// A preview of the first link in `text`.
    var link: LinkPreview? = nil

    func payload() -> ChatPayload {
        ChatPayload(id: id, scope: conversation.isCommunity ? .community : .direct, senderID: senderID,
                    senderName: senderName, text: text, sentAt: sentAt, media: media, link: link)
    }

    /// One line for the conversation list and notifications: "GIF", "Sticker",
    /// or the text without Markdown symbols.
    var previewText: String {
        switch media?.kind {
        case .gif?: String(localized: "GIF")
        case .sticker?: String(localized: "Sticker")
        default: MessageMarkdown.plainText(text)
        }
    }
}
