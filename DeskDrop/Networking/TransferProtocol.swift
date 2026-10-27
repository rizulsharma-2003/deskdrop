import Foundation

/// Hard limits applied to everything that arrives from the network.
enum ProtocolLimits {
    /// Largest control message accepted. Resources (file contents) are not messages.
    static let maxMessageBytes = 1 << 20
    static let maxFilesPerTransfer = 1000
    static let maxPathBytes = 1024
    static let maxComponentBytes = 255
    static let maxPathDepth = 32
    static let maxFileSize: Int64 = 1 << 40
    static let maxDisplayNameLength = 32
    static let maxTypeIdentifierLength = 128
    static let maxAppVersionLength = 32
    /// Offers from one peer still waiting for a decision before new ones are refused.
    static let maxPendingOffersPerPeer = 5

    /// Longest chat message, in characters.
    static let maxChatCharacters = 4000
    /// Messages per `chatHistory` batch (keeps each batch well under `maxMessageBytes`).
    static let chatHistoryBatch = 40
    /// Most community messages sent to a colleague when they connect.
    static let maxChatHistoryOnSync = 400
    /// Live chat messages accepted from one peer per `chatRateWindow` seconds.
    static let maxChatMessagesPerWindow = 30
    static let chatRateWindow: TimeInterval = 10
    /// Reactors remembered per message (and accepted in one history entry).
    static let maxReactionsPerMessage = 50
    /// Largest profile photo or sticker image carried between Macs. Base64 in
    /// JSON keeps it under `maxMessageBytes`.
    static let maxMediaBytes = 600_000
    /// Largest image width or height accepted from another Mac.
    static let maxMediaDimension = 1024
    /// Image requests answered for one peer per `chatRateWindow` seconds.
    static let maxMediaRequestsPerWindow = 40

    /// How long a recipient has to accept or decline.
    static let offerTimeout: Duration = .seconds(120)
    /// No measurable progress for this long fails the transfer.
    static let stallTimeout: TimeInterval = 60
    /// How long the sender waits for the recipient to verify and acknowledge.
    static let completionTimeout: Duration = .seconds(300)
    /// How long a prepared transfer waits for its recipient to (re)connect.
    static let connectionWaitTimeout: Duration = .seconds(20)
}

enum ProtocolError: Error, Equatable {
    case tooLarge(Int)
    case malformed
    case unsupportedVersion(Int)
    case unknownMessageType(String)
    case missingField(String)
}

/// Encodes and strictly decodes `ProtocolMessage`s.
///
/// Wire format (JSON):
/// `{"v":1,"type":"accept","transferID":"…"}`
/// The version is checked before anything else so a future, incompatible envelope
/// produces a clear `unsupportedVersion` error rather than a vague decoding failure.
enum ProtocolCodec {
    static let currentVersion = 1
    static let supportedVersions: ClosedRange<Int> = 1...1

    private struct VersionProbe: Decodable {
        let v: Int
        let type: String
    }

    private struct Envelope: Codable {
        var v: Int
        var type: ProtocolMessage.Kind
        var hello: Hello?
        var offer: TransferOffer?
        var transferID: UUID?
        var declineReason: DeclineReason?
        var failureReason: FailureReason?
        var chat: ChatPayload?
        var messageID: UUID?
        var chatSync: ChatSyncRequest?
        var chatHistory: [ChatPayload]?
        var chatReaction: ChatReaction?
        var chatRead: ChatReadReceipt?
        var typing: Bool?
        var avatar: AvatarInfo?
        var hash: String?
        var media: MediaBlob?
        var update: UpdateOffer?
        var version: String?
    }

