import AppKit
import CryptoKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// A dismissible message shown under the header.
struct AppBanner: Identifiable, Equatable {
    enum Style: Equatable {
        case info
        case warning
        case error
    }

    enum Action: Equatable {
        case retry(UUID)
        case openNetworkSettings
        case refresh
    }

    let id = UUID()
    let style: Style
    let title: String
    var message: String?
    var action: Action?

    var actionTitle: String? {
        switch action {
        case .retry: String(localized: "Try Again")
        case .openNetworkSettings: String(localized: "Open Settings")
        case .refresh: String(localized: "Refresh")
        case nil: nil
        }
    }
}

/// A short label under a device card describing the latest transfer with that peer.
struct CardActivity: Equatable {
    enum Style: Equatable {
        case progress
        case success
        case warning
        case neutral
    }

    let text: String
    let style: Style
}

/// The app's single source of UI state. Owns the services, translates their
/// events into something views can show, and exposes user actions.
@MainActor
@Observable
final class DeskDropViewModel {
    let settings: SettingsStore
    let history: HistoryStore
    let transfers: TransferService
    let chat: ChatService
    /// Profile photos and stickers kept on this Mac.
    let library: MediaLibrary
    /// GIFs and stickers downloaded from GIPHY.
    @ObservationIgnored let remoteImages = RemoteImageCache()
    /// DeskDrop updates from colleagues' Macs.
    let updates: UpdateService
    /// The update sheet is open.
    var showingUpdate = false

    /// What the main window shows: the desk of nearby Macs, or Messages.
    enum MainSection: Hashable {
        case nearby
        case messages
    }

    var mainSection: MainSection = .nearby

    /// The conversation shown in Messages.
    var chatSelection: ConversationID = .community

    /// Switches the main window to Messages, optionally opening a conversation.
    func showMessages(_ conversation: ConversationID? = nil) {
        if let conversation { chatSelection = conversation }
        mainSection = .messages
    }

    private(set) var peers: [PeerDevice] = []
    private(set) var discoveryState: DiscoveryState = .stopped
    private(set) var isSharingEnabled = false
    private(set) var permissionDenied = false
    private(set) var networkAvailable = true
    private(set) var searchGraceElapsed = false
    private(set) var receivingFolderPath: String
    private(set) var isUsingDefaultReceivingFolder: Bool
    private(set) var panelDismissedIDs: Set<UUID> = []
    private(set) var recentlyFinishedIDs: Set<UUID> = []
    var banner: AppBanner?

    @ObservationIgnored var onIncomingOffer: ((Transfer) -> Void)?
    @ObservationIgnored var onTransferFinished: ((Transfer) -> Void)?
    /// Plays the send effect on screen, for the Settings preview.
    @ObservationIgnored var onPreviewEffect: (() -> Void)?
    /// Posts a sample message notification, for Settings.
    @ObservationIgnored var onTestNotification: (() -> Void)?
    /// Quits for real, even when quitting normally keeps DeskDrop in the menu bar.
    @ObservationIgnored var onQuitCompletely: (() -> Void)?
    /// Brings DeskDrop back into the Dock and shows the main window.
    @ObservationIgnored var onShowMainWindow: (() -> Void)?

    /// macOS has notifications for DeskDrop switched off, so banners can't appear.
    var notificationsBlocked = false

    @ObservationIgnored let connection: PeerConnectionService
    @ObservationIgnored let destination: FileDestinationManager
    @ObservationIgnored private let permissionProbe = LocalNetworkPermissionProbe()
    @ObservationIgnored private let pathObserver = NetworkPathObserver()
    @ObservationIgnored private let timers = ScheduledTasks<TimerKey>()
    @ObservationIgnored private let deviceKind = DeviceInfo.deviceKind
    @ObservationIgnored private var lastInterfaces: [String] = []

    /// How long discovery runs before "No colleagues found" replaces "Discovering".
    private static let searchGrace: Duration = .seconds(12)
    private static let cardLabelLinger: Duration = .seconds(6)
    private static let panelAutoDismiss: Duration = .seconds(30)
    private static let bannerAutoDismiss: Duration = .seconds(8)

    private enum TimerKey: Hashable {
        case searchGrace
        case networkRestart
        case banner
        case linger(UUID)
        case panelDismiss(UUID)
    }

