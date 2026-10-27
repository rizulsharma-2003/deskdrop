import Foundation

/// A file inside a transfer, as shown in the UI.
struct TransferFile: Identifiable, Equatable, Sendable {
    let index: Int
    let path: String
    let size: Int64
    let typeIdentifier: String?

    var id: Int { index }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// One transfer in either direction, with its real, measured progress.
struct Transfer: Identifiable, Equatable, Sendable {
    let id: UUID
    let direction: TransferDirection
    let peerID: String
    var peerName: String
    var peerTag: String
    var phase: TransferPhase
    let createdAt: Date
    var finishedAt: Date?

    /// Empty for outgoing transfers until preparation finishes.
    var files: [TransferFile] = []
    var totalBytes: Int64 = 0
    var bytesTransferred: Int64 = 0
    var bytesPerSecond: Double?
    var secondsRemaining: Double?

    /// Outgoing: what the user dropped (kept for Retry).
    var sourceURLs: [URL] = []
    /// Incoming: the top-level items saved into the receiving folder.
    var savedURLs: [URL] = []
    /// A user-facing explanation when the transfer did not complete.
    var detail: String?

    var fractionCompleted: Double {
        if phase == .completed { return 1 }
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
    }

    /// Top-level names: dropped items for outgoing transfers, offered items for incoming.
    var topLevelNames: [String] {
        if files.isEmpty { return sourceURLs.map(\.lastPathComponent) }
        var seen = Set<String>()
        return files.compactMap { file in
            guard let first = file.path.split(separator: "/").first.map(String.init) else { return nil }
            return seen.insert(first).inserted ? first : nil
        }
    }

    /// True when the transfer is a single dropped folder.
    var isSingleFolder: Bool {
        if files.isEmpty {
            guard sourceURLs.count == 1, let url = sourceURLs.first else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let tops = topLevelNames
        return tops.count == 1 && !(files.count == 1 && files[0].path == tops[0])
    }

    /// "Report.pdf", "Photos", or "Report.pdf and 3 more".
    var title: String {
        let tops = topLevelNames
        guard let first = tops.first else { return String(localized: "Files") }
        if tops.count == 1 { return first }
        return String(localized: "\(first) and \(tops.count - 1) more")
    }

    /// "1 file", "24 files".
    var fileCountDescription: String {
        let count = files.isEmpty ? sourceURLs.count : files.count
        return count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
    }

    /// The type to use for an icon when only one item is involved.
    var primaryTypeIdentifier: String? {
        guard !isSingleFolder, topLevelNames.count == 1 else { return nil }
        return files.first?.typeIdentifier
    }
}
