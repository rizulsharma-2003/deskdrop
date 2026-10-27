import Foundation

/// Moves profile photos and sticker images between Macs, by content hash.
///
/// - **Profile photos:** when a colleague connects (and whenever you change your
///   photo), each Mac announces its photo's hash. A Mac that doesn't have that
///   image yet asks for it.
/// - **Stickers you made:** a sticker message carries only the image's hash. The
///   recipient asks the Mac that delivered the message for the image.
///
/// Images are only accepted when this Mac asked that colleague for them, when
/// their SHA-256 matches, and when they decode as a PNG, JPEG or GIF within the
/// size limits. Requests are rate-limited.
@MainActor
final class MediaExchange {
    let library: MediaLibrary

    private let transport: any ChatTransport
    private let clock: () -> TimeInterval
    /// hash → colleagues it was requested from, and when.
    private var requests: [String: [String: TimeInterval]] = [:]
    /// Colleagues whose new photo is on its way: colleague → hash.
    private var pendingAvatars: [String: String] = [:]
    /// Images messages need, and who to ask when they connect: hash → colleagues.
    private var wanted: [String: Set<String>] = [:]
    /// When each colleague's recent requests arrived, for rate limiting.
    private var served: [String: [TimeInterval]] = [:]

    /// How long to wait for an image before asking again.
    static let requestTimeout: TimeInterval = 30

    init(transport: any ChatTransport, library: MediaLibrary,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport
        self.library = library
        self.clock = clock
    }

    // MARK: - Profile photos

    /// Tells everyone connected about your photo, after you change it.
    func announceAvatar() {
        for peer in transport.readyPeers where peer.supportsAvatar {
            try? transport.send(.avatar(AvatarInfo(hash: library.myAvatarHash)), to: peer.id)
        }
    }

    /// Announces your photo to a colleague who just connected, and asks them for
    /// images still missing.
    func peerBecameReady(_ peerID: String) {
        guard let peer = transport.peer(for: peerID) else { return }
        if peer.supportsAvatar {
            try? transport.send(.avatar(AvatarInfo(hash: library.myAvatarHash)), to: peerID)
        }
        for (hash, sources) in wanted where sources.contains(peerID) {
            request(hash, from: peerID)
        }
    }

    // MARK: - Sticker images

    /// A message needs this image. Asks `peerID` now if they're connected, or
    /// when they next connect.
    func want(_ hash: String, from peerID: String) {
        guard ChatMedia.isHash(hash), !library.contains(hash) else { return }
        wanted[hash, default: []].insert(peerID)
        request(hash, from: peerID)
    }

    // MARK: - Receiving

    func receive(_ message: ProtocolMessage, from peerID: String) {
        switch message {
        case .avatar(let info):
            receiveAvatar(info, from: peerID)
        case .mediaRequest(let hash):
            answer(hash, to: peerID)
        case .media(let blob):
            receiveImage(blob, from: peerID)
        default:
            break
        }
    }

    private func receiveAvatar(_ info: AvatarInfo, from peerID: String) {
        guard let hash = info.hash else {
            pendingAvatars[peerID] = nil
            library.setAvatar(nil, forPeer: peerID)
            return
        }
        guard ChatMedia.isHash(hash) else { return }
        if library.contains(hash) {
            pendingAvatars[peerID] = nil
            library.setAvatar(hash, forPeer: peerID)
        } else {
            pendingAvatars[peerID] = hash
            request(hash, from: peerID)
        }
    }

    private func answer(_ hash: String, to peerID: String) {
        guard ChatMedia.isHash(hash), allowRequest(from: peerID), let data = library.data(for: hash),
              data.count <= ProtocolLimits.maxMediaBytes else { return }
        do {
            try transport.send(.media(MediaBlob(hash: hash, data: data)), to: peerID)
        } catch {
            Log.transfer.info("Image not sent: peer not reachable")
        }
    }

    private func receiveImage(_ blob: MediaBlob, from peerID: String) {
        // Only images this Mac asked that colleague for, exactly as requested.
        guard requests[blob.hash]?[peerID] != nil else {
            Log.transfer.error("Dropped an image nobody asked for")
            return
        }
        guard blob.data.count <= ProtocolLimits.maxMediaBytes, MediaLibrary.hash(of: blob.data) == blob.hash,
              ImageProcessing.isAcceptableImage(blob.data) else {
            Log.transfer.error("Dropped an invalid image")
            requests[blob.hash]?[peerID] = nil
            return
        }
        requests[blob.hash] = nil
        wanted[blob.hash] = nil
        guard library.store(blob.data) != nil else { return }
        for (peer, hash) in pendingAvatars where hash == blob.hash {
            pendingAvatars[peer] = nil
            library.setAvatar(hash, forPeer: peer)
        }
    }

    // MARK: - Helpers

    private func request(_ hash: String, from peerID: String) {
        let now = clock()
        if let asked = requests[hash]?[peerID], now - asked < Self.requestTimeout { return }
        guard let peer = transport.peer(for: peerID), peer.presence == .ready,
              peer.supportsMedia || peer.supportsAvatar else { return }
        do {
            try transport.send(.mediaRequest(hash: hash), to: peerID)
            requests[hash, default: [:]][peerID] = now
        } catch {
            Log.transfer.info("Image request not sent: peer not reachable")
        }
    }

    private func allowRequest(from peerID: String) -> Bool {
        let now = clock()
        var recent = (served[peerID] ?? []).filter { now - $0 < ProtocolLimits.chatRateWindow }
        guard recent.count < ProtocolLimits.maxMediaRequestsPerWindow else {
            served[peerID] = recent
            return false
        }
        recent.append(now)
        served[peerID] = recent
        return true
    }
}
