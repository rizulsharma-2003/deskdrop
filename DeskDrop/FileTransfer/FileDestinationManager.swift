import Foundation

enum DestinationError: Error, Equatable {
    case folderUnavailable(String)
    case folderNotWritable(String)
    case insufficientSpace(required: Int64, available: Int64)

    var isSpaceProblem: Bool {
        if case .insufficientSpace = self { return true }
        return false
    }
}

/// Where accepted files go, and the private staging area used while they arrive.
@MainActor
protocol ReceivingDestination: AnyObject {
    /// A validated, writable folder with room for `requiredBytes`.
    func prepareDestination(requiredBytes: Int64) throws -> URL
    var duplicateHandling: DuplicateHandling { get }
    var stagingRoot: URL { get }
}

/// Resolves the receiving folder (Downloads by default, or a user-chosen folder
/// remembered with a security-scoped bookmark) and checks it before every accept.
@MainActor
final class FileDestinationManager: ReceivingDestination {
    /// Extra room left free on the volume beyond the transfer itself.
    nonisolated static let safetyMargin: Int64 = 64 * 1024 * 1024

    private let defaults: UserDefaults
    private let duplicateHandlingProvider: () -> DuplicateHandling
    private var accessedDirectory: URL?
    private(set) var customDirectory: URL?
    let stagingRoot: URL

    nonisolated static var defaultStagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskDrop", isDirectory: true)
            .appendingPathComponent("Incoming", isDirectory: true)
    }

    /// ~/Downloads. Inside the sandbox the container path is a symlink to the real
    /// folder, so it is resolved to give Finder and the user the familiar path.
    nonisolated static var defaultDownloadsDirectory: URL {
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        return url.resolvingSymlinksInPath()
    }

    init(defaults: UserDefaults = .standard,
         stagingRoot: URL = FileDestinationManager.defaultStagingRoot,
         duplicateHandling: @escaping () -> DuplicateHandling) {
        self.defaults = defaults
        self.stagingRoot = stagingRoot
        self.duplicateHandlingProvider = duplicateHandling
        restoreCustomDirectory()
    }

    var duplicateHandling: DuplicateHandling { duplicateHandlingProvider() }

    var receivingDirectory: URL { customDirectory ?? Self.defaultDownloadsDirectory }

    var isUsingDefaultDirectory: Bool { customDirectory == nil }

    func setCustomDirectory(_ url: URL) throws {
        try Self.validateDirectory(url)
        let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: SettingsKey.receivingDirectoryBookmark)
        beginAccessing(url)
        customDirectory = url
    }

    func resetToDefaultDirectory() {
        defaults.removeObject(forKey: SettingsKey.receivingDirectoryBookmark)
        endAccessing()
        customDirectory = nil
    }

    func prepareDestination(requiredBytes: Int64) throws -> URL {
        let directory = receivingDirectory
        try Self.validateDirectory(directory)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try Self.ensureCapacity(requiredBytes, at: [stagingRoot, directory])
        return directory
    }

    /// Removes anything left in the staging area by a previous run.
    func removeStaleStagingFiles() {
        let root = stagingRoot.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Validation

    nonisolated static func validateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DestinationError.folderUnavailable(url.lastPathComponent)
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw DestinationError.folderNotWritable(url.lastPathComponent)
        }
    }

    nonisolated static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Every distinct volume involved must have room for the whole transfer.
    nonisolated static func ensureCapacity(_ requiredBytes: Int64, at urls: [URL]) throws {
        var checkedVolumes = Set<String>()
        for url in urls {
            let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]).volume?.path) ?? url.path
            guard checkedVolumes.insert(volume).inserted else { continue }
            guard let available = availableCapacity(at: url) else { continue }
            let needed = requiredBytes + safetyMargin
            if available < needed {
                throw DestinationError.insufficientSpace(required: requiredBytes, available: max(0, available - safetyMargin))
            }
        }
    }

    // MARK: - Security-scoped bookmark

    private func restoreCustomDirectory() {
        guard let data = defaults.data(forKey: SettingsKey.receivingDirectoryBookmark) else { return }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            Log.files.error("Saved receiving folder could not be resolved; using Downloads")
            defaults.removeObject(forKey: SettingsKey.receivingDirectoryBookmark)
            return
        }
        beginAccessing(url)
        customDirectory = url
        if isStale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: SettingsKey.receivingDirectoryBookmark)
        }
    }

    private func beginAccessing(_ url: URL) {
        endAccessing()
        if url.startAccessingSecurityScopedResource() {
            accessedDirectory = url
        }
    }

    private func endAccessing() {
        accessedDirectory?.stopAccessingSecurityScopedResource()
        accessedDirectory = nil
    }
}
