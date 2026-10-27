import Foundation
import Observation

/// Recent Activity, stored as a small JSON file in Application Support.
/// Only metadata is kept; file contents never are.
@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let limit: Int

    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DeskDrop", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    init(fileURL: URL = HistoryStore.defaultFileURL, limit: Int = 500) {
        self.fileURL = fileURL
        self.limit = limit
        load()
    }

    func record(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            entries = try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            // Keep the unreadable file for inspection rather than silently losing it.
            Log.app.error("History could not be read; starting fresh")
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            entries = []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("History could not be saved: \(error.localizedDescription, privacy: .private)")
        }
    }
}
