import Foundation
import Testing
@testable import DeskDrop

@Suite("Protocol codec")
struct ProtocolCodecTests {
    private let id = UUID()

    private var sampleOffer: TransferOffer {
        TransferOffer(transferID: id, files: [
            OfferedFile(path: "Report.pdf", size: 12, sha256: String(repeating: "a", count: 64), typeIdentifier: "com.adobe.pdf"),
            OfferedFile(path: "Photos/beach.jpg", size: 30, sha256: String(repeating: "b", count: 64), typeIdentifier: nil),
        ], totalBytes: 42)
    }

    @Test("Every message type survives a round trip")
    func roundTrip() throws {
        let messages: [ProtocolMessage] = [
            .hello(Hello(installationID: UUID().uuidString, displayName: "Priya’s Mac", deviceKind: .laptop, appVersion: "1.0.0")),
            .offer(sampleOffer),
            .accept(transferID: id),
            .decline(transferID: id, reason: .busy),
            .cancel(transferID: id),
            .complete(transferID: id),
            .failure(transferID: id, reason: .validationFailed),
            .chat(ChatPayload(id: id, scope: .direct, senderID: UUID().uuidString, senderName: "Alex",
                              text: "Lunch at 1?\nBring the deck.", sentAt: Date(timeIntervalSince1970: 1_800_000_000))),
            .chatAck(messageID: id),
            .chatSync(ChatSyncRequest(communitySince: nil)),
            .chatSync(ChatSyncRequest(communitySince: Date(timeIntervalSince1970: 1_800_000_000))),
            .chatHistory([ChatPayload(id: UUID(), scope: .community, senderID: UUID().uuidString, senderName: "Priya",
                                      text: "Morning all", sentAt: Date(timeIntervalSince1970: 1_800_000_100),
                                      reactions: [ReactionMark(reactorID: UUID().uuidString, reactorName: "Alex", emoji: "❤️")])]),
            .chatReaction(ChatReaction(messageID: id, scope: .direct, emoji: "👍", reactorID: UUID().uuidString,
                                       reactorName: "Alex", at: Date(timeIntervalSince1970: 1_800_000_200))),
            .chatReaction(ChatReaction(messageID: id, scope: .community, emoji: nil, reactorID: UUID().uuidString,
                                       reactorName: "Alex", at: Date(timeIntervalSince1970: 1_800_000_200))),
            .chatRead(ChatReadReceipt(lastReadMessageID: id, readAt: Date(timeIntervalSince1970: 1_800_000_300))),
            .chatTyping(true),
            .chatTyping(false),
            .chat(ChatPayload(id: UUID(), scope: .community, senderID: UUID().uuidString, senderName: "Alex",
                              text: "GIF: Party https://giphy.com/gifs/abc123", sentAt: Date(timeIntervalSince1970: 1_800_000_400),
                              media: ChatMedia(kind: .gif, url: URL(string: "https://media2.giphy.com/media/abc123/giphy.gif"),
                                               hash: nil, width: 480, height: 270, title: "Party", giphyID: "abc123"))),
            .avatar(AvatarInfo(hash: String(repeating: "c", count: 64))),
            .avatar(AvatarInfo(hash: nil)),
            .mediaRequest(hash: String(repeating: "d", count: 64)),
            .media(MediaBlob(hash: String(repeating: "e", count: 64), data: Data([0x89, 0x50, 0x4E, 0x47]))),
            .updateAvailable(UpdateOffer(manifest: Data("{}".utf8), signature: Data(repeating: 7, count: 64))),
            .updateRequest(version: "1.8.0"),
        ]
        for message in messages {
            let decoded = try ProtocolCodec.decode(ProtocolCodec.encode(message))
            #expect(decoded == message)
        }
        #expect(Set(messages.map(\.kind)) == Set(ProtocolMessage.Kind.allCases))
    }

    @Test("Envelope carries the current version")
    func envelopeVersion() throws {
        let data = try ProtocolCodec.encode(.accept(transferID: id))
        #expect(ProtocolCodec.peekVersion(data) == ProtocolCodec.currentVersion)
    }

