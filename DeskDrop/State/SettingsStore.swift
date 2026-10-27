import Foundation
import Observation

/// User preferences, persisted in UserDefaults. Nothing sensitive is stored here
/// (a GIPHY API key is meant to be shipped inside apps, so it isn't a secret).
@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults: UserDefaults

    /// Random, generated once per installation. Lets peers tell two Macs with the
    /// same display name apart. It is not a credential.
    let installationID: String

    var displayName: String {
        didSet { defaults.set(displayName, forKey: SettingsKey.displayName) }
    }

    var startSharingOnLaunch: Bool {
        didSet { defaults.set(startSharingOnLaunch, forKey: SettingsKey.startSharingOnLaunch) }
    }

    /// Quitting (⌘Q, the Dock) hides DeskDrop to the menu bar instead, so it keeps
    /// receiving files and messages and can still notify you.
    var keepRunningInMenuBar: Bool {
        didSet { defaults.set(keepRunningInMenuBar, forKey: SettingsKey.keepRunningInMenuBar) }
    }

    /// Colleagues see "…" while you type a one-on-one message.
    var sendTypingIndicator: Bool {
        didSet { defaults.set(sendTypingIndicator, forKey: SettingsKey.sendTypingIndicator) }
    }

    /// Whether the one-time explanation of that has been shown.
    var explainedMenuBarQuit: Bool {
        didSet { defaults.set(explainedMenuBarQuit, forKey: SettingsKey.explainedMenuBarQuit) }
    }

    var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: SettingsKey.showNotifications) }
    }

    var duplicateHandling: DuplicateHandling {
        didSet { defaults.set(duplicateHandling.rawValue, forKey: SettingsKey.duplicateHandling) }
    }

    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: SettingsKey.appearance) }
    }

    /// Hold a dragged file still to see nearby Macs around the cursor.
    var holdToShowNearby: Bool {
        didSet { defaults.set(holdToShowNearby, forKey: SettingsKey.holdToShowNearby) }
    }

    var holdDelay: HoldDelay {
        didSet { defaults.set(holdDelay.rawValue, forKey: SettingsKey.holdDelay) }
    }

    /// Push a dragged file against an assigned screen edge to send it.
    var edgeSharingEnabled: Bool {
        didSet { defaults.set(edgeSharingEnabled, forKey: SettingsKey.edgeSharingEnabled) }
    }

    /// Notifications for chat messages that arrive while their conversation isn't on screen.
    var messageNotifications: Bool {
        didSet { defaults.set(messageNotifications, forKey: SettingsKey.messageNotifications) }
    }

    /// DeskDrop's sound for incoming files and new messages.
    var playAlertSound: Bool {
        didSet { defaults.set(playAlertSound, forKey: SettingsKey.playAlertSound) }
    }

    /// Sound for incoming file requests (see `NotificationSounds`).
    var fileSound: String {
        didSet { defaults.set(fileSound, forKey: SettingsKey.fileSound) }
    }

    /// Sound for new messages.
    var messageSound: String {
        didSet { defaults.set(messageSound, forKey: SettingsKey.messageSound) }
    }

    /// Let colleagues see when you've read their one-on-one messages.
    var sendReadReceipts: Bool {
        didSet { defaults.set(sendReadReceipts, forKey: SettingsKey.sendReadReceipts) }
    }

    /// Emoji you picked recently, newest first.
    var recentEmoji: [String] {
        didSet { defaults.set(recentEmoji, forKey: SettingsKey.recentEmoji) }
    }

    /// Show **bold**, lists, code and other Markdown in messages.
    var renderMarkdown: Bool {
        didSet { defaults.set(renderMarkdown, forKey: SettingsKey.renderMarkdown) }
    }

    /// The GIPHY API key you entered. Empty means the built-in one, if any.
    var giphyAPIKey: String {
        didSet { defaults.set(giphyAPIKey, forKey: SettingsKey.giphyAPIKey) }
    }

    /// The key GIF and sticker search uses: yours, or the one built into DeskDrop.
    var effectiveGiphyKey: String {
        let own = giphyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? (GiphyClient.bundledKey ?? "") : own
    }

    var giphyRating: GiphyClient.Rating {
        didSet { defaults.set(giphyRating.rawValue, forKey: SettingsKey.giphyRating) }
    }

    /// GIFs and stickers move on their own (Reduce Motion always stops them).
    var autoplayGIFs: Bool {
        didSet { defaults.set(autoplayGIFs, forKey: SettingsKey.autoplayGIFs) }
    }

    /// New stickers keep just the subject of the picture.
    var stickerRemovesBackground: Bool {
        didSet { defaults.set(stickerRemovesBackground, forKey: SettingsKey.stickerRemovesBackground) }
    }

    /// Links you send get a preview (title and image), made on this Mac.
    var sendLinkPreviews: Bool {
        didSet { defaults.set(sendLinkPreviews, forKey: SettingsKey.sendLinkPreviews) }
    }

    /// Download updates and install them while DeskDrop is idle, then relaunch quietly.
    var installUpdatesAutomatically: Bool {
        didSet { defaults.set(installUpdatesAutomatically, forKey: SettingsKey.installUpdatesAutomatically) }
    }

    /// Set just before an automatic update relaunches DeskDrop, so the new copy
    /// comes back the way the old one was (window closed stays closed).
    func noteQuietRelaunch(showingWindow: Bool) {
        defaults.set(Date.now, forKey: SettingsKey.quietRelaunchAt)
        defaults.set(showingWindow, forKey: SettingsKey.quietRelaunchShowsWindow)
    }

    /// After an automatic update: whether to show the window. Nil if this launch
    /// isn't one (the note is used once and expires after two minutes).
    func takeQuietRelaunch() -> Bool? {
        defer {
            defaults.removeObject(forKey: SettingsKey.quietRelaunchAt)
            defaults.removeObject(forKey: SettingsKey.quietRelaunchShowsWindow)
        }
        guard let at = defaults.object(forKey: SettingsKey.quietRelaunchAt) as? Date,
              Date.now.timeIntervalSince(at) < 120 else { return nil }
        return defaults.bool(forKey: SettingsKey.quietRelaunchShowsWindow)
    }

    /// The GIFs and stickers picker opens where you last left it.
    var mediaPickerTab: String {
        didSet { defaults.set(mediaPickerTab, forKey: SettingsKey.mediaPickerTab) }
    }

    func noteEmojiUsed(_ emoji: String) {
        recentEmoji = Array(([emoji] + recentEmoji.filter { $0 != emoji }).prefix(24))
    }

    /// The glowing send and arrival effects.
    var proximityEffects: Bool {
        didSet { defaults.set(proximityEffects, forKey: SettingsKey.proximityEffects) }
    }

    var leftEdge: EdgeAssignment? {
        didSet { Self.store(leftEdge, forKey: SettingsKey.leftEdge, in: defaults) }
    }

    var rightEdge: EdgeAssignment? {
        didSet { Self.store(rightEdge, forKey: SettingsKey.rightEdge, in: defaults) }
    }

    func assignment(for edge: ScreenEdge) -> EdgeAssignment? {
        switch edge {
        case .left: leftEdge
        case .right: rightEdge
        }
    }

    func setAssignment(_ assignment: EdgeAssignment?, for edge: ScreenEdge) {
        switch edge {
        case .left: leftEdge = assignment
        case .right: rightEdge = assignment
        }
    }

    private static func store(_ assignment: EdgeAssignment?, forKey key: String, in defaults: UserDefaults) {
        if let assignment, let data = try? JSONEncoder().encode(assignment) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func loadAssignment(forKey key: String, in defaults: UserDefaults) -> EdgeAssignment? {
        guard let data = defaults.data(forKey: key),
              let assignment = try? JSONDecoder().decode(EdgeAssignment.self, from: data),
              UUID(uuidString: assignment.installationID) != nil else { return nil }
        return assignment
    }

    init(defaults: UserDefaults = .standard, fallbackDisplayName: () -> String = DeviceInfo.defaultDisplayName) {
        self.defaults = defaults

        if let stored = defaults.string(forKey: SettingsKey.installationID), UUID(uuidString: stored) != nil {
            installationID = stored
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: SettingsKey.installationID)
            installationID = generated
        }

        displayName = defaults.string(forKey: SettingsKey.displayName).flatMap(NameSanitizer.sanitizeDisplayName)
            ?? NameSanitizer.sanitizeDisplayName(fallbackDisplayName())
            ?? "Mac"
        startSharingOnLaunch = defaults.object(forKey: SettingsKey.startSharingOnLaunch) as? Bool ?? true
        keepRunningInMenuBar = defaults.object(forKey: SettingsKey.keepRunningInMenuBar) as? Bool ?? true
        explainedMenuBarQuit = defaults.bool(forKey: SettingsKey.explainedMenuBarQuit)
        sendTypingIndicator = defaults.object(forKey: SettingsKey.sendTypingIndicator) as? Bool ?? true
        showNotifications = defaults.object(forKey: SettingsKey.showNotifications) as? Bool ?? true
        duplicateHandling = defaults.string(forKey: SettingsKey.duplicateHandling).flatMap(DuplicateHandling.init(rawValue:)) ?? .keepBoth
        appearance = defaults.string(forKey: SettingsKey.appearance).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        holdToShowNearby = defaults.object(forKey: SettingsKey.holdToShowNearby) as? Bool ?? true
        holdDelay = (defaults.object(forKey: SettingsKey.holdDelay) as? Double).flatMap(HoldDelay.init(rawValue:)) ?? .medium
        edgeSharingEnabled = defaults.object(forKey: SettingsKey.edgeSharingEnabled) as? Bool ?? true
        proximityEffects = defaults.object(forKey: SettingsKey.proximityEffects) as? Bool ?? true
        messageNotifications = defaults.object(forKey: SettingsKey.messageNotifications) as? Bool ?? true
        playAlertSound = defaults.object(forKey: SettingsKey.playAlertSound) as? Bool ?? true
        fileSound = defaults.string(forKey: SettingsKey.fileSound) ?? NotificationSounds.deskDrop
        messageSound = defaults.string(forKey: SettingsKey.messageSound) ?? NotificationSounds.deskDrop
        sendReadReceipts = defaults.object(forKey: SettingsKey.sendReadReceipts) as? Bool ?? true
        recentEmoji = (defaults.stringArray(forKey: SettingsKey.recentEmoji) ?? []).compactMap(ChatValidator.sanitizeEmoji)
        renderMarkdown = defaults.object(forKey: SettingsKey.renderMarkdown) as? Bool ?? true
        giphyAPIKey = defaults.string(forKey: SettingsKey.giphyAPIKey) ?? ""
        giphyRating = defaults.string(forKey: SettingsKey.giphyRating).flatMap(GiphyClient.Rating.init(rawValue:)) ?? .g
        autoplayGIFs = defaults.object(forKey: SettingsKey.autoplayGIFs) as? Bool ?? true
        stickerRemovesBackground = defaults.object(forKey: SettingsKey.stickerRemovesBackground) as? Bool ?? true
        mediaPickerTab = defaults.string(forKey: SettingsKey.mediaPickerTab) ?? "gifs"
        sendLinkPreviews = defaults.object(forKey: SettingsKey.sendLinkPreviews) as? Bool ?? true
        installUpdatesAutomatically = defaults.object(forKey: SettingsKey.installUpdatesAutomatically) as? Bool ?? true
        leftEdge = Self.loadAssignment(forKey: SettingsKey.leftEdge, in: defaults)
        rightEdge = Self.loadAssignment(forKey: SettingsKey.rightEdge, in: defaults)
    }

    /// Applies a display name typed by the user. Returns false if nothing usable remains.
    @discardableResult
    func updateDisplayName(_ raw: String) -> Bool {
        guard let name = NameSanitizer.sanitizeDisplayName(raw) else { return false }
        if name != displayName { displayName = name }
        return true
    }
}
