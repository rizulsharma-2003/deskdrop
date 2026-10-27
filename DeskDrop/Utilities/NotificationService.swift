import AppKit
import UserNotifications

/// How to tell the user about something new.
enum AlertRoute: Equatable, Sendable {
    /// Nothing: they're already looking at it, or sounds and banners are off.
    case none
    /// Play the sound in the app; DeskDrop is in front.
    case sound
    /// Post a system notification, which carries the sound.
    case banner
}

/// When DeskDrop shows a banner, plays a sound, or stays quiet.
enum AlertPolicy {
    /// - Parameters:
    ///   - onScreen: DeskDrop is active and this conversation is open in the focused window.
    ///   - inFront: DeskDrop is the active app and its main window is on screen.
    static func forMessage(onScreen: Bool, inFront: Bool, notificationsOn: Bool, soundOn: Bool) -> AlertRoute {
        if onScreen { return .none }
        if !inFront, notificationsOn { return .banner }
        return soundOn ? .sound : .none
    }

    /// Incoming files always get the floating request panel, so a banner is only
    /// needed while another app is in front.
    static func forFile(appActive: Bool, notificationsOn: Bool, soundOn: Bool) -> AlertRoute {
        if !appActive, notificationsOn { return .banner }
        return soundOn ? .sound : .none
    }
}

/// System notifications. They point the user at DeskDrop (accepting or declining
/// files always happens in the app), open the conversation when clicked, and let
/// you reply to a message straight from the banner. Everything keeps working if
/// the user never grants permission.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let messageCategory = "deskdrop.message"
    nonisolated static let replyAction = "deskdrop.reply"
    nonisolated private static let conversationKey = "conversation"
    nonisolated private static let updateKey = "update"

    /// A message notification was clicked.
    var onOpenConversation: ((ConversationID) -> Void)?
    /// Reply typed into a message notification.
    var onReply: ((String, ConversationID) -> Void)?
    /// Any other notification was clicked.
    var onOpenApp: (() -> Void)?
    /// An "update available" notification was clicked.
    var onOpenUpdate: (() -> Void)?

    private var authorization: Task<Void, Never>?

    /// Becomes the notification delegate and registers the Reply action. Outside
    /// tests it also asks for permission up front, so the very first message can
    /// already show a banner.
    func start(requestingPermission: Bool) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: String(localized: "Reply"),
                                                  options: [], textInputButtonTitle: String(localized: "Send"),
                                                  textInputPlaceholder: String(localized: "Message"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.messageCategory, actions: [reply], intentIdentifiers: [], options: []),
        ])
        if requestingPermission {
            requestAuthorizationIfNeeded()
        } else {
            Task {
                let status = await Self.authorizationStatus()
                Log.app.notice("Notification permission status: \(status.rawValue, privacy: .public)")
            }
        }
    }

    func notifyIncomingOffer(_ transfer: Transfer, sound: UNNotificationSound?) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "\(transfer.peerName) wants to send you a file")
        content.body = String(localized: "\(transfer.title) · \(FileSizeFormatter.string(fromBytes: transfer.totalBytes)). Open DeskDrop to accept or decline.")
        content.sound = sound
        post(content, id: transfer.id)
    }

    func notifyReceived(_ transfer: Transfer) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Received from \(transfer.peerName)")
        content.body = transfer.title
        post(content, id: transfer.id)
    }

    func notifyMessage(_ message: ChatMessage, in conversationTitle: String, sound: UNNotificationSound?) {
        let content = UNMutableNotificationContent()
        content.title = message.conversation.isCommunity ? String(localized: "\(message.senderName) · \(conversationTitle)") : message.senderName
        content.body = message.previewText
        content.sound = sound
        content.threadIdentifier = message.conversation.rawValue
        content.categoryIdentifier = Self.messageCategory
        content.userInfo = [Self.conversationKey: message.conversation.rawValue]
        post(content, id: message.id)
    }

    /// A newer DeskDrop is available from a colleague.
    func notifyUpdate(version: String, from name: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "DeskDrop \(version) is available")
        content.body = String(localized: "From \(name). Click to see what’s new and update.")
        content.userInfo = [Self.updateKey: version]
        post(content, id: UUID())
    }

    /// A sample message notification, for checking permission and the sound.
    func notifyTest(sound: UNNotificationSound?) {
        let content = UNMutableNotificationContent()
        content.title = "DeskDrop"
        content.body = String(localized: "Notifications are working. New messages will look like this.")
        content.sound = sound
        post(content, id: UUID())
    }

    func removeNotification(for id: UUID) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }

    /// Clears a conversation's banners from Notification Center once it's read.
    func removeMessageNotifications(in conversation: ConversationID) {
        let thread = conversation.rawValue
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await Self.deliveredIDs(inThread: thread)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// System Settings › Notifications › DeskDrop.
    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? "com.deskdrop.app"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether macOS currently lets DeskDrop show notifications.
    nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    nonisolated private static func deliveredIDs(inThread thread: String) async -> [String] {
        await UNUserNotificationCenter.current().deliveredNotifications()
            .filter { $0.request.content.threadIdentifier == thread }
            .map(\.request.identifier)
    }

    /// Asks once per launch, and only if the user hasn't decided yet.
    @discardableResult
    func requestAuthorizationIfNeeded() -> Task<Void, Never> {
        if let authorization { return authorization }
        let task = Task {
            let status = await Self.authorizationStatus()
            guard status == .notDetermined else {
                Log.app.notice("Notification permission status: \(status.rawValue, privacy: .public)")
                return
            }
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                Log.app.notice("Notification permission \(granted ? "granted" : "declined", privacy: .public)")
            } catch {
                Log.app.error("Notification permission request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        authorization = task
        return task
    }

    private func post(_ content: UNMutableNotificationContent, id: UUID) {
        let request = UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil)
        let ready = requestAuthorizationIfNeeded()
        Task {
            await ready.value
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.app.error("Notification not shown: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// DeskDrop only posts when a banner is wanted, so show it even if DeskDrop
    /// has come to the front in the meantime.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if userInfo[Self.updateKey] != nil {
            await MainActor.run { onOpenUpdate?() }
            return
        }
        let conversation = userInfo[Self.conversationKey] as? String
        let reply = response.actionIdentifier == Self.replyAction
            ? (response as? UNTextInputNotificationResponse)?.userText
            : nil
        await handleResponse(conversation: conversation, reply: reply)
    }

    private func handleResponse(conversation raw: String?, reply: String?) {
        guard let raw else {
            onOpenApp?()
            return
        }
        let conversation = ConversationID(rawValue: raw)
        if let reply {
            onReply?(reply, conversation)
        } else {
            onOpenConversation?(conversation)
        }
    }
}
