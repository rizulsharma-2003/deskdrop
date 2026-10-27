import AppKit
import CryptoKit

/// Downloads GIFs and stickers from GIPHY's media servers (and nowhere else),
/// keeping them in memory and in Caches so a conversation doesn't download them
/// again. The disk copy is trimmed to `diskLimit`, oldest first.
@MainActor
final class RemoteImageCache {
    private let directory: URL
    private let session: URLSession
    private let memory: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 150
        return cache
    }()
    private var inFlight: [URL: Task<Data, Error>] = [:]

    /// Largest download accepted.
    nonisolated static let maxBytes = 12_000_000
    nonisolated static let diskLimit: Int64 = 250_000_000

    enum Failure: Error {
        case notAllowed
        case unavailable
        case notAnImage
    }

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DeskDrop", isDirectory: true).appendingPathComponent("GIPHY", isDirectory: true)
    }

    init(directory: URL = RemoteImageCache.defaultDirectory, session: URLSession = .giphy) {
        self.directory = directory
        self.session = session
    }

    #if DEBUG
    /// UI tests only: an image for a GIPHY link, so GIFs show without the network.
    func seedForUITesting(_ data: Data, for url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(Self.key(for: url), isDirectory: false))
        if let image = NSImage(data: data) { memory.setObject(image, forKey: url as NSURL) }
    }
    #endif

    /// The image if it's already in memory, so a view can show it without waiting.
    func cachedImage(for url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async throws -> NSImage {
        guard ChatMedia.isGiphyMedia(url) else { throw Failure.notAllowed }
        if let image = memory.object(forKey: url as NSURL) { return image }
        let task: Task<Data, Error>
        if let existing = inFlight[url] {
            task = existing
        } else {
            let file = directory.appendingPathComponent(Self.key(for: url), isDirectory: false)
            let session = self.session
            task = Task { try await Self.load(url, file: file, session: session) }
            inFlight[url] = task
        }
        let data: Data
        do {
            data = try await task.value
            inFlight[url] = nil
        } catch {
            inFlight[url] = nil
            throw error
        }
        if let image = memory.object(forKey: url as NSURL) { return image }
        guard let image = NSImage(data: data) else { throw Failure.notAnImage }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    /// The downloaded bytes, for copying a GIF.
    func data(for url: URL) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(Self.key(for: url), isDirectory: false))
    }

    /// Reads the disk copy or downloads it. Runs off the main actor.
    nonisolated private static func load(_ url: URL, file: URL, session: URLSession) async throws -> Data {
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
            return data
        }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= maxBytes else { throw Failure.unavailable }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw Failure.notAnImage
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    nonisolated private static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Removes the oldest downloads once the folder passes `diskLimit`.
    nonisolated static func trimDisk(at directory: URL = defaultDirectory, limit: Int64 = diskLimit) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            return
        }
        var entries = files.compactMap { url -> (url: URL, size: Int64, date: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > limit * 3 / 4 {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
