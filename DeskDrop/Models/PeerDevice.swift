import Foundation

/// The rough shape of a Mac, used only to pick an illustration.
enum DeviceKind: String, Codable, Sendable {
    case laptop
    case desktop

    init(from decoder: Decoder) throws {
        // Unknown values from newer versions fall back to a generic desktop.
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeviceKind(rawValue: raw) ?? .desktop
    }

    var symbolName: String {
        switch self {
        case .laptop: "laptopcomputer"
        case .desktop: "desktopcomputer"
        }
    }
}

/// How far DeskDrop has got with a nearby Mac. Discovery alone does not mean a
/// transfer can succeed, so the stages are kept distinct.
enum PeerPresence: Equatable, Sendable {
    /// Seen on the network; no session yet.
    case discovered
    /// An encrypted session is being negotiated.
    case connecting
    /// The session is up and the DeskDrop handshake is in progress.
    case connected
    /// Handshake complete; the peer can receive offers.
    case ready
    /// The peer speaks a protocol version this build does not support.
    case incompatible(remoteVersion: Int)
    /// Repeated connection attempts failed; waiting for the user to retry.
    case unavailable

    var canReceive: Bool { self == .ready }
}

/// A nearby Mac running DeskDrop.
struct PeerDevice: Identifiable, Equatable, Sendable {
    /// Random installation identifier advertised by the peer. Not authenticated.
    let id: String
    var displayName: String
    var deviceKind: DeviceKind
    var presence: PeerPresence
    var lastSeen: Date
    /// Whether this colleague's DeskDrop understands chat (announced in its hello).
    var supportsChat = false
    /// Whether it shows typing indicators (1.6 and later).
    var supportsTyping = false
    /// Whether it exchanges profile photos (1.7 and later).
    var supportsAvatar = false
    /// Whether it shows GIFs and stickers, and serves sticker images (1.7 and later).
    var supportsMedia = false
    /// Whether it can receive and pass on DeskDrop updates (1.7 and later).
    var supportsUpdates = false

    /// A short tag that helps tell apart two peers with the same display name.
    var shortTag: String { Self.shortTag(for: id) }

    static func shortTag(for installationID: String) -> String {
        String(installationID.replacingOccurrences(of: "-", with: "").prefix(4)).uppercased()
    }

    /// Up to two initials for the illustration's screen.
    var initials: String { Self.initials(for: displayName) }

    static func initials(for name: String) -> String {
        let trimmed = name.replacingOccurrences(of: "'s Mac", with: "")
            .replacingOccurrences(of: "’s Mac", with: "")
        let words = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }
}
