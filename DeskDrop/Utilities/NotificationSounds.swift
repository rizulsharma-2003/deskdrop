import AppKit
import AVFoundation
import UserNotifications

/// One choice in the sound pickers.
struct SoundOption: Identifiable, Hashable {
    let id: String
    let title: String
}

enum SoundImportError: Error {
    case unreadable
    case tooLarge
}

/// The sounds DeskDrop can play for incoming files and messages:
/// DeskDrop's own sound, the built-in macOS sounds, and sound files you add.
///
/// System notifications only play AIFF, WAV or CAF files under 30 seconds that are
/// in the app bundle or the app's `Library/Sounds` folder, so built-in sounds are
/// copied there and added files are converted to CAF and trimmed.
@MainActor
enum NotificationSounds {
    static let deskDrop = "deskdrop"
    private static let systemPrefix = "system:"
    private static let customPrefix = "custom:"
    private static let bundledName = "DeskDropAlert"
    private static let customFilePrefix = "DeskDropCustom-"
    private static let systemFilePrefix = "DeskDropSystem-"
    /// Notifications ignore longer sounds.
    nonisolated static let maxSeconds = 29.5

    static let systemNames = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
                              "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    /// `Library/Sounds` inside DeskDrop's container.
    static var soundsDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return library.appendingPathComponent("Sounds", isDirectory: true)
    }

    // MARK: - Choices

    static var builtInOptions: [SoundOption] {
        [SoundOption(id: deskDrop, title: String(localized: "DeskDrop"))]
            + systemNames.filter { systemFile($0) != nil }.map { SoundOption(id: systemPrefix + $0, title: $0) }
    }

    static var customOptions: [SoundOption] {
        let files = (try? FileManager.default.contentsOfDirectory(at: soundsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(customFilePrefix) && $0.pathExtension == "caf" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { SoundOption(id: customPrefix + $0.lastPathComponent, title: customTitle($0.lastPathComponent)) }
    }

    static func title(for id: String) -> String {
        if id == deskDrop { return String(localized: "DeskDrop") }
        if id.hasPrefix(systemPrefix) { return String(id.dropFirst(systemPrefix.count)) }
        if id.hasPrefix(customPrefix) { return customTitle(String(id.dropFirst(customPrefix.count))) }
        return String(localized: "DeskDrop")
    }

    private static func customTitle(_ fileName: String) -> String {
        String(fileName.dropFirst(customFilePrefix.count).dropLast(".caf".count))
    }

    private static func systemFile(_ name: String) -> URL? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The playable file for a choice; unknown or missing choices fall back to DeskDrop's sound.
    static func fileURL(for id: String) -> URL? {
        if id.hasPrefix(systemPrefix), let url = systemFile(String(id.dropFirst(systemPrefix.count))) {
            return url
        }
        if id.hasPrefix(customPrefix) {
            let url = soundsDirectory.appendingPathComponent(String(id.dropFirst(customPrefix.count)))
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return Bundle.main.url(forResource: bundledName, withExtension: "caf")
    }

    // MARK: - Playing

    private static var current: NSSound?

    /// Plays a choice in the app (for alerts that don't go through a notification, and previews).
    static func play(_ id: String) {
        current?.stop()
        guard let url = fileURL(for: id), let sound = NSSound(contentsOf: url, byReference: true) else {
            Log.app.error("Alert sound could not be loaded")
            return
        }
        current = sound
        sound.play()
    }

    /// The sound for a system notification.
    static func notificationSound(for id: String) -> UNNotificationSound {
        if id.hasPrefix(customPrefix) {
            let name = String(id.dropFirst(customPrefix.count))
            if FileManager.default.fileExists(atPath: soundsDirectory.appendingPathComponent(name).path) {
                return UNNotificationSound(named: UNNotificationSoundName(name))
            }
        }
        if id.hasPrefix(systemPrefix), let name = installSystemSound(String(id.dropFirst(systemPrefix.count))) {
            return UNNotificationSound(named: UNNotificationSoundName(name))
        }
        return UNNotificationSound(named: UNNotificationSoundName("\(bundledName).caf"))
    }

    /// Copies a built-in sound into `Library/Sounds`, where notifications can find it.
    private static func installSystemSound(_ name: String) -> String? {
        guard let source = systemFile(name) else { return nil }
        let fileName = "\(systemFilePrefix)\(name).aiff"
        let destination = soundsDirectory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                Log.app.error("Built-in sound could not be prepared for notifications: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return fileName
    }

    // MARK: - Adding sounds

    /// Converts any audio file macOS can read (MP3, M4A, WAV, AIFF…) into a CAF in
    /// `Library/Sounds`, trimmed to under 30 seconds, and returns its choice ID.
    static func importSound(from source: URL) async throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        if let size = (attributes?[.size] as? NSNumber)?.int64Value, size > 200 * 1024 * 1024 {
            throw SoundImportError.tooLarge
        }
        let directory = soundsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = NameSanitizer.sanitizeComponent(source.deletingPathExtension().lastPathComponent)
        var fileName = "\(customFilePrefix)\(base).caf"
        var attempt = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) {
            fileName = "\(customFilePrefix)\(base) \(attempt).caf"
            attempt += 1
        }
        let destination = directory.appendingPathComponent(fileName)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try await Task.detached(priority: .userInitiated) {
            try convert(source, to: destination, maxSeconds: maxSeconds)
        }.value
        return customPrefix + fileName
    }

    /// Decodes `source` and writes 16-bit PCM CAF, stopping at `maxSeconds`.
    nonisolated static func convert(_ source: URL, to destination: URL, maxSeconds: Double) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw SoundImportError.unreadable
        }
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let output = try AVAudioFile(forWriting: destination, settings: settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
                throw SoundImportError.unreadable
            }
            var remaining = min(input.length, AVAudioFramePosition(maxSeconds * format.sampleRate))
            while remaining > 0 {
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 32_768)))
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
                remaining -= AVAudioFramePosition(buffer.frameLength)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error is SoundImportError ? error : SoundImportError.unreadable
        }
    }

    /// Removes a sound you added.
    static func removeCustom(_ id: String) {
        guard id.hasPrefix(customPrefix) else { return }
        try? FileManager.default.removeItem(at: soundsDirectory.appendingPathComponent(String(id.dropFirst(customPrefix.count))))
    }

    static func isCustom(_ id: String) -> Bool { id.hasPrefix(customPrefix) }
}
