import Foundation

/// The single status shown in the header and menu bar, derived from real
/// discovery, permission, network and peer state.
enum NetworkStatus: Equatable, Sendable {
    case paused
    case discovering
    case connecting
    case ready(peerCount: Int)
    case noColleagues
    case permissionRequired
    case unavailable
    case connectionProblem

    enum Tone: Sendable {
        case neutral
        case active
        case success
        case warning
        case danger
    }

    var title: String {
        switch self {
        case .paused: String(localized: "Sharing off")
        case .discovering: String(localized: "Discovering nearby Macs")
        case .connecting: String(localized: "Connecting")
        case .ready: String(localized: "Ready to share")
        case .noColleagues: String(localized: "No colleagues found")
        case .permissionRequired: String(localized: "Network permission required")
        case .unavailable: String(localized: "Temporarily unavailable")
        case .connectionProblem: String(localized: "Connection problem")
        }
    }

    var detail: String {
        switch self {
        case .paused:
            String(localized: "Other Macs can’t see you. Turn sharing on to send and receive.")
        case .discovering:
            String(localized: "Looking for colleagues running DeskDrop on this network.")
        case .connecting:
            String(localized: "Setting up an encrypted connection.")
        case .ready(let count):
            count == 1
                ? String(localized: "1 colleague can receive files.")
                : String(localized: "\(count) colleagues can receive files.")
        case .noColleagues:
            String(localized: "Ask colleagues to open DeskDrop. Everyone must be on the same network.")
        case .permissionRequired:
            String(localized: "Allow DeskDrop under System Settings › Privacy & Security › Local Network.")
        case .unavailable:
            String(localized: "No usable network connection. DeskDrop will resume automatically.")
        case .connectionProblem:
            String(localized: "Nearby Macs were found but couldn’t be reached. Try Refresh.")
        }
    }

    var symbolName: String {
        switch self {
        case .paused: "pause.circle"
        case .discovering, .connecting: "dot.radiowaves.left.and.right"
        case .ready: "checkmark.circle"
        case .noColleagues: "person.2.slash"
        case .permissionRequired: "lock.shield"
        case .unavailable: "wifi.slash"
        case .connectionProblem: "exclamationmark.triangle"
        }
    }

    var tone: Tone {
        switch self {
        case .paused, .noColleagues: .neutral
        case .discovering, .connecting: .active
        case .ready: .success
        case .permissionRequired, .unavailable: .warning
        case .connectionProblem: .danger
        }
    }

    var isSearching: Bool {
        self == .discovering || self == .connecting
    }
}
