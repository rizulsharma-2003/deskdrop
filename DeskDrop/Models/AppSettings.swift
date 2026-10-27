import AppKit

/// What to do when a received item has the same name as something already in the
/// receiving folder.
enum DuplicateHandling: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Save as "Name 2.ext". Nothing is ever overwritten.
    case keepBoth
    /// Move the existing item to the Trash, then save. Falls back to keepBoth if the
    /// Trash is unavailable, so nothing is deleted irrecoverably.
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepBoth: String(localized: "Keep both (add a number)")
        case .replace: String(localized: "Replace (move the old one to the Trash)")
        }
    }
}

enum AppearanceMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// UserDefaults keys. Kept in one place so tests and the settings store agree.
enum SettingsKey {
    static let installationID = "installationID"
    static let displayName = "displayName"
    static let startSharingOnLaunch = "startSharingOnLaunch"
    static let showNotifications = "showNotifications"
    static let duplicateHandling = "duplicateHandling"
    static let appearance = "appearance"
    static let receivingDirectoryBookmark = "receivingDirectoryBookmark"
    static let archivedPeerID = "archivedPeerID"
    static let archivedPeerIDName = "archivedPeerIDName"
    static let holdToShowNearby = "holdToShowNearby"
    static let holdDelay = "holdDelay"
    static let edgeSharingEnabled = "edgeSharingEnabled"
    static let proximityEffects = "proximityEffects"
    static let leftEdge = "leftEdgeAssignment"
    static let rightEdge = "rightEdgeAssignment"
    static let messageNotifications = "messageNotifications"
    static let playAlertSound = "playAlertSound"
    static let fileSound = "fileSound"
    static let messageSound = "messageSound"
    static let sendReadReceipts = "sendReadReceipts"
    static let recentEmoji = "recentEmoji"
    static let keepRunningInMenuBar = "keepRunningInMenuBar"
    static let sendTypingIndicator = "sendTypingIndicator"
    static let explainedMenuBarQuit = "explainedMenuBarQuit"
    static let renderMarkdown = "renderMarkdown"
    static let giphyAPIKey = "giphyAPIKey"
    static let giphyRating = "giphyRating"
    static let autoplayGIFs = "autoplayGIFs"
    static let stickerRemovesBackground = "stickerRemovesBackground"
    static let mediaPickerTab = "mediaPickerTab"
    static let sendLinkPreviews = "sendLinkPreviews"
    static let installUpdatesAutomatically = "installUpdatesAutomatically"
    static let quietRelaunchAt = "quietRelaunchAt"
    static let quietRelaunchShowsWindow = "quietRelaunchShowsWindow"
}

/// How long a dragged file must be held still before nearby Macs appear around it.
enum HoldDelay: Double, CaseIterable, Identifiable, Sendable {
    case short = 0.5
    case medium = 0.75
    case long = 1.1

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .short: String(localized: "Short")
        case .medium: String(localized: "Medium")
        case .long: String(localized: "Long")
        }
    }
}