    init(defaults: UserDefaults = .standard, historyURL: URL = HistoryStore.defaultFileURL,
         chatURL: URL = ChatStore.defaultFileURL, mediaDirectory: URL = MediaLibrary.defaultDirectory,
         updatesDirectory: URL = UpdateService.defaultDirectory) {
        let settings = SettingsStore(defaults: defaults)
        let destination = FileDestinationManager(defaults: defaults) { settings.duplicateHandling }
        let connection = PeerConnectionService(defaults: defaults)
        let library = MediaLibrary(directory: mediaDirectory)
        self.settings = settings
        self.destination = destination
        self.connection = connection
        self.library = library
        self.history = HistoryStore(fileURL: historyURL)
        self.transfers = TransferService(transport: connection, destination: destination)
        self.updates = UpdateService(transport: connection, publicKey: Self.updatePublicKey,
                                     bundleID: Bundle.main.bundleIdentifier ?? "com.deskdrop.app",
                                     currentVersion: DeviceInfo.shortVersion, directory: updatesDirectory,
                                     installer: UpdateInstaller())
        self.chat = ChatService(transport: connection, store: ChatStore(fileURL: chatURL),
                                media: MediaExchange(transport: connection, library: library),
                                linkPreviews: { url in
                                    settings.sendLinkPreviews ? await LinkPreviewer.preview(for: url, library: library) : nil
                                },
                                sendsReadReceipts: { settings.sendReadReceipts },
                                sendsTyping: { settings.sendTypingIndicator }) {
            (settings.installationID, settings.displayName)
        }
        self.receivingFolderPath = destination.receivingDirectory.path
        self.isUsingDefaultReceivingFolder = destination.isUsingDefaultDirectory

        connection.onPeersChanged = { [weak self] peers in self?.peersChanged(peers) }
        connection.onStateChanged = { [weak self] state in self?.discoveryState = state }
        transfers.onIncomingOffer = { [weak self] transfer in self?.didReceiveOffer(transfer) }
        transfers.onTransferFinished = { [weak self] transfer in self?.didFinish(transfer) }
        permissionProbe.onChange = { [weak self] denied in self?.permissionDenied = denied }
        pathObserver.onChange = { [weak self] available, interfaces in self?.networkChanged(available, interfaces: interfaces) }
    }

    // MARK: - Lifecycle

    func start() {
        destination.removeStaleStagingFiles()
        Task.detached(priority: .background) { RemoteImageCache.trimDisk() }
        pathObserver.start()
        setSharingEnabled(settings.startSharingOnLaunch)
    }

    func shutdown() {
        chat.store.flush()
        transfers.cancelAll()
        connection.stop()
        permissionProbe.stop()
        pathObserver.stop()
        timers.cancelAll()
    }

    func setSharingEnabled(_ enabled: Bool) {
        isSharingEnabled = enabled
        if enabled {
            connection.start(identity: identity)
            permissionProbe.start()
            restartSearchGrace()
        } else {
            transfers.cancelAll()
            connection.stop()
            permissionProbe.stop()
            timers.cancel(.searchGrace)
        }
    }

    /// Restarts discovery and retries peers that stopped responding.
    func refresh() {
        guard isSharingEnabled else {
            setSharingEnabled(true)
            return
        }
        for peer in peers where peer.presence == .unavailable {
            connection.reconnect(peer.id)
        }
        connection.restartDiscovery()
        restartSearchGrace()
    }

    /// Applies a new display name. Reconnects to peers so they see it.
    @discardableResult
    func applyDisplayName(_ raw: String) -> Bool {
        let previous = settings.displayName
        guard settings.updateDisplayName(raw) else { return false }
        if isSharingEnabled, settings.displayName != previous {
            connection.start(identity: identity)
            restartSearchGrace()
        }
        return true
    }

    private var identity: LocalIdentity {
        LocalIdentity(installationID: settings.installationID, displayName: settings.displayName,
                      deviceKind: deviceKind, appVersion: DeviceInfo.shortVersion)
    }

    var localDeviceKind: DeviceKind { deviceKind }

    private func restartSearchGrace() {
        searchGraceElapsed = false
        timers.schedule(.searchGrace, after: Self.searchGrace) { [weak self] in
            self?.searchGraceElapsed = true
        }
    }

    private func networkChanged(_ available: Bool, interfaces: [String]) {
        let wasAvailable = networkAvailable
        networkAvailable = available
        defer { lastInterfaces = interfaces }
        guard available, !lastInterfaces.isEmpty, !wasAvailable || interfaces != lastInterfaces else { return }
        // Wi-Fi changed or came back: restart discovery once things settle.
        timers.schedule(.networkRestart, after: .seconds(2)) { [weak self] in
            guard let self, self.isSharingEnabled else { return }
            Log.network.info("Network changed; restarting discovery")
            self.connection.restartDiscovery()
            self.restartSearchGrace()
        }
    }

    // MARK: - Status

    var networkStatus: NetworkStatus {
        guard isSharingEnabled else { return .paused }
        if permissionDenied || discoveryState == .failed(.permissionDenied) { return .permissionRequired }
        if !networkAvailable { return .unavailable }
        if case .failed = discoveryState { return .unavailable }
        let ready = peers.filter { $0.presence == .ready }.count
        if ready > 0 { return .ready(peerCount: ready) }
        if peers.contains(where: { $0.presence == .connecting || $0.presence == .connected || $0.presence == .discovered }) {
            return .connecting
        }
        if !peers.isEmpty { return .connectionProblem }
        return searchGraceElapsed ? .noColleagues : .discovering
    }

    func peer(_ id: String) -> PeerDevice? {
        peers.first { $0.id == id }
    }

