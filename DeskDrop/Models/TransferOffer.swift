import Foundation

/// One file inside an offer. Only metadata — never contents.
struct OfferedFile: Codable, Equatable, Sendable {
    /// Relative path with "/" separators. A single file is just its name; files from a
    /// dropped folder are prefixed with the folder name ("Photos/2024/beach.jpg").
    let path: String
    let size: Int64
    /// Lowercase hex SHA-256 of the contents, checked by the recipient before saving.
    let sha256: String
    /// Uniform type identifier, used only to pick an icon.
    let typeIdentifier: String?
}

/// Everything a recipient needs to decide whether to accept a transfer.
struct TransferOffer: Codable, Equatable, Sendable {
    let transferID: UUID
    let files: [OfferedFile]
    let totalBytes: Int64

    /// The first path component of every file, in order, without duplicates.
    var topLevelNames: [String] {
        var seen = Set<String>()
        return files.compactMap { file in
            guard let first = file.path.split(separator: "/", omittingEmptySubsequences: false).first else { return nil }
            let name = String(first)
            return seen.insert(name).inserted ? name : nil
        }
    }
}

/// Exchanged when a session opens, and carried as the invitation context.
struct Hello: Codable, Equatable, Sendable {
    let installationID: String
    let displayName: String
    let deviceKind: DeviceKind
    let appVersion: String
    /// Optional features this Mac understands, e.g. "chat". Absent from older versions.
    var capabilities: [String]? = nil

    static let chatCapability = "chat"
    /// Understands `chatTyping`.
    static let typingCapability = "typing"
    /// Exchanges profile photos (`avatar`, `mediaRequest`, `media`).
    static let avatarCapability = "avatar"
    /// Shows GIFs and stickers in messages.
    static let mediaCapability = "media"
    /// Passes DeskDrop updates on (`updateAvailable`, `updateRequest`).
    static let updateCapability = "update"
}
