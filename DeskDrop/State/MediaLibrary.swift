import AppKit
import CryptoKit
import Observation

/// Images kept on this Mac by content hash: profile photos (yours and your
/// colleagues') and sticker images (yours, and ones colleagues sent you). Saved
/// in Application Support with a small index, so photos still show while a
/// colleague is away.
@MainActor
@Observable
final class MediaLibrary {
    /// Colleague installation ID → hash of their profile photo.
    private(set) var avatarHashes: [String: String] = [:]
    private(set) var myAvatarHash: String?
    /// Your stickers, newest first.
    private(set) var myStickers: [String] = []
    /// Bumped whenever an image arrives, so views waiting for one look again.
    private(set) var arrivals = 0

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let images = NSCache<NSString, NSImage>()
    @ObservationIgnored private var present: Set<String> = []

    /// Most stickers you can keep.
    static let maxStickers = 200

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DeskDrop", isDirectory: true).appendingPathComponent("Media", isDirectory: true)
    }

    private struct Index: Codable {
        var version = 1
        var avatars: [String: String]
        var myAvatar: String?
        var stickers: [String]
    }

    init(directory: URL = MediaLibrary.defaultDirectory) {
        self.directory = directory
        load()
    }

    nonisolated static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Images

    func contains(_ hash: String) -> Bool {
        present.contains(hash)
    }

    func data(for hash: String) -> Data? {
        guard present.contains(hash) else { return nil }
        return try? Data(contentsOf: fileURL(for: hash))
    }

    /// The image for `hash`, or nil while it hasn't arrived (views showing nil
    /// update when it does).
    func image(for hash: String) -> NSImage? {
        if let cached = images.object(forKey: hash as NSString) { return cached }
        guard present.contains(hash), let data = data(for: hash), let image = NSImage(data: data) else {
            _ = arrivals
            return nil
        }
        images.setObject(image, forKey: hash as NSString)
        return image
    }

    /// Saves an image and returns its hash. Images are never altered after this,
    /// so the hash always matches what colleagues receive.
    @discardableResult
    func store(_ data: Data) -> String? {
        let hash = Self.hash(of: data)
        guard !present.contains(hash) else { return hash }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: hash), options: .atomic)
        } catch {
            Log.app.error("Image could not be saved: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        present.insert(hash)
        arrivals += 1
        return hash
    }

    // MARK: - Profile photos

    func avatar(forPeer peerID: String) -> NSImage? {
        avatarHashes[peerID].flatMap(image(for:))
    }

    var myAvatar: NSImage? {
        myAvatarHash.flatMap(image(for:))
    }

    /// A colleague's photo changed (nil: they removed it). Only call with an
    /// image that's already stored.
    func setAvatar(_ hash: String?, forPeer peerID: String) {
        guard avatarHashes[peerID] != hash, hash.map(contains) ?? true else { return }
        let old = avatarHashes[peerID]
        avatarHashes[peerID] = hash
        save()
        old.map(removeIfUnused)
    }

    /// Sets (or with nil removes) your own photo. Returns its hash.
    @discardableResult
    func setMyAvatar(_ data: Data?) -> String? {
        let old = myAvatarHash
        if let data {
            guard let hash = store(data) else { return old }
            myAvatarHash = hash
        } else {
            myAvatarHash = nil
        }
        save()
        if let old, old != myAvatarHash { removeIfUnused(old) }
        return myAvatarHash
    }

    // MARK: - Stickers

    /// Adds an image to your stickers (or moves it to the front). Returns its hash.
    @discardableResult
    func addSticker(_ data: Data) -> String? {
        guard let hash = store(data) else { return nil }
        addSticker(hash: hash)
        return hash
    }

    /// Adds a sticker that's already stored, such as one a colleague sent.
    func addSticker(hash: String) {
        guard contains(hash) else { return }
        myStickers = Array(([hash] + myStickers.filter { $0 != hash }).prefix(Self.maxStickers))
        save()
    }

    func removeSticker(_ hash: String) {
        guard myStickers.contains(hash) else { return }
        myStickers.removeAll { $0 == hash }
        save()
    }

    func isMySticker(_ hash: String) -> Bool {
        myStickers.contains(hash)
    }

    // MARK: - Persistence

    private var indexURL: URL { directory.appendingPathComponent("index.json", isDirectory: false) }

    private func fileURL(for hash: String) -> URL {
        directory.appendingPathComponent(hash, isDirectory: false)
    }

    /// Old profile photos go once nobody uses them. Sticker images stay: messages
    /// in your history may still show them.
    private func removeIfUnused(_ hash: String) {
        guard hash != myAvatarHash, !avatarHashes.values.contains(hash), !myStickers.contains(hash) else { return }
        try? FileManager.default.removeItem(at: fileURL(for: hash))
        present.remove(hash)
        images.removeObject(forKey: hash as NSString)
    }

    private func save() {
        let index = Index(avatars: avatarHashes, myAvatar: myAvatarHash, stickers: myStickers)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        } catch {
            Log.app.error("Image index could not be saved: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func load() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        present = Set(names.filter(ChatMedia.isHash))
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        avatarHashes = index.avatars.filter { UUID(uuidString: $0.key) != nil && present.contains($0.value) }
        myAvatarHash = index.myAvatar.flatMap { present.contains($0) ? $0 : nil }
        myStickers = index.stickers.filter(present.contains)
    }
}