    private func peersChanged(_ peers: [PeerDevice]) {
        self.peers = peers
        // Keep edge labels current if a colleague renames their Mac.
        for edge in ScreenEdge.allCases {
            guard var assignment = settings.assignment(for: edge),
                  let peer = peers.first(where: { $0.id == assignment.installationID }),
                  peer.displayName != assignment.displayName else { continue }
            assignment.displayName = peer.displayName
            settings.setAssignment(assignment, for: edge)
        }
    }

    // MARK: - Chat

    /// One row of the Messages sidebar.
    struct ConversationSummary: Identifiable, Equatable {
        let id: ConversationID
        let title: String
        let preview: String?
        let lastActivity: Date?
        let unread: Int
        /// For one-on-one conversations: the colleague if they're nearby right now.
        let peer: PeerDevice?
    }

    func displayName(forPeer peerID: String) -> String {
        peer(peerID)?.displayName ?? chat.store.contacts[peerID] ?? String(localized: "Unknown Mac")
    }

    func title(for conversation: ConversationID) -> String {
        conversation.peerID.map(displayName(forPeer:)) ?? String(localized: "Everyone nearby")
    }

    /// Files sent to or received from a colleague, oldest first, for their
    /// conversation: live transfers, then those remembered in Recent Activity.
    /// History from before 1.6 has no colleague ID; it's matched by name, and only
    /// when no other known Mac has that name.
    func conversationFiles(with peerID: String) -> [ConversationFile] {
        let live = transfers.transfers.filter { $0.peerID == peerID }
        let liveIDs = Set(live.map(\.id))
        let name = displayName(forPeer: peerID)
        let nameIsUnique = !knownNames(except: peerID).contains(name)
        var files = live.map(ConversationFile.init(transfer:))
        for entry in history.entries where !liveIDs.contains(entry.id) {
            if let owner = entry.peerID {
                guard owner == peerID else { continue }
            } else {
                guard nameIsUnique, entry.peerName == name else { continue }
            }
            files.append(ConversationFile(entry: entry))
        }
        return files.sorted { $0.date < $1.date }
    }

    private func knownNames(except peerID: String) -> Set<String> {
        var names = Set(peers.filter { $0.id != peerID }.map(\.displayName))
        for (id, name) in chat.store.contacts where id != peerID { names.insert(name) }
        return names
    }

