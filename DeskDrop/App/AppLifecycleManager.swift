import AppKit
import SwiftUI
import Observation
import UserNotifications

/// Owns the single view model and coordinates app-level behaviour around it:
/// starting and stopping networking, presenting incoming requests in a floating
/// panel, notifications, and quitting safely.
@MainActor
final class AppLifecycleManager {
    let model: DeskDropViewModel
    private let notifications = NotificationService()
    private lazy var incomingPanel = IncomingPanelController(model: model)
    private lazy var dragOverlay = DragOverlayController(model: model)

    /// Hosted unit tests launch the app; they must not start networking.
    private let isHostingUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var isUITesting: Bool {
        #if DEBUG
        UITestSupport.isUITesting
        #else
        false
        #endif
    }

    init() {
        #if DEBUG
        if UITestSupport.isUITesting, let defaults = UserDefaults(suiteName: UITestSupport.defaultsSuite) {
            // UI tests start clean and never touch the user's real settings or history.
            defaults.removePersistentDomain(forName: UITestSupport.defaultsSuite)
            let history = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDropUITestHistory.json")
            let chat = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDropUITestChat.json")
            let media = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDropUITestMedia", isDirectory: true)
            let updates = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDropUITestUpdates", isDirectory: true)
            try? FileManager.default.removeItem(at: history)
            try? FileManager.default.removeItem(at: chat)
            try? FileManager.default.removeItem(at: media)
            model = DeskDropViewModel(defaults: defaults, historyURL: history, chatURL: chat, mediaDirectory: media,
                                      updatesDirectory: updates)
        } else {
            model = DeskDropViewModel()
        }
        #else
        model = DeskDropViewModel()
        #endif
        model.onIncomingOffer = { [weak self] transfer in self?.presentIncoming(transfer) }
        model.onTransferFinished = { [weak self] transfer in self?.transferFinished(transfer) }
        model.onPreviewEffect = { [weak self] in self?.dragOverlay.previewEffect() }
        model.onTestNotification = { [weak self] in self?.sendTestNotification() }
        model.onQuitCompletely = { [weak self] in self?.quitCompletely() }
        model.onShowMainWindow = { [weak self] in self?.showMainWindow() }
        model.chat.onMessageReceived = { [weak self] message in self?.messageArrived(message) }
        notifications.onOpenConversation = { [weak self] conversation in
            self?.showMainWindow()
            self?.model.showMessages(conversation)
        }
        notifications.onReply = { [weak self] text, conversation in
            self?.model.chat.reply(text, in: conversation)
        }
        notifications.onOpenApp = { [weak self] in self?.showMainWindow() }
        notifications.onOpenUpdate = { [weak self] in
            self?.showMainWindow()
            self?.model.showingUpdate = true
        }
        model.updates.onUpdateFound = { [weak self] manifest, name in
            self?.notifications.notifyUpdate(version: manifest.version, from: name)
        }
        model.updates.onInstalled = { [weak self] automatic, app in
            guard let self else { return }
            if automatic {
                // Come back as we were: a closed window stays closed.
                let showing = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == SceneID.main }
                model.settings.noteQuietRelaunch(showingWindow: showing)
            }
            UpdateInstaller.relaunch(app) { self.quitCompletely() }
        }
    }

    func didFinishLaunching() {
        NSApp.appearance = model.settings.appearance.nsAppearance
        guard !isHostingUnitTests else { return }
        notifications.start(requestingPermission: !isUITesting)
        if let showWindow = isUITesting ? nil : model.settings.takeQuietRelaunch() {
            // Relaunched by an automatic update.
            if showWindow { ensureMainWindowIsShown() }
            notifications.notifyUpdated(to: DeviceInfo.shortVersion)
        } else {
            ensureMainWindowIsShown()
        }
        #if DEBUG
        if UITestSupport.isUITesting {
            observeIncomingPanel()
            model.startForUITesting(injectIncomingOffer: UITestSupport.injectsIncomingOffer)
            if UITestSupport.injectsPeer {
                model.injectPeerForUITesting(assignToLeftEdge: UITestSupport.assignsLeftEdge)
            }
            if UITestSupport.seedsChat {
                model.seedChatHistoryForUITesting()
            }
            if UITestSupport.opensMessages {
                model.showMessages(UITestSupport.opensDirectConversation ? .direct("00000000-0000-4000-8000-000000000002") : nil)
            }
            if UITestSupport.simulatesLiveMessages {
                model.simulateLiveMessagesForUITesting()
            }
            if UITestSupport.showsTyping {
                model.chat.showTypingForUITesting("00000000-0000-4000-8000-000000000002")
            }
            if let package = UITestSupport.installsUpdate {
                model.publishUpdate(at: package)
                model.showingUpdate = true
                model.updates.update()
            } else if UITestSupport.checksForUpdates {
                Task { @MainActor [model] in
                    await model.updates.checkFeed()
                    Log.app.notice("UI testing: checked GitHub; available \(model.updates.available?.manifest.version ?? "none", privacy: .public)")
                    model.updates.update()
                }
            } else if let package = UITestSupport.showsUpdate {
                model.publishUpdate(at: package)
                model.showingUpdate = true
            }
            refreshNotificationStatus()
            // Long enough for the test to inspect the overlay after releasing the drag.
            dragOverlay.teardownDelay = .seconds(4)
            observeGestureSettings()
            return
        }
        #endif
        observeIncomingPanel()
        observeGestureSettings()
        observeUnreadMessages()
        observeOpenConversation()
        observeMainWindowVisibility()
        refreshNotificationStatus()
        // After an update, the copy that's quitting finishes first.
        Task { @MainActor [weak self] in
            await RelaunchSupport.waitForPreviousCopy()
            self?.model.start()
        }
    }

    /// Runs the drag gestures while sharing is on and at least one gesture is enabled.
    private func observeGestureSettings() {
        let wanted = withObservationTracking {
            let settings = model.settings
            _ = settings.holdDelay
            return (model.isSharingEnabled || isUITesting) && (settings.holdToShowNearby || settings.edgeSharingEnabled)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeGestureSettings()
            }
        }
        dragOverlay.setEnabled(wanted)
    }

    // MARK: - Quitting

    /// Set by "Quit DeskDrop Completely", so the next termination really quits.
    private var quittingCompletely = false

    func shouldTerminate() -> NSApplication.TerminateReply {
        if !quittingCompletely, model.settings.keepRunningInMenuBar, !isSystemQuit, !isUITesting, !isHostingUnitTests {
            return keepRunningInMenuBar()
        }
        let reply = confirmQuitDuringTransfers()
        if reply == .terminateCancel { quittingCompletely = false }
        return reply
    }

    private func confirmQuitDuringTransfers() -> NSApplication.TerminateReply {
        let moving = model.transfers.transfers.filter { $0.phase.isMovingData }
        guard !moving.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Quit DeskDrop?")
        alert.informativeText = moving.count == 1
            ? String(localized: "A transfer is in progress and will be cancelled.")
            : String(localized: "\(moving.count) transfers are in progress and will be cancelled.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Keep Running"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func willTerminate() {
        model.shutdown()
    }

    func quitCompletely() {
        quittingCompletely = true
        NSApp.terminate(nil)
    }

    /// Logging out, restarting and shutting down must always quit. Those quit
    /// events carry a reason; ⌘Q and the Dock's Quit don't.
    private var isSystemQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication) else { return false }
        return event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    /// "Quitting" closes DeskDrop's windows and removes it from the Dock, but it
    /// keeps running in the menu bar: colleagues can still reach you, and new
    /// messages and files still notify you. The first time, it says so.
    private func keepRunningInMenuBar() -> NSApplication.TerminateReply {
        if !model.settings.explainedMenuBarQuit {
            model.settings.explainedMenuBarQuit = true
            let alert = NSAlert()
            alert.messageText = String(localized: "DeskDrop will keep running in the menu bar")
            alert.informativeText = String(localized: "So colleagues can still send you files and messages, and you’ll still be notified. To stop DeskDrop completely, click its menu bar icon and choose Quit DeskDrop Completely. You can change this in Settings › General.")
            alert.addButton(withTitle: String(localized: "Keep Running"))
            alert.addButton(withTitle: String(localized: "Quit Completely"))
            if alert.runModal() == .alertSecondButtonReturn {
                quittingCompletely = true
                return shouldTerminate()
            }
        }
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
            window.close()
        }
        model.chat.activeConversation = nil
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    /// Provided by the SwiftUI scene so AppKit code can open windows.
    var openWindow: OpenWindowAction?

    func showMainWindow() {
        // Back in the Dock if "quitting" had hidden DeskDrop to the menu bar.
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        openWindow?(id: SceneID.main)
        NSApp.activate()
    }

    /// Because DeskDrop also lives in the menu bar, macOS may start it with no
    /// window (for example on a fresh install). Launching should always show the
    /// main window, so open it if window restoration didn't.
    private func ensureMainWindowIsShown(attempt: Int = 0) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self else { return }
            let visible = NSApp.windows.contains { $0.identifier?.rawValue == SceneID.main && $0.isVisible }
            guard !visible else { return }
            if let openWindow {
                // Opening without activating: when launched at login, DeskDrop
                // shouldn't take focus from what you're doing.
                openWindow(id: SceneID.main)
            } else if attempt < 10 {
                ensureMainWindowIsShown(attempt: attempt + 1)
            }
        }
    }

    // MARK: - Messages

    private func messageArrived(_ message: ChatMessage) {
        guard !isUITesting else { return }
        let route = AlertPolicy.forMessage(
            onScreen: NSApp.isActive && isMainWindowKeyAndOnScreen && model.chat.activeConversation == message.conversation,
            inFront: NSApp.isActive && isMainWindowOnScreen,
            notificationsOn: model.settings.messageNotifications,
            soundOn: model.settings.playAlertSound)
        let title = model.title(for: message.conversation)
        alert(route, sound: model.settings.messageSound) { sound in
            notifications.notifyMessage(message, in: title, sound: sound)
        }
    }

    /// The main window is open, not minimized, and at least partly visible.
    private var isMainWindowOnScreen: Bool {
        NSApp.windows.contains { window in
            window.identifier?.rawValue == SceneID.main && window.isVisible && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }

    /// The main window is on screen and is the one you're typing in.
    private var isMainWindowKeyAndOnScreen: Bool {
        guard let key = NSApp.keyWindow, key.identifier?.rawValue == SceneID.main else { return false }
        return !key.isMiniaturized && key.occlusionState.contains(.visible)
    }

    /// A minimized, closed or hidden window isn't "reading" a conversation: new
    /// messages there must alert you and stay unread (and send no read receipt).
    private func observeMainWindowVisibility() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification,
                                          NSWindow.didChangeOcclusionStateNotification,
                                          NSApplication.didHideNotification]
        for name in names {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mainWindowVisibilityChanged() }
            }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNotificationStatus() }
        }
        // Coming back (un-minimizing, clicking the window) resumes reading the open
        // conversation even if SwiftUI didn't notice the window was ever inactive.
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            // Only the window's identity crosses into the main-actor block.
            let window = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                let main = NSApp.windows.first { $0.identifier?.rawValue == SceneID.main }
                if let main, ObjectIdentifier(main) == window { self?.mainWindowBecameKey() }
            }
        }
    }

    private func mainWindowVisibilityChanged() {
        if !isMainWindowOnScreen || NSApp.isHidden {
            model.chat.activeConversation = nil
        }
    }

    private func mainWindowBecameKey() {
        guard model.mainSection == .messages, isMainWindowKeyAndOnScreen else { return }
        model.chat.activeConversation = model.chatSelection
    }

    /// Keeps the "notifications are off" notice in Messages up to date.
    private func refreshNotificationStatus() {
        Task { @MainActor [weak self] in
            let status = await NotificationService.authorizationStatus()
            self?.model.notificationsBlocked = status == .denied
        }
    }

    /// Opening a conversation clears its banners from Notification Center.
    private func observeOpenConversation() {
        let open = withObservationTracking {
            model.chat.activeConversation
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeOpenConversation()
            }
        }
        if let open { notifications.removeMessageNotifications(in: open) }
    }

    /// Settings › Receiving › Messages › Send Test Notification.
    private func sendTestNotification() {
        let sound = model.settings.playAlertSound ? NotificationSounds.notificationSound(for: model.settings.messageSound) : nil
        notifications.notifyTest(sound: sound)
    }

    /// Shows the number of unread messages on the Dock icon.
    private func observeUnreadMessages() {
        let unread = withObservationTracking {
            model.unreadMessageCount
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeUnreadMessages()
            }
        }
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }

    // MARK: - Incoming

    private func presentIncoming(_ transfer: Transfer) {
        syncIncomingPanel()
        guard !isUITesting else { return }
        dragOverlay.playArrival()
        let route = AlertPolicy.forFile(appActive: NSApp.isActive, notificationsOn: model.settings.showNotifications,
                                        soundOn: model.settings.playAlertSound)
        alert(route, sound: model.settings.fileSound) { sound in
            notifications.notifyIncomingOffer(transfer, sound: sound)
        }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// A banner carries the chosen sound; in front, the sound plays directly so
    /// the alert isn't silent.
    private func alert(_ route: AlertRoute, sound soundID: String, post: (UNNotificationSound?) -> Void) {
        switch route {
        case .none:
            break
        case .sound:
            NotificationSounds.play(soundID)
        case .banner:
            post(model.settings.playAlertSound ? NotificationSounds.notificationSound(for: soundID) : nil)
        }
    }

    private func transferFinished(_ transfer: Transfer) {
        guard transfer.direction == .incoming, !isUITesting else { return }
        notifications.removeNotification(for: transfer.id)
        if transfer.phase == .completed, !NSApp.isActive, model.settings.showNotifications {
            notifications.notifyReceived(transfer)
        }
    }

    /// Shows the panel whenever there is an incoming transfer to present, and
    /// hides it when there is none, by observing the model.
    private func observeIncomingPanel() {
        withObservationTracking {
            syncIncomingPanel()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observeIncomingPanel()
            }
        }
    }

    private func syncIncomingPanel() {
        if model.currentPanelTransfer != nil {
            incomingPanel.show()
        } else {
            incomingPanel.hide()
        }
    }
}

