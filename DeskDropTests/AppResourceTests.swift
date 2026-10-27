import AppKit
import AVFoundation
import Testing
import UserNotifications
@testable import DeskDrop

@Suite("Sounds and emoji")
@MainActor
struct AppResourceTests {
    @Test("DeskDrop's sound is bundled in a format and length notifications accept")
    func bundledSound() throws {
        let url = try #require(NotificationSounds.fileURL(for: NotificationSounds.deskDrop))
        #expect(url.pathExtension == "caf")
        let sound = try #require(NSSound(contentsOf: url, byReference: true))
        #expect(sound.duration > 0.5)
        #expect(sound.duration < 30, "System notifications ignore custom sounds of 30 seconds or more")
    }

    @Test("Built-in macOS sounds are offered and unknown choices fall back to DeskDrop's")
    func choices() {
        let options = NotificationSounds.builtInOptions
        #expect(options.first?.id == NotificationSounds.deskDrop)
        #expect(options.contains { $0.title == "Glass" })
        #expect(NotificationSounds.title(for: "system:Glass") == "Glass")
        #expect(NotificationSounds.fileURL(for: "custom:missing.caf")?.lastPathComponent == "DeskDropAlert.caf")
    }

    @Test("Added sound files are converted to CAF and trimmed to the notification limit")
    func conversion() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let source = try #require(NotificationSounds.fileURL(for: NotificationSounds.deskDrop))
        let destination = root.url.appendingPathComponent("converted.caf")
        try NotificationSounds.convert(source, to: destination, maxSeconds: 1.0)
        let file = try AVAudioFile(forReading: destination)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(seconds > 0.9 && seconds <= 1.01)

        let notAudio = try root.file("notes.txt", contents: Data("hello".utf8))
        #expect(throws: SoundImportError.unreadable) {
            try NotificationSounds.convert(notAudio, to: root.url.appendingPathComponent("bad.caf"), maxSeconds: 5)
        }
    }

    /// Library/Sounds is a link out of the sandbox container; without the
    /// entitlement exception both of these fail with "permission denied".
    @Test("A chosen macOS sound and an added sound can be stored where notifications find them")
    func soundsDirectoryIsWritable() async throws {
        let system = NotificationSounds.notificationSound(for: "system:Tink")
        let systemCopy = NotificationSounds.soundsDirectory.appendingPathComponent("DeskDropSystem-Tink.aiff")
        #expect(FileManager.default.fileExists(atPath: systemCopy.path))
        #expect(system != UNNotificationSound(named: UNNotificationSoundName("DeskDropAlert.caf")))

        let source = try #require(NotificationSounds.fileURL(for: NotificationSounds.deskDrop))
        let id = try await NotificationSounds.importSound(from: source)
        #expect(NotificationSounds.isCustom(id))
        let added = try #require(NotificationSounds.fileURL(for: id))
        #expect(added.path.hasPrefix(NotificationSounds.soundsDirectory.path) || added.resolvingSymlinksInPath().path.contains("/Library/Sounds/"))
        NotificationSounds.removeCustom(id)
        try? FileManager.default.removeItem(at: systemCopy)
    }

    @Test("Emoji search uses Unicode names")
    func emojiSearch() {
        #expect(EmojiCatalog.search("thumbs").contains("👍"))
        #expect(EmojiCatalog.search("joy").contains("😂"))
        #expect(EmojiCatalog.search("cat face").contains("🐱"))
        #expect(EmojiCatalog.search("zzzz-nothing").isEmpty)
        #expect(EmojiCatalog.tapbacks.allSatisfy { ChatValidator.sanitizeEmoji($0) != nil })
    }
}