    /// Everyone nearby first, then colleagues with recent conversations (messages
    /// or files), then colleagues nearby you haven't talked to yet.
    var conversationSummaries: [ConversationSummary] {
        let store = chat.store
        func summary(_ id: ConversationID) -> ConversationSummary {
            let last = store.lastMessage(in: id)
            var preview = last?.previewText
            var lastActivity = last?.sentAt
            if let last, id.isCommunity, !last.isOutgoing { preview = "\(last.senderName): \(last.previewText)" }
            if let last, last.isOutgoing, let text = preview { preview = String(localized: "You: \(text)") }
            if let peerID = id.peerID, let file = conversationFiles(with: peerID).last,
               file.date > (lastActivity ?? .distantPast) {
                preview = file.isOutgoing ? String(localized: "You: 📎 \(file.title)") : "📎 \(file.title)"
                lastActivity = file.date
            }
            if let peerID = id.peerID, chat.isTyping(peerID) { preview = String(localized: "typing…") }
            return ConversationSummary(id: id, title: title(for: id), preview: preview, lastActivity: lastActivity,
                                       unread: store.unreadCount(in: id), peer: id.peerID.flatMap(peer))
        }
        var peerIDs = Set(peers.map(\.id))
        for key in store.messages.keys { if let id = key.peerID { peerIDs.insert(id) } }
        for entry in history.entries { if let id = entry.peerID { peerIDs.insert(id) } }
        let direct = peerIDs.map { summary(.direct($0)) }.sorted { lhs, rhs in
            switch (lhs.lastActivity, rhs.lastActivity) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
        return [summary(.community)] + direct
    }

    var unreadMessageCount: Int { chat.store.totalUnread }

    // MARK: - Updates

    /// The publisher's key built into this copy (Config/UpdateKey.xcconfig), if any.
    static var updatePublicKey: Curve25519.Signing.PublicKey? {
        (Bundle.main.object(forInfoDictionaryKey: UpdaterService.publicKeyInfoKey) as? String)
            .flatMap(UpdatePackage.publicKey(hex:))
    }

    /// Lets the publisher choose a `.deskdropupdate` file to share with colleagues.
    func choosePackageToPublish() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: UpdatePackage.fileExtension) ?? .data]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Publish")
        panel.message = String(localized: "Choose the .deskdropupdate file made by the release script. Colleagues nearby will be offered it.")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.publishUpdate(at: url)
            }
        }
    }

    func publishUpdate(at url: URL) {
        do {
            let manifest = try updates.publish(url)
            showBanner(AppBanner(style: .info, title: String(localized: "Sharing DeskDrop \(manifest.version) with colleagues"),
                                 message: String(localized: "Everyone nearby on DeskDrop 1.7 or later is offered the update, and passes it on once they’ve installed it.")))
        } catch {
            showBanner(AppBanner(style: .error, title: String(localized: "That update can’t be published"),
                                 message: error.localizedDescription))
        }
    }

    // MARK: - Profile photo

    /// Your photo, shown to colleagues on their desk and in Messages.
    var profilePhoto: NSImage? { library.myAvatar }

    func photo(forPeer peerID: String) -> NSImage? {
        library.avatar(forPeer: peerID)
    }

    /// Lets you pick a picture for your profile photo.
    func chooseProfilePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a picture for your profile photo. Colleagues nearby will see it.")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.setProfilePhoto(from: url)
            }
        }
    }

    /// Crops the picture to a square, saves it and tells colleagues.
    func setProfilePhoto(from url: URL) {
        Task {
            do {
                let photo = try await Task.detached(priority: .userInitiated) {
                    try ImageProcessing.profilePhoto(from: try Data(contentsOf: url))
                }.value
                setProfilePhoto(data: photo)
            } catch {
                showBanner(AppBanner(style: .warning, title: String(localized: "That picture can’t be used"),
                                     message: String(localized: "Choose a JPEG, PNG, HEIC or other image file.")))
            }
        }
    }

    /// Saves an already-prepared photo (nil removes it) and tells colleagues.
    func setProfilePhoto(data: Data?) {
        library.setMyAvatar(data)
        chat.media?.announceAvatar()
    }

    // MARK: - GIFs and stickers

    func send(_ media: ChatMedia, to conversation: ConversationID) {
        chat.send(media, to: conversation)
    }

    /// Sends one of your stickers.
    func sendSticker(_ hash: String, to conversation: ConversationID) {
        guard let data = library.data(for: hash), let size = ImageProcessing.pixelSize(of: data) else { return }
        let media = ChatMedia(kind: .sticker, url: nil, hash: hash, width: size.width, height: size.height)
        if chat.send(media, to: conversation) { library.addSticker(hash: hash) }
    }

    /// Lets you pick pictures to turn into stickers.
    func chooseStickerImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Make Stickers")
        panel.message = settings.stickerRemovesBackground
            ? String(localized: "Choose pictures. DeskDrop keeps just the subject of each one.")
            : String(localized: "Choose pictures to use as stickers.")
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                self?.addStickers(from: urls)
            }
        }
    }

    /// Whether stickers are being made right now.
    private(set) var makingStickers = 0

    /// Turns pictures into stickers (in the background; Vision can take a moment).
    func addStickers(from urls: [URL]) {
        let removeBackground = settings.stickerRemovesBackground
        for url in urls.prefix(20) {
            makingStickers += 1
            Task {
                defer { makingStickers -= 1 }
                do {
                    let sticker = try await Task.detached(priority: .userInitiated) {
                        let data = try Data(contentsOf: url)
                        do {
                            return try ImageProcessing.sticker(from: data, removeBackground: removeBackground)
                        } catch where removeBackground {
                            // Nothing stood out (or Vision couldn't run): use the whole picture.
                            return try ImageProcessing.sticker(from: data, removeBackground: false)
                        }
                    }.value
                    library.addSticker(sticker)
                } catch {
                    showBanner(AppBanner(style: .warning,
                                         title: String(localized: "“\(url.lastPathComponent)” couldn’t be made into a sticker")))
                }
            }
        }
    }

    // MARK: - Drag gestures

    /// Colleagues offered around a held file: everyone DeskDrop can send to,
    /// available ones first.
    var nearbyForGesture: [PeerDevice] {
        peers
            .filter { peer in
                if case .incompatible = peer.presence { return false }
                return true
            }
            .sorted { ($0.presence == .ready ? 0 : 1) < ($1.presence == .ready ? 0 : 1) }
    }

    /// The live peer assigned to `edge`, if that Mac is nearby.
    func peer(for edge: ScreenEdge) -> PeerDevice? {
        settings.assignment(for: edge).flatMap { peer($0.installationID) }
    }

    func edges(assignedTo peerID: String) -> [ScreenEdge] {
        ScreenEdge.allCases.filter { settings.assignment(for: $0)?.installationID == peerID }
    }

    /// Assigns a colleague to an edge. A colleague belongs to one edge at a time.
    func assign(_ peerID: String, to edge: ScreenEdge) {
        guard let peer = peer(peerID) else { return }
        for other in ScreenEdge.allCases where other != edge && settings.assignment(for: other)?.installationID == peerID {
            settings.setAssignment(nil, for: other)
        }
        settings.setAssignment(EdgeAssignment(installationID: peer.id, displayName: peer.displayName), for: edge)
    }

    func clearEdge(_ edge: ScreenEdge) {
        settings.setAssignment(nil, for: edge)
    }

    /// What the card for `peerID` should say about the latest transfer, if anything.
    func activity(for peerID: String) -> CardActivity? {
        guard let transfer = transfers.transfers.first(where: {
            $0.peerID == peerID && ($0.phase.isActive || recentlyFinishedIDs.contains($0.id))
        }) else { return nil }
        let percent = Int((transfer.fractionCompleted * 100).rounded(.down))
        let outgoing = transfer.direction == .outgoing
        switch transfer.phase {
        case .preparing: return CardActivity(text: String(localized: "Preparing…"), style: .progress)
        case .offering, .awaitingAcceptance: return CardActivity(text: String(localized: "Waiting for response…"), style: .progress)
        case .awaitingDecision: return CardActivity(text: String(localized: "Wants to send a file"), style: .progress)
        case .accepted: return CardActivity(text: String(localized: "Accepted"), style: .progress)
        case .transferring:
            return CardActivity(text: outgoing ? String(localized: "Sending \(percent)%") : String(localized: "Receiving \(percent)%"),
                                style: .progress)
        case .verifying:
            return CardActivity(text: outgoing ? String(localized: "Verifying…") : String(localized: "Saving…"), style: .progress)
        case .completed:
            return CardActivity(text: outgoing ? String(localized: "Delivered") : String(localized: "Received"), style: .success)
        case .declined: return CardActivity(text: String(localized: "Declined"), style: .neutral)
        case .expired: return CardActivity(text: String(localized: "No response"), style: .neutral)
        case .cancelled: return CardActivity(text: String(localized: "Cancelled"), style: .neutral)
        case .failed: return CardActivity(text: String(localized: "Failed"), style: .warning)
        }
    }

    // MARK: - Incoming presentation

    /// Incoming transfers the floating panel should present, oldest first.
    var panelTransfers: [Transfer] {
        transfers.transfers
            .filter { transfer in
                transfer.direction == .incoming
                    && !panelDismissedIDs.contains(transfer.id)
                    && transfer.phase != .declined(.userDeclined)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The transfer currently presented: anything active first, then finished ones
    /// waiting to be acknowledged.
    var currentPanelTransfer: Transfer? {
        let candidates = panelTransfers
        return candidates.first { $0.phase.isActive } ?? candidates.first
    }

    var pendingIncoming: [Transfer] {
        transfers.transfers
            .filter { $0.direction == .incoming && $0.phase == .awaitingDecision }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func dismissFromPanel(_ id: UUID) {
        panelDismissedIDs.insert(id)
        timers.cancel(.panelDismiss(id))
    }

    private func didReceiveOffer(_ transfer: Transfer) {
        onIncomingOffer?(transfer)
    }

    private func didFinish(_ transfer: Transfer) {
        if let entry = HistoryEntry(transfer: transfer) {
            history.record(entry)
        }
        // So the conversation with them keeps their name after they leave.
        chat.store.remember(name: transfer.peerName, for: transfer.peerID)

        let id = transfer.id
        recentlyFinishedIDs.insert(id)
        timers.schedule(.linger(id), after: Self.cardLabelLinger) { [weak self] in
            self?.recentlyFinishedIDs.remove(id)
        }

        if transfer.direction == .incoming {
            timers.schedule(.panelDismiss(id), after: Self.panelAutoDismiss) { [weak self] in
                self?.dismissFromPanel(id)
            }
        } else {
            showOutcomeBanner(for: transfer)
        }
        onTransferFinished?(transfer)
    }

    private func showOutcomeBanner(for transfer: Transfer) {
        switch transfer.phase {
        case .failed:
            showBanner(AppBanner(style: .error, title: String(localized: "Couldn’t send “\(transfer.title)”"),
                                 message: transfer.detail, action: canRetry(transfer) ? .retry(transfer.id) : nil))
        case .declined:
            showBanner(AppBanner(style: .info, title: String(localized: "\(transfer.peerName) declined “\(transfer.title)”"),
                                 message: transfer.detail == TransferMessages.outcome(for: transfer) ? nil : transfer.detail))
        case .expired:
            showBanner(AppBanner(style: .warning, title: String(localized: "No response from \(transfer.peerName)"),
                                 message: String(localized: "The request expired before it was accepted."),
                                 action: canRetry(transfer) ? .retry(transfer.id) : nil))
        default:
            break
        }
    }

    func showBanner(_ banner: AppBanner) {
        self.banner = banner
        timers.schedule(.banner, after: Self.bannerAutoDismiss) { [weak self] in
            if self?.banner?.id == banner.id { self?.banner = nil }
        }
    }

    func performBannerAction(_ action: AppBanner.Action) {
        banner = nil
        switch action {
        case .retry(let id): retry(id)
        case .openNetworkSettings: NetworkPermissions.openLocalNetworkSettings()
        case .refresh: refresh()
        }
    }

    // MARK: - Transfer actions

    /// Sends dropped items to a colleague. Discovery alone isn't enough; the
    /// transfer waits briefly for the encrypted session if it is still connecting.
    func send(_ urls: [URL], to peerID: String) {
        guard !urls.isEmpty else { return }
        guard let peer = peer(peerID) else {
            showBanner(AppBanner(style: .warning, title: String(localized: "That Mac is no longer nearby")))
            return
        }
        switch peer.presence {
        case .incompatible:
            showBanner(AppBanner(style: .warning, title: String(localized: "\(peer.displayName) needs to update DeskDrop"),
                                 message: String(localized: "Both Macs must run compatible versions of DeskDrop.")))
            return
        case .unavailable:
            connection.reconnect(peer.id)
        default:
            break
        }
        transfers.send(urls, to: peer)
    }

    /// Lets keyboard and VoiceOver users send without dragging. `onSend` lets the
    /// stage play the throw for files chosen this way too.
    func chooseFilesAndSend(to peerID: String, onSend: (([URL]) -> Void)? = nil) {
        guard let peer = peer(peerID) else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Send")
        panel.message = String(localized: "Choose files or folders to send to \(peer.displayName)")
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated {
                self?.send(urls, to: peerID)
                onSend?(urls)
            }
        }
    }

    func accept(_ id: UUID) { transfers.accept(id) }
    func decline(_ id: UUID) { transfers.decline(id) }
    func cancel(_ id: UUID) { transfers.cancel(id) }
    func dismiss(_ id: UUID) { transfers.dismiss(id) }

    func retry(_ id: UUID) {
        guard let transfer = transfers.transfer(id) else { return }
        if transfers.retry(id) == nil {
            showBanner(AppBanner(style: .warning, title: String(localized: "\(transfer.peerName) isn’t nearby right now"),
                                 message: String(localized: "Try again when their Mac appears."), action: .refresh))
        }
    }

    func canRetry(_ transfer: Transfer) -> Bool {
        transfer.direction == .outgoing && transfer.phase.isTerminal && transfer.phase != .completed
            && !transfer.sourceURLs.isEmpty
    }

    func revealInFinder(_ transfer: Transfer) {
        let existing = transfer.savedURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            showBanner(AppBanner(style: .warning, title: String(localized: "The received items were moved or deleted")))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    /// Opens a single received file with its default app. Only ever user-initiated;
    /// folders and multiple items are revealed instead.
    func open(_ transfer: Transfer) {
        guard transfer.savedURLs.count == 1, let url = transfer.savedURLs.first,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else {
            revealInFinder(transfer)
            return
        }
        if !NSWorkspace.shared.open(url) { revealInFinder(transfer) }
    }

    func revealHistoryItem(_ entry: HistoryEntry) {
        guard let path = entry.savedPath, FileManager.default.fileExists(atPath: path) else {
            showBanner(AppBanner(style: .warning, title: String(localized: "“\(entry.title)” was moved or deleted")))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Receiving folder

    func chooseReceivingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination.receivingDirectory
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose where DeskDrop saves files you accept")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.setReceivingFolder(url)
            }
        }
    }

    private func setReceivingFolder(_ url: URL) {
        do {
            try destination.setCustomDirectory(url)
        } catch {
            showBanner(AppBanner(style: .error, title: String(localized: "That folder can’t be used"),
                                 message: TransferMessages.destinationFailure(error)))
        }
        receivingFolderPath = destination.receivingDirectory.path
        isUsingDefaultReceivingFolder = destination.isUsingDefaultDirectory
    }

    func resetReceivingFolder() {
        destination.resetToDefaultDirectory()
        receivingFolderPath = destination.receivingDirectory.path
        isUsingDefaultReceivingFolder = true
    }

    func revealReceivingFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([destination.receivingDirectory])
    }
}