#if DEBUG
/// Launch arguments used by the UI tests.
enum UITestSupport {
    static let defaultsSuite = "com.deskdrop.app.uitesting"

    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITesting")
    }

    static var injectsIncomingOffer: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestIncomingOffer")
    }

    static var injectsPeer: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestPeer")
    }

    static var opensMessages: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestOpenMessages")
    }

    static var opensDirectConversation: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestOpenDirect")
    }

    static var seedsChat: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestChatHistory")
    }

    static var assignsLeftEdge: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestLeftEdge")
    }

    /// Simulates a colleague sending a message every second into the open conversation.
    static var simulatesLiveMessages: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestLiveMessages")
    }

    /// Installs this update package straight away (end-to-end update test).
    static var installsUpdate: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DeskDropUITestInstallUpdate"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// Checks GitHub for an update and installs it (end-to-end update test).
    static var checksForUpdates: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestCheckForUpdates")
    }

    /// Offers this update package and opens the update sheet, without installing.
    static var showsUpdate: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-DeskDropUITestShowUpdate"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// Opens the GIFs and stickers picker in the open conversation.
    static var opensMediaPicker: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestMediaPicker")
    }

    /// Shows the test colleague as typing.
    static var showsTyping: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestTyping")
    }

    /// Opens the conversation scrolled to its oldest message.
    static var startsScrolledUp: Bool {
        ProcessInfo.processInfo.arguments.contains("-DeskDropUITestScrolledUp")
    }
}
#endif
