import Foundation

/// Every message DeskDrop peers exchange. Encoded by `ProtocolCodec` inside a
/// versioned envelope; see docs/NETWORKING.md for the wire format.
enum ProtocolMessage: Equatable, Sendable {
    /// Handshake: identifies the installation and confirms the protocol version.
    case hello(Hello)
    /// Sender → recipient: metadata for a proposed transfer. No file contents.
    case offer(TransferOffer)
    /// Recipient → sender: go ahead and send the files.
    case accept(transferID: UUID)
    /// Recipient → sender: the offer was refused.
    case decline(transferID: UUID, reason: DeclineReason)
    /// Either side: stop this transfer.
    case cancel(transferID: UUID)
    /// Recipient → sender: every file was written, verified and saved.
    case complete(transferID: UUID)
    /// Either side: the transfer cannot continue.
    case failure(transferID: UUID, reason: FailureReason)
    /// A chat message, to one colleague or to everyone nearby.
    case chat(ChatPayload)
    /// Recipient → sender: a one-on-one message was stored.
    case chatAck(messageID: UUID)
    /// On connecting: ask for community messages this Mac may have missed.
    case chatSync(ChatSyncRequest)
    /// A batch of community messages answering `chatSync`.
    case chatHistory([ChatPayload])
    /// Someone added, changed or removed a reaction.
    case chatReaction(ChatReaction)
    /// One-on-one: the recipient has read up to a message.
    case chatRead(ChatReadReceipt)
    /// One-on-one: started (true) or stopped (false) typing. Only sent to Macs
    /// that announce the "typing" capability.
    case chatTyping(Bool)
    /// My profile photo's hash (or none). Only sent to Macs that announce "avatar".
    case avatar(AvatarInfo)
    /// "Send me the image with this hash": a profile photo or a sticker.
    case mediaRequest(hash: String)
    /// The image answering `mediaRequest`.
    case media(MediaBlob)
    /// "I have this signed DeskDrop update." Only sent to Macs that announce "update".
    case updateAvailable(UpdateOffer)
    /// "Send me that update." Answered with a resource named `update/<version>`.
    case updateRequest(version: String)

    enum Kind: String, Codable, Sendable, CaseIterable {
        case hello, offer, accept, decline, cancel, complete, failure
        case chat, chatAck, chatSync, chatHistory, chatReaction, chatRead, chatTyping
        case avatar, mediaRequest, media
        case updateAvailable, updateRequest
    }

    /// Updates are handled by `UpdateService`.
    var isUpdate: Bool {
        kind == .updateAvailable || kind == .updateRequest
    }

    /// Chat messages (and the photos and stickers that go with them) are handled
    /// by `ChatService`; everything else by `TransferService`.
    var isChat: Bool {
        switch kind {
        case .chat, .chatAck, .chatSync, .chatHistory, .chatReaction, .chatRead, .chatTyping,
             .avatar, .mediaRequest, .media: true
        default: false
        }
    }

    var kind: Kind {
        switch self {
        case .hello: .hello
        case .offer: .offer
        case .accept: .accept
        case .decline: .decline
        case .cancel: .cancel
        case .complete: .complete
        case .failure: .failure
        case .chat: .chat
        case .chatAck: .chatAck
        case .chatSync: .chatSync
        case .chatHistory: .chatHistory
        case .chatReaction: .chatReaction
        case .chatRead: .chatRead
        case .chatTyping: .chatTyping
        case .avatar: .avatar
        case .mediaRequest: .mediaRequest
        case .media: .media
        case .updateAvailable: .updateAvailable
        case .updateRequest: .updateRequest
        }
    }

    var transferID: UUID? {
        switch self {
        case .hello, .chat, .chatAck, .chatSync, .chatHistory, .chatReaction, .chatRead, .chatTyping,
             .avatar, .mediaRequest, .media, .updateAvailable, .updateRequest: nil
        case .offer(let offer): offer.transferID
        case .accept(let id), .decline(let id, _), .cancel(let id), .complete(let id), .failure(let id, _): id
        }
    }
}
