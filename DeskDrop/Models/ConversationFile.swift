import Foundation
import UniformTypeIdentifiers

/// A file transfer as it appears in a one-on-one conversation: from the live
/// transfer while DeskDrop still has it, then from Recent Activity. Nothing new
/// travels between Macs for this; each side shows its own record of the transfer.
struct ConversationFile: Identifiable, Equatable {
    let id: UUID
    let isOutgoing: Bool
    /// When it was offered, which is where it sits in the conversation.
    let date: Date
    let title: String
    let fileCount: Int
    let totalBytes: Int64
    let phase: TransferPhase
    /// Why it didn't complete, when known.
    let detail: String?
    let typeIdentifier: String?
    let isFolder: Bool
    /// The live transfer, for progress and actions; nil once only history remains.
    let transfer: Transfer?
    /// Something on disk you can preview, open or drag: the received item, or
    /// (until DeskDrop quits) the item you sent.
    let fileURL: URL?

    init(transfer: Transfer) {
        id = transfer.id
        isOutgoing = transfer.direction == .outgoing
        date = transfer.createdAt
        title = transfer.title
        fileCount = max(transfer.files.count, transfer.sourceURLs.count)
        totalBytes = transfer.totalBytes
        phase = transfer.phase
        detail = transfer.detail
        typeIdentifier = transfer.primaryTypeIdentifier
        isFolder = transfer.isSingleFolder
        self.transfer = transfer
        let candidate: URL? = isOutgoing
            ? (transfer.sourceURLs.count == 1 ? transfer.sourceURLs.first : nil)
            : (transfer.phase == .completed && transfer.savedURLs.count == 1 ? transfer.savedURLs.first : nil)
        fileURL = candidate.flatMap(Self.existing)
    }

    init(entry: HistoryEntry) {
        id = entry.id
        isOutgoing = entry.direction == .outgoing
        date = entry.startedAt ?? entry.date
        title = entry.title
        fileCount = entry.fileCount
        totalBytes = entry.totalBytes
        switch entry.outcome {
        case .completed: phase = .completed
        case .declined: phase = .declined(.userDeclined)
        case .cancelled: phase = .cancelled(.local)
        case .failed: phase = .failed(.unknown)
        case .expired: phase = .expired
        }
        detail = entry.detail
        typeIdentifier = entry.typeIdentifier
        isFolder = entry.isFolder ?? false
        transfer = nil
        // Items you sent are only reachable while DeskDrop has them (sandbox), so
        // from history only a received item can be opened.
        fileURL = !isOutgoing && entry.outcome == .completed
            ? entry.savedPath.map { URL(fileURLWithPath: $0) }.flatMap(Self.existing)
            : nil
    }

    /// A single image you can see a preview of.
    var isImage: Bool {
        guard !isFolder, fileCount == 1, let typeIdentifier, let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .image)
    }

    private static func existing(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
