import Foundation
import Testing
@testable import DeskDrop

@Suite("Transfer state machine")
struct TransferStateTests {
    @Test("The outgoing happy path is allowed step by step")
    func outgoingPath() {
        let path: [TransferPhase] = [.preparing, .offering, .awaitingAcceptance, .accepted, .transferring, .verifying, .completed]
        for (current, next) in zip(path, path.dropFirst()) {
            #expect(current.canTransition(to: next), "\(current) → \(next)")
        }
    }

    @Test("The incoming happy path is allowed step by step")
    func incomingPath() {
        let path: [TransferPhase] = [.awaitingDecision, .accepted, .transferring, .verifying, .completed]
        for (current, next) in zip(path, path.dropFirst()) {
            #expect(current.canTransition(to: next), "\(current) → \(next)")
        }
    }

    @Test("Terminal phases never change", arguments: [
        TransferPhase.completed, .declined(.userDeclined), .cancelled(.local), .failed(.timedOut), .expired,
    ])
    func terminal(phase: TransferPhase) {
        #expect(phase.isTerminal)
        for next in [TransferPhase.preparing, .accepted, .transferring, .completed, .failed(.unknown), .cancelled(.remote)] {
            #expect(!phase.canTransition(to: next), "\(phase) → \(next)")
        }
    }

    @Test("Phases cannot be skipped or reversed")
    func illegalJumps() {
        #expect(!TransferPhase.preparing.canTransition(to: .transferring))
        #expect(!TransferPhase.awaitingDecision.canTransition(to: .transferring))
        #expect(!TransferPhase.awaitingAcceptance.canTransition(to: .completed))
        #expect(!TransferPhase.transferring.canTransition(to: .accepted))
        #expect(!TransferPhase.verifying.canTransition(to: .transferring))
        #expect(!TransferPhase.transferring.canTransition(to: .declined(.userDeclined)))
        #expect(!TransferPhase.accepted.canTransition(to: .accepted))
    }

    @Test("Any active phase can be cancelled or fail")
    func cancelAndFail() {
        for phase in [TransferPhase.preparing, .offering, .awaitingAcceptance, .awaitingDecision, .accepted, .transferring, .verifying] {
            #expect(phase.canTransition(to: .cancelled(.local)))
            #expect(phase.canTransition(to: .failed(.peerDisconnected)))
        }
    }

    @Test("Duplicate transfer IDs are detected and old ones eventually forgotten")
    func boundedIDs() {
        var ids = BoundedIDSet(capacity: 3)
        let first = UUID()
        let insertedOnce = ids.insert(first)
        let insertedAgain = ids.insert(first)
        #expect(insertedOnce)
        #expect(!insertedAgain)
        for _ in 0..<3 { _ = ids.insert(UUID()) }
        #expect(!ids.contains(first))
        #expect(ids.count == 3)
    }

    @Test("History records only finished transfers")
    func historyEntry() {
        var transfer = Transfer(id: UUID(), direction: .outgoing, peerID: "p", peerName: "Alex", peerTag: "ABCD",
                                phase: .transferring, createdAt: .now)
        transfer.files = [TransferFile(index: 0, path: "a.txt", size: 3, typeIdentifier: nil)]
        transfer.totalBytes = 3
        #expect(HistoryEntry(transfer: transfer) == nil)
        transfer.phase = .declined(.userDeclined)
        #expect(HistoryEntry(transfer: transfer)?.outcome == .declined)
        transfer.phase = .failed(.timedOut)
        #expect(HistoryEntry(transfer: transfer)?.outcome == .failed)
    }

    @Test("Transfer titles summarise the items")
    func titles() {
        var transfer = Transfer(id: UUID(), direction: .incoming, peerID: "p", peerName: "Alex", peerTag: "ABCD",
                                phase: .awaitingDecision, createdAt: .now)
        transfer.files = [TransferFile(index: 0, path: "Report.pdf", size: 1, typeIdentifier: nil)]
        #expect(transfer.title == "Report.pdf")
        #expect(!transfer.isSingleFolder)
        transfer.files = [TransferFile(index: 0, path: "Photos/a.jpg", size: 1, typeIdentifier: nil),
                          TransferFile(index: 1, path: "Photos/b.jpg", size: 1, typeIdentifier: nil)]
        #expect(transfer.title == "Photos")
        #expect(transfer.isSingleFolder)
        transfer.files.append(TransferFile(index: 2, path: "notes.txt", size: 1, typeIdentifier: nil))
        #expect(transfer.title == "Photos and 1 more")
    }
}