#if DEBUG
extension DeskDropViewModel {
    /// UI tests run without networking so no permission prompt blocks them.
    func startForUITesting(injectIncomingOffer: Bool) {
        isSharingEnabled = false
        guard injectIncomingOffer else { return }
        let peer = PeerDevice(id: "00000000-0000-4000-8000-000000000002",
                              displayName: "Test Colleague", deviceKind: .laptop, presence: .ready, lastSeen: .now)
        let offer = TransferOffer(transferID: UUID(), files: [
            OfferedFile(path: "Quarterly Report.pdf", size: 2_457_600, sha256: String(repeating: "a", count: 64),
                        typeIdentifier: "com.adobe.pdf"),
        ], totalBytes: 2_457_600)
        transfers.injectOfferForUITesting(offer, from: peer)
    }

    /// UI tests only: sample conversation history (in the throwaway UI-test chat file)
    /// so incoming bubbles, unread counts and grouping can be checked without a second Mac.
    func seedChatHistoryForUITesting() {
        let colleague = "00000000-0000-4000-8000-000000000002"
        let priya = "00000000-0000-4000-8000-000000000003"
        let now = Date.now
        @discardableResult
        func add(_ text: String, from sender: String, name: String, in conversation: ConversationID,
                 minutesAgo: Double) -> UUID {
            let date = now.addingTimeInterval(-minutesAgo * 60)
            let id = UUID()
            chat.store.insert(ChatMessage(id: id, conversation: conversation, senderID: sender, senderName: name,
                                          text: text, sentAt: date, receivedAt: date, isOutgoing: sender == settings.installationID,
                                          delivery: sender == settings.installationID ? .delivered : nil))
            return id
        }
        let me = settings.installationID
        chat.store.remember(name: "Priya’s MacBook", for: priya)
        chat.store.remember(name: "Test Colleague", for: colleague)
        // Files with the colleague: one received with a real file to preview, one
        // received earlier, one you sent that they declined.
        func file(_ title: String, _ type: String, minutesAgo: Double, direction: TransferDirection,
                  outcome: HistoryEntry.Outcome, savedPath: String? = nil, detail: String? = nil) {
            let date = now.addingTimeInterval(-minutesAgo * 60)
            history.record(HistoryEntry(id: UUID(), title: title, fileCount: 1, totalBytes: 1_843_200, direction: direction,
                                        peerName: "Test Colleague", date: date.addingTimeInterval(4), outcome: outcome,
                                        detail: detail, savedPath: savedPath, peerID: colleague, startedAt: date,
                                        typeIdentifier: type, isFolder: false))
        }
        let mockup = FileManager.default.temporaryDirectory.appendingPathComponent("Mockup.png")
        if let tiff = NSApp.applicationIconImage.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: mockup)
        }
        file("Release Notes.pdf", "com.adobe.pdf", minutesAgo: 30, direction: .incoming, outcome: .completed)
        file("Mockup.png", "public.png", minutesAgo: 6, direction: .incoming, outcome: .completed, savedPath: mockup.path)
        file("Build 1.6.zip", "public.zip-archive", minutesAgo: 5, direction: .outgoing, outcome: .declined,
             detail: "Test Colleague declined.")
        add("Morning everyone! Coffee machine on 3 is fixed ☕️", from: priya, name: "Priya’s MacBook", in: .community, minutesAgo: 1500)
        let standup = add("Standup moved to 10:30 today", from: colleague, name: "Test Colleague", in: .community, minutesAgo: 42)
        add("Thanks for the heads up", from: me, name: settings.displayName, in: .community, minutesAgo: 40)
        add("Can someone send me the Q3 deck?", from: priya, name: "Priya’s MacBook", in: .community, minutesAgo: 6)
        add("I’ll drop it to you now", from: colleague, name: "Test Colleague", in: .community, minutesAgo: 5)
        chat.store.setReaction("👍", by: me, name: settings.displayName, on: standup)
        chat.store.setReaction("👍", by: priya, name: "Priya’s MacBook", on: standup)
        add("Hey, do you have the latest build?", from: colleague, name: "Test Colleague", in: .direct(colleague), minutesAgo: 3)
        add("Also the release notes if you have them", from: colleague, name: "Test Colleague", in: .direct(colleague), minutesAgo: 2.9)
        let reply = add("Sending both over now", from: me, name: settings.displayName, in: .direct(colleague), minutesAgo: 2.5)
        chat.store.setReaction("❤️", by: colleague, name: "Test Colleague", on: reply)
        let thanks = add("🙌", from: me, name: settings.displayName, in: .direct(colleague), minutesAgo: 2.4)
        chat.store.markReadByRecipient(in: .direct(colleague), upTo: thanks, at: now.addingTimeInterval(-120))
        seedMediaForUITesting(colleague: colleague, priya: priya, now: now)
    }

    /// UI tests only: profile photos, Markdown, a GIF and a sticker, all made on
    /// this Mac so nothing needs the network.
    private func seedMediaForUITesting(colleague: String, priya: String, now: Date) {
        let me = settings.installationID
        func picture(_ colors: [NSColor], symbol: String, tint: NSColor = .white) -> Data? {
            let image = NSImage(size: NSSize(width: 300, height: 300), flipped: false) { rect in
                NSGradient(colors: colors)?.draw(in: rect, angle: -60)
                let config = NSImage.SymbolConfiguration(pointSize: 150, weight: .medium)
                    .applying(.init(paletteColors: [tint]))
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config)?.draw(in: rect.insetBy(dx: 60, dy: 60))
                return true
            }
            guard let tiff = image.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        if let photo = picture([.systemOrange, .systemPink], symbol: "person.fill"),
           let avatar = try? ImageProcessing.profilePhoto(from: photo), let hash = library.store(avatar) {
            library.setAvatar(hash, forPeer: colleague)
        }
        if let photo = picture([.systemTeal, .systemBlue], symbol: "face.smiling"),
           let avatar = try? ImageProcessing.profilePhoto(from: photo) {
            library.setMyAvatar(avatar)
        }
        if let photo = picture([.systemGreen, .systemMint], symbol: "leaf.fill"),
           let avatar = try? ImageProcessing.profilePhoto(from: photo), let hash = library.store(avatar) {
            library.setAvatar(hash, forPeer: priya)
        }

        func add(_ text: String, from sender: String, name: String, minutesAgo: Double, media: ChatMedia? = nil) {
            let date = now.addingTimeInterval(-minutesAgo * 60)
            let mine = sender == me
            chat.store.insert(ChatMessage(id: UUID(), conversation: .direct(colleague), senderID: sender, senderName: name,
                                          text: text, sentAt: date, receivedAt: date, isOutgoing: mine,
                                          delivery: mine ? .delivered : nil, media: media))
        }
        add("**Build 1.7** is _almost_ ready:\n- GIFs from GIPHY\n- your own stickers\n- `Markdown` in messages\n> ship it on Friday?",
            from: colleague, name: "Test Colleague", minutesAgo: 2.0)
        // An animated GIF, drawn here, standing in for one from GIPHY.
        let gifURL = URL(string: "https://media.giphy.com/media/deskdropUITest/giphy.gif")!
        if let gif = Self.sampleGIF() {
            remoteImages.seedForUITesting(gif, for: gifURL)
            add("GIF: Celebrate https://giphy.com/gifs/deskdropUITest", from: colleague, name: "Test Colleague", minutesAgo: 1.9,
                media: ChatMedia(kind: .gif, url: gifURL, hash: nil, width: 240, height: 160, title: "Celebrate",
                                 giphyID: "deskdropUITest"))
        }
        if let art = picture([.clear, .clear], symbol: "hands.clap.fill", tint: .systemOrange),
           let sticker = try? ImageProcessing.sticker(from: art, removeBackground: false),
           let hash = library.addSticker(sticker), let size = ImageProcessing.pixelSize(of: sticker) {
            add("[Sticker]", from: me, name: settings.displayName, minutesAgo: 1.6,
                media: ChatMedia(kind: .sticker, url: nil, hash: hash, width: size.width, height: size.height))
        }
        add("Yes! Notes are on [the wiki](https://example.com/wiki). Run:\n```\nscripts/build-release.sh\n```",
            from: me, name: settings.displayName, minutesAgo: 1.3)
        // A link preview, as the colleague's Mac made it.
        if let picture = picture([.systemIndigo, .systemPurple], symbol: "macbook"),
           let image = try? ImageProcessing.linkImage(from: picture), let hash = library.store(image),
           let size = ImageProcessing.pixelSize(of: image), let url = URL(string: "https://www.apple.com/macbook-air/") {
            let date = now.addingTimeInterval(-60)
            chat.store.insert(ChatMessage(id: UUID(), conversation: .direct(colleague), senderID: colleague,
                                          senderName: "Test Colleague", text: "New laptops for the team? \(url.absoluteString)",
                                          sentAt: date, receivedAt: date, isOutgoing: false, delivery: nil,
                                          link: LinkPreview(url: url, title: "MacBook Air 13- and 15-inch with M5",
                                                            imageHash: hash, imageWidth: size.width, imageHeight: size.height)))
        }
    }

    /// A small two-colour animated GIF.
    private static func sampleGIF() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 8, nil) else {
            return nil
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<8 {
            guard let context = CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            let hue = CGFloat(frame) / 8
            context.setFillColor(NSColor(hue: hue, saturation: 0.6, brightness: 0.95, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            context.setFillColor(NSColor.white.cgColor)
            let x = 30 + CGFloat(frame) * 22
            context.fillEllipse(in: CGRect(x: x, y: 50, width: 60, height: 60))
            guard let image = context.makeImage() else { return nil }
            CGImageDestinationAddImage(destination, image,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]] as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// UI tests only: a long one-on-one history, then a new message from the
    /// colleague every second, to exercise scrolling.
    func simulateLiveMessagesForUITesting() {
        let colleague = "00000000-0000-4000-8000-000000000002"
        let start = Date.now.addingTimeInterval(-600)
        for index in 0..<40 {
            let date = start.addingTimeInterval(Double(index) * 5)
            let mine = index % 3 == 0
            chat.store.insert(ChatMessage(id: UUID(), conversation: .direct(colleague),
                                          senderID: mine ? settings.installationID : colleague,
                                          senderName: mine ? settings.displayName : "Test Colleague",
                                          text: "Earlier message \(index + 1)", sentAt: date, receivedAt: date,
                                          isOutgoing: mine, delivery: mine ? .delivered : nil))
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            for index in 1...6 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.chat.store.insert(ChatMessage(id: UUID(), conversation: .direct(colleague), senderID: colleague,
                                                   senderName: "Test Colleague", text: "Live message \(index)",
                                                   sentAt: .now, receivedAt: .now, isOutgoing: false, delivery: nil))
            }
        }
    }

    /// UI tests only: lists a colleague with no network behind it so drag gestures
    /// have a target. Sending to it fails honestly once the connection wait expires.
    func injectPeerForUITesting(assignToLeftEdge: Bool) {
        let peer = PeerDevice(id: "00000000-0000-4000-8000-000000000002", displayName: "Test Colleague",
                              deviceKind: .desktop, presence: .ready, lastSeen: .now)
        peers = [peer]
        if assignToLeftEdge { assign(peer.id, to: .left) }
    }
}
#endif
