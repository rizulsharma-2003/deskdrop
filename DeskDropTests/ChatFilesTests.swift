import Foundation
import Testing
@testable import DeskDrop

@Suite("Files in conversations")
@MainActor
struct ChatFilesTests {
    private func message(_ text: String, from sender: String, at seconds: TimeInterval) -> ChatMessage {
        let date = Date(timeIntervalSince1970: 1_800_000_000 + seconds)
        return ChatMessage(id: UUID(), conversation: .direct("peer"), senderID: sender, senderName: sender,
                           text: text, sentAt: date, receivedAt: date, isOutgoing: sender == "me",
                           delivery: sender == "me" ? .delivered : nil)
    }

    private func entry(_ title: String, peerID: String?, peerName: String = "Rohit", at seconds: TimeInterval,
                       direction: TransferDirection = .incoming, outcome: HistoryEntry.Outcome = .completed) -> HistoryEntry {
        let date = Date(timeIntervalSince1970: 1_800_000_000 + seconds)
        return HistoryEntry(id: UUID(), title: title, fileCount: 1, totalBytes: 2048, direction: direction,
                            peerName: peerName, date: date.addingTimeInterval(5), outcome: outcome,
                            detail: outcome == .declined ? "Rohit declined." : nil, savedPath: nil,
                            peerID: peerID, startedAt: date, typeIdentifier: "com.adobe.pdf", isFolder: false)
    }

    @Test("Files sit among messages by time and break a run of bubbles")
    func timeline() {
        let first = message("Sending the deck", from: "me", at: 0)
        let second = message("here it comes", from: "me", at: 10)
        let file = ConversationFile(entry: entry("Q3.pdf", peerID: "peer", at: 20, direction: .outgoing))
        let third = message("got it?", from: "me", at: 30)
        let rows = ChatRow.rows(for: [first, second, third], files: [file])

        #expect(rows.map(\.id) == [ChatRow.time(first.sentAt).id, first.id.uuidString, second.id.uuidString,
                                   "file-\(file.id.uuidString)", third.id.uuidString])
        guard case .message(_, _, let secondEnds) = rows[2], case .message(_, let thirdStarts, _) = rows[4] else {
            Issue.record("Unexpected rows")
            return
        }
        #expect(secondEnds, "The bubble before a file gets its tail")
        #expect(thirdStarts, "A message after a file starts a new run")

        let later = ConversationFile(entry: entry("Later.pdf", peerID: "peer", at: 4000))
        let withGap = ChatRow.rows(for: [first], files: [later])
        #expect(withGap.count == 4, "A file an hour later gets its own timestamp")
    }

    @Test("History remembers who and when, and older entries still load")
    func historyFields() throws {
        let saved = entry("Q3.pdf", peerID: "peer-1", at: 0)
        let data = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(HistoryEntry.self, from: data) == saved)

        // A 1.5 entry: none of the new fields.
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"old.txt","fileCount":1,"totalBytes":3,"direction":"incoming",
         "peerName":"Rohit","date":0,"outcome":"completed"}
        """
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: Data(legacy.utf8))
        #expect(decoded.peerID == nil)
        #expect(ConversationFile(entry: decoded).date == decoded.date, "Placed at the finish time when the start is unknown")
    }

    @Test("A conversation shows that colleague's files: their history, and unambiguous older entries")
    func filesForColleague() throws {
        let suite = "DeskDropTests.files.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let model = DeskDropViewModel(defaults: defaults, historyURL: root.url.appendingPathComponent("history.json"),
                                      chatURL: root.url.appendingPathComponent("chat.json"))
        let rohit = UUID().uuidString
        let other = UUID().uuidString
        model.chat.store.remember(name: "Rohit", for: rohit)
        model.chat.store.remember(name: "Ejaj", for: other)

        model.history.record(entry("mine.pdf", peerID: rohit, at: 0))
        model.history.record(entry("theirs.pdf", peerID: other, peerName: "Ejaj", at: 10))
        model.history.record(entry("legacy.pdf", peerID: nil, peerName: "Rohit", at: 20))
        model.history.record(entry("declined.pdf", peerID: rohit, at: 30, direction: .outgoing, outcome: .declined))

        let files = model.conversationFiles(with: rohit)
        #expect(files.map(\.title) == ["mine.pdf", "legacy.pdf", "declined.pdf"])
        #expect(files.last?.isOutgoing == true)
        #expect(files.last?.detail == "Rohit declined.")

        // With two Macs called Rohit, an old entry can't be placed safely.
        model.chat.store.remember(name: "Rohit", for: other)
        #expect(model.conversationFiles(with: rohit).map(\.title) == ["mine.pdf", "declined.pdf"])

        let summary = try #require(model.conversationSummaries.first { $0.id == .direct(rohit) })
        #expect(summary.preview == "You: 📎 declined.pdf", "The latest file shows in the conversation list")
    }
}
