import Foundation

/// A finished transfer as remembered in Recent Activity. Metadata only — file
/// contents are never stored.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case completed
        case declined
        case cancelled
        case failed
        case expired
    }

    let id: UUID
    let title: String
    let fileCount: Int
    let totalBytes: Int64
    let direction: TransferDirection
    let peerName: String
    let date: Date
    let outcome: Outcome
    let detail: String?
    /// Where a received item was saved, so it can be revealed later.
    let savedPath: String?
    /// The colleague's installation ID, so the transfer appears in your
    /// conversation with them. Absent from entries recorded before 1.6.
    var peerID: String? = nil
    /// When the transfer was offered, which is where it sits in the conversation.
    var startedAt: Date? = nil
    /// For a single file, its type (for the icon); whether it was one folder.
    var typeIdentifier: String? = nil
    var isFolder: Bool? = nil
}

extension HistoryEntry {
    init?(transfer: Transfer) {
        let outcome: Outcome
        switch transfer.phase {
        case .completed: outcome = .completed
        case .declined: outcome = .declined
        case .cancelled: outcome = .cancelled
        case .failed: outcome = .failed
        case .expired: outcome = .expired
        default: return nil
        }
        self.init(id: transfer.id,
                  title: transfer.title,
                  fileCount: max(transfer.files.count, transfer.sourceURLs.count),
                  totalBytes: transfer.totalBytes,
                  direction: transfer.direction,
                  peerName: transfer.peerName,
                  date: transfer.finishedAt ?? .now,
                  outcome: outcome,
                  detail: transfer.detail,
                  savedPath: transfer.savedURLs.first?.path,
                  peerID: transfer.peerID,
                  startedAt: transfer.createdAt,
                  typeIdentifier: transfer.primaryTypeIdentifier,
                  isFolder: transfer.isSingleFolder)
    }
}