    @Test("Unsupported versions are rejected before anything else is decoded")
    func unsupportedVersion() {
        let json = #"{"v":99,"type":"something-new","future":true}"#
        #expect(throws: ProtocolError.unsupportedVersion(99)) {
            try ProtocolCodec.decode(Data(json.utf8))
        }
        let zero = #"{"v":0,"type":"accept","transferID":"\#(id.uuidString)"}"#
        #expect(throws: ProtocolError.unsupportedVersion(0)) {
            try ProtocolCodec.decode(Data(zero.utf8))
        }
    }

    @Test("Malformed input never decodes", arguments: [
        "", "not json", "[]", "{}", #"{"v":"1","type":"accept"}"#, #"{"type":"accept"}"#,
        #"{"v":1,"type":"accept","transferID":"not-a-uuid"}"#,
        #"{"v":1,"type":"offer","offer":{"transferID":"x"}}"#,
    ])
    func malformed(json: String) {
        #expect(throws: (any Error).self) {
            try ProtocolCodec.decode(Data(json.utf8))
        }
    }

    @Test("Unknown message types are named in the error")
    func unknownType() {
        let json = #"{"v":1,"type":"deleteEverything"}"#
        #expect(throws: ProtocolError.unknownMessageType("deleteEverything")) {
            try ProtocolCodec.decode(Data(json.utf8))
        }
    }

    @Test("A known type without its required field is rejected")
    func missingField() {
        let json = #"{"v":1,"type":"decline","transferID":"\#(id.uuidString)"}"#
        #expect(throws: ProtocolError.missingField("declineReason")) {
            try ProtocolCodec.decode(Data(json.utf8))
        }
    }

    @Test("Messages over the size limit are refused both ways")
    func sizeLimit() {
        let oversized = Data(repeating: 0x20, count: ProtocolLimits.maxMessageBytes + 1)
        #expect(throws: ProtocolError.tooLarge(oversized.count)) {
            try ProtocolCodec.decode(oversized)
        }
        let longPath = String(repeating: "a", count: 1000)
        let files = (0..<1500).map { OfferedFile(path: "\(longPath)\($0)", size: 0, sha256: FileDigest.emptySHA256, typeIdentifier: nil) }
        #expect(throws: (any Error).self) {
            try ProtocolCodec.encode(.offer(TransferOffer(transferID: id, files: files, totalBytes: 0)))
        }
    }

    @Test("Hello capabilities are optional, so older peers still decode")
    func helloCapabilities() throws {
        let old = #"{"v":1,"type":"hello","hello":{"installationID":"\#(UUID().uuidString)","displayName":"Old Mac","deviceKind":"desktop","appVersion":"1.0.0"}}"#
        guard case .hello(let hello) = try ProtocolCodec.decode(Data(old.utf8)) else {
            Issue.record("Expected a hello")
            return
        }
        #expect(hello.capabilities == nil)
    }

    @Test("Oversized chat history batches are refused")
    func chatHistoryLimit() throws {
        let payload = ChatPayload(id: UUID(), scope: .community, senderID: UUID().uuidString, senderName: "A",
                                  text: "x", sentAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try ProtocolCodec.encode(.chatHistory(Array(repeating: payload, count: ProtocolLimits.chatHistoryBatch + 1)))
        #expect(throws: ProtocolError.malformed) { try ProtocolCodec.decode(data) }
    }

    @Test("Unknown reasons from newer peers degrade gracefully")
    func unknownReason() throws {
        let json = #"{"v":1,"type":"failure","transferID":"\#(id.uuidString)","failureReason":"solarFlare"}"#
        #expect(try ProtocolCodec.decode(Data(json.utf8)) == .failure(transferID: id, reason: .unknown))
    }

    @Test("Resource names round-trip and reject garbage")
    func resourceNames() {
        let name = ResourceName.make(transferID: id, index: 7)
        #expect(ResourceName.parse(name)?.transferID == id)
        #expect(ResourceName.parse(name)?.index == 7)
        for bad in ["", "abc", "\(id.uuidString)", "\(id.uuidString)/-1", "\(id.uuidString)/x",
                    "\(id.uuidString)/1/2", "../\(id.uuidString)/1", "\(id.uuidString)/99999"] {
            #expect(ResourceName.parse(bad) == nil, "\(bad) should not parse")
        }
    }
}