    static func encode(_ message: ProtocolMessage) throws -> Data {
        var envelope = Envelope(v: currentVersion, type: message.kind)
        switch message {
        case .hello(let hello):
            envelope.hello = hello
        case .offer(let offer):
            envelope.offer = offer
        case .accept(let id), .cancel(let id), .complete(let id):
            envelope.transferID = id
        case .decline(let id, let reason):
            envelope.transferID = id
            envelope.declineReason = reason
        case .failure(let id, let reason):
            envelope.transferID = id
            envelope.failureReason = reason
        case .chat(let payload):
            envelope.chat = payload
        case .chatAck(let id):
            envelope.messageID = id
        case .chatSync(let request):
            envelope.chatSync = request
        case .chatHistory(let payloads):
            envelope.chatHistory = payloads
        case .chatReaction(let reaction):
            envelope.chatReaction = reaction
        case .chatRead(let receipt):
            envelope.chatRead = receipt
        case .chatTyping(let isTyping):
            envelope.typing = isTyping
        case .avatar(let info):
            envelope.avatar = info
        case .mediaRequest(let hash):
            envelope.hash = hash
        case .media(let blob):
            envelope.media = blob
        case .updateAvailable(let offer):
            envelope.update = offer
        case .updateRequest(let version):
            envelope.version = version
        }
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= ProtocolLimits.maxMessageBytes else { throw ProtocolError.tooLarge(data.count) }
        return data
    }

    static func decode(_ data: Data) throws -> ProtocolMessage {
        guard data.count <= ProtocolLimits.maxMessageBytes else { throw ProtocolError.tooLarge(data.count) }
        let decoder = JSONDecoder()

        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch {
            throw ProtocolError.malformed
        }
        guard supportedVersions.contains(probe.v) else { throw ProtocolError.unsupportedVersion(probe.v) }
        guard ProtocolMessage.Kind(rawValue: probe.type) != nil else {
            throw ProtocolError.unknownMessageType(String(probe.type.prefix(32)))
        }

        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw ProtocolError.malformed
        }

        func require<T>(_ value: T?, _ name: String) throws -> T {
            guard let value else { throw ProtocolError.missingField(name) }
            return value
        }

        switch envelope.type {
        case .hello:
            return .hello(try require(envelope.hello, "hello"))
        case .offer:
            return .offer(try require(envelope.offer, "offer"))
        case .accept:
            return .accept(transferID: try require(envelope.transferID, "transferID"))
        case .cancel:
            return .cancel(transferID: try require(envelope.transferID, "transferID"))
        case .complete:
            return .complete(transferID: try require(envelope.transferID, "transferID"))
        case .decline:
            return .decline(transferID: try require(envelope.transferID, "transferID"),
                            reason: try require(envelope.declineReason, "declineReason"))
        case .failure:
            return .failure(transferID: try require(envelope.transferID, "transferID"),
                            reason: try require(envelope.failureReason, "failureReason"))
        case .chat:
            return .chat(try require(envelope.chat, "chat"))
        case .chatAck:
            return .chatAck(messageID: try require(envelope.messageID, "messageID"))
        case .chatSync:
            return .chatSync(try require(envelope.chatSync, "chatSync"))
        case .chatHistory:
            let history = try require(envelope.chatHistory, "chatHistory")
            guard history.count <= ProtocolLimits.chatHistoryBatch else { throw ProtocolError.malformed }
            return .chatHistory(history)
        case .chatReaction:
            return .chatReaction(try require(envelope.chatReaction, "chatReaction"))
        case .chatRead:
            return .chatRead(try require(envelope.chatRead, "chatRead"))
        case .chatTyping:
            return .chatTyping(try require(envelope.typing, "typing"))
        case .avatar:
            return .avatar(try require(envelope.avatar, "avatar"))
        case .mediaRequest:
            return .mediaRequest(hash: try require(envelope.hash, "hash"))
        case .media:
            return .media(try require(envelope.media, "media"))
        case .updateAvailable:
            return .updateAvailable(try require(envelope.update, "update"))
        case .updateRequest:
            let version = try require(envelope.version, "version")
            guard version.utf8.count <= 32 else { throw ProtocolError.malformed }
            return .updateRequest(version: version)
        }
    }

    /// Only the version field, for diagnosing an incompatible peer.
    static func peekVersion(_ data: Data) -> Int? {
        guard data.count <= ProtocolLimits.maxMessageBytes else { return nil }
        return try? JSONDecoder().decode(VersionProbe.self, from: data).v
    }
}

/// Resource names have the form "<transfer UUID>/<file index>".
enum ResourceName {
    static func make(transferID: UUID, index: Int) -> String {
        "\(transferID.uuidString)/\(index)"
    }

    static func parse(_ name: String) -> (transferID: UUID, index: Int)? {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let id = UUID(uuidString: String(parts[0])),
              let index = Int(parts[1]), index >= 0, index < ProtocolLimits.maxFilesPerTransfer
        else { return nil }
        return (id, index)
    }
}
