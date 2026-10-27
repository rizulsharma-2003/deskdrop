import Foundation
@preconcurrency import MultipeerConnectivity

/// Who this Mac is on the network.
struct LocalIdentity: Equatable, Sendable {
    let installationID: String
    var displayName: String
    let deviceKind: DeviceKind
    let appVersion: String

    var hello: Hello {
        Hello(installationID: installationID, displayName: displayName, deviceKind: deviceKind, appVersion: appVersion,
              capabilities: [Hello.chatCapability, Hello.typingCapability, Hello.avatarCapability, Hello.mediaCapability,
                             Hello.updateCapability])
    }
}

enum DiscoveryFailure: Equatable, Sendable {
    /// Local-network access was refused in Privacy & Security.
    case permissionDenied
    /// The app bundle is missing its Bonjour declarations.
    case misconfigured
    /// Advertising or browsing failed for another reason.
    case serviceError
}

enum DiscoveryState: Equatable, Sendable {
    case stopped
    case running(since: Date)
    case failed(DiscoveryFailure)
}

/// Advertises this Mac, browses for other DeskDrop installations, and maintains one
/// encrypted `MCSession` per peer.
///
/// - One session per peer keeps failures isolated and avoids the 8-peer session limit.
/// - To avoid both Macs inviting each other, the one with the smaller installation
///   ID invites; the other only invites as a fallback if nothing arrives.
/// - A peer becomes `ready` only after both sides exchange a `hello` message.
/// - Sessions require encryption (`.required`); there is no downgrade path.
///
/// Multipeer Connectivity calls its delegates on private queues. Every callback is
/// forwarded to the main actor in order via the main dispatch queue.
@MainActor
final class PeerConnectionService: NSObject, PeerTransport, ChatTransport, UpdateTransport {
    /// Bonjour service type: `_deskdrop._tcp` / `_deskdrop._udp` (see Info.plist).
    nonisolated static let serviceType = "deskdrop"

    weak var transferDelegate: (any PeerTransportDelegate)?
    weak var chatDelegate: (any ChatTransportDelegate)?
    weak var updateDelegate: (any UpdateTransportDelegate)?
    var onPeersChanged: (([PeerDevice]) -> Void)?
    var onStateChanged: ((DiscoveryState) -> Void)?

    private(set) var state: DiscoveryState = .stopped {
        didSet { if state != oldValue { onStateChanged?(state) } }
    }
    private(set) var peers: [PeerDevice] = []

    private let defaults: UserDefaults
    nonisolated let inboxDirectory: URL
    private var identity: LocalIdentity?
    private var localPeerID: MCPeerID?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var links: [String: PeerLink] = [:]
    private let timers = ScheduledTasks<TimerKey>()
    private var discoveryRestartAttempts = 0

    private static let inviteTimeout: TimeInterval = 20
    private static let connectTimeout: Duration = .seconds(25)
    private static let handshakeTimeout: Duration = .seconds(10)
    private static let fallbackInviteDelay: Duration = .seconds(6)
    private static let removalGrace: Duration = .seconds(4)
    private static let maxReconnectAttempts = 5

    private enum TimerKey: Hashable {
        case connectTimeout(String)
        case handshake(String)
        case fallbackInvite(String)
        case reconnect(String)
        case removal(String)
        case restartDiscovery
    }

    private enum SessionState {
        case idle
        case connecting
        case connected
    }

    /// Everything known about one remote installation.
    private final class PeerLink {
        let id: String
        var mcPeerID: MCPeerID
        var displayName: String
        var deviceKind: DeviceKind
        var lastSeen = Date.now
        var isDiscovered = false
        var session: MCSession?
        var sessionState = SessionState.idle
        var handshakeComplete = false
        var capabilities: [String] = []
        var incompatibleVersion: Int?
        var reconnectAttempts = 0
        var isUnavailable = false

        init(id: String, mcPeerID: MCPeerID, displayName: String, deviceKind: DeviceKind) {
            self.id = id
            self.mcPeerID = mcPeerID
            self.displayName = displayName
            self.deviceKind = deviceKind
        }

        var presence: PeerPresence {
            if let version = incompatibleVersion { return .incompatible(remoteVersion: version) }
            if handshakeComplete { return .ready }
            switch sessionState {
            case .connected: return .connected
            case .connecting: return .connecting
            case .idle: return isUnavailable ? .unavailable : .discovered
            }
        }
    }

    nonisolated static var defaultInboxDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DeskDrop", isDirectory: true)
            .appendingPathComponent("Inbox", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard, inboxDirectory: URL = PeerConnectionService.defaultInboxDirectory) {
        self.defaults = defaults
        self.inboxDirectory = inboxDirectory
        super.init()
    }

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Lifecycle

    /// Starts advertising and browsing. Changing the identity's display name
    /// recreates the peer ID, which disconnects existing sessions.
    func start(identity: LocalIdentity) {
        if self.identity != identity || localPeerID == nil {
            stop()
            self.identity = identity
            localPeerID = makePeerID(displayName: identity.displayName)
        }
        guard advertiser == nil else { return }
        startDiscovery()
    }

    func stop() {
        timers.cancelAll()
        stopDiscovery()
        for link in links.values {
            tearDownSession(link, notify: link.handshakeComplete)
        }
        links.removeAll()
        state = .stopped
        publishPeers()
    }

    /// Restarts advertising and browsing without dropping connected peers. Used for
    /// the Refresh action and after network changes.
    func restartDiscovery() {
        guard identity != nil else { return }
        if case .stopped = state { return }
        timers.cancel(.restartDiscovery)
        stopDiscovery()
        for link in links.values where link.session == nil {
            link.isDiscovered = false
            link.isUnavailable = false
            link.reconnectAttempts = 0
            scheduleRemoval(link)
        }
        startDiscovery()
        publishPeers()
    }

    /// User-initiated retry for a peer that stopped responding.
    func reconnect(_ peerID: String) {
        guard let link = links[peerID], link.session == nil, link.incompatibleVersion == nil else { return }
        link.isUnavailable = false
        link.reconnectAttempts = 0
        timers.cancel(.reconnect(peerID))
        invite(link)
    }

    private func startDiscovery() {
        guard let identity, let localPeerID else { return }
        let info: [String: String] = [
            "id": identity.installationID,
            "n": identity.displayName,
            "k": identity.deviceKind.rawValue,
            "v": String(ProtocolCodec.currentVersion),
        ]
        let advertiser = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: info, serviceType: Self.serviceType)
        advertiser.delegate = self
        let browser = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        browser.delegate = self
        self.advertiser = advertiser
        self.browser = browser
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        state = .running(since: .now)
        Log.network.info("Discovery started")
    }

    private func stopDiscovery() {
        advertiser?.stopAdvertisingPeer()
        advertiser?.delegate = nil
        advertiser = nil
        browser?.stopBrowsingForPeers()
        browser?.delegate = nil
        browser = nil
    }

    /// Reuses the archived peer ID while the display name is unchanged, as Apple
    /// recommends, so other Macs do not see a "new" device on every launch.
    private func makePeerID(displayName: String) -> MCPeerID {
        let name = Self.peerIDName(for: displayName)
        if defaults.string(forKey: SettingsKey.archivedPeerIDName) == name,
           let data = defaults.data(forKey: SettingsKey.archivedPeerID),
           let peerID = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
            return peerID
        }
        let peerID = MCPeerID(displayName: name)
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: peerID, requiringSecureCoding: true) {
            defaults.set(data, forKey: SettingsKey.archivedPeerID)
            defaults.set(name, forKey: SettingsKey.archivedPeerIDName)
        }
        return peerID
    }

    /// MCPeerID display names are limited to 63 UTF-8 bytes.
    static func peerIDName(for displayName: String) -> String {
        var name = displayName
        while name.utf8.count > 63 { name.removeLast() }
        return name.isEmpty ? "Mac" : name
    }

    // MARK: - Connections

    private func connectIfNeeded(_ link: PeerLink) {
        guard isRunning, let identity, link.session == nil, link.isDiscovered,
              link.incompatibleVersion == nil, !link.isUnavailable else { return }
        if identity.installationID < link.id {
            invite(link)
        } else if !timers.isScheduled(.fallbackInvite(link.id)) {
            let id = link.id
            timers.schedule(.fallbackInvite(id), after: Self.fallbackInviteDelay) { [weak self] in
                guard let self, let link = self.links[id], link.session == nil, link.isDiscovered else { return }
                Log.connection.info("No invitation arrived; inviting as fallback")
                self.invite(link)
            }
        }
    }

    private func invite(_ link: PeerLink) {
        guard link.session == nil, let browser, let identity,
              let context = try? ProtocolCodec.encode(.hello(identity.hello)),
              let session = makeSession() else { return }
        timers.cancel(.fallbackInvite(link.id))
        link.session = session
        link.sessionState = .connecting
        browser.invitePeer(link.mcPeerID, to: session, withContext: context, timeout: Self.inviteTimeout)
        scheduleConnectTimeout(link)
        publishPeers()
        Log.connection.info("Invited peer \(link.id.prefix(8), privacy: .public)")
    }

    private func makeSession() -> MCSession? {
        guard let localPeerID else { return nil }
        let session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    private func scheduleConnectTimeout(_ link: PeerLink) {
        let id = link.id
        timers.schedule(.connectTimeout(id), after: Self.connectTimeout) { [weak self] in
            guard let self, let link = self.links[id], link.sessionState != .connected else { return }
            Log.connection.notice("Connection to \(id.prefix(8), privacy: .public) timed out")
            self.tearDownSession(link, notify: false)
            self.scheduleReconnect(link)
            self.publishPeers()
        }
    }

    private func tearDownSession(_ link: PeerLink, notify: Bool) {
        let session = link.session
        link.session = nil
        link.sessionState = .idle
        link.handshakeComplete = false
        timers.cancel(.connectTimeout(link.id))
        timers.cancel(.handshake(link.id))
        session?.delegate = nil
        session?.disconnect()
        if notify { transferDelegate?.transportPeerDisconnected(link.id) }
    }

    /// Exponential backoff with jitter, capped, so a missing peer never causes a
    /// reconnect storm. After several failures the peer is shown as unavailable.
    private func scheduleReconnect(_ link: PeerLink) {
        guard isRunning, link.isDiscovered, link.incompatibleVersion == nil else {
            scheduleRemoval(link)
            return
        }
        link.reconnectAttempts += 1
        guard link.reconnectAttempts <= Self.maxReconnectAttempts else {
            link.isUnavailable = true
            Log.connection.notice("Peer \(link.id.prefix(8), privacy: .public) marked unavailable")
            return
        }
        let seconds = min(30, pow(2, Double(link.reconnectAttempts))) + Double.random(in: 0...1)
        let id = link.id
        timers.schedule(.reconnect(id), after: .milliseconds(Int(seconds * 1000))) { [weak self] in
            guard let self, let link = self.links[id] else { return }
            self.connectIfNeeded(link)
        }
    }

    private func scheduleRemoval(_ link: PeerLink) {
        let id = link.id
        timers.schedule(.removal(id), after: Self.removalGrace) { [weak self] in
            guard let self, let link = self.links[id], !link.isDiscovered, link.session == nil else { return }
            self.timers.cancel(.reconnect(id))
            self.timers.cancel(.fallbackInvite(id))
            self.links[id] = nil
            self.publishPeers()
        }
    }

    private func link(for session: MCSession) -> PeerLink? {
        links.values.first { $0.session === session }
    }

    private func publishPeers() {
        let devices = links.values
            .map { link in
                PeerDevice(id: link.id, displayName: link.displayName, deviceKind: link.deviceKind,
                           presence: link.presence, lastSeen: link.lastSeen,
                           supportsChat: link.capabilities.contains(Hello.chatCapability),
                           supportsTyping: link.capabilities.contains(Hello.typingCapability),
                           supportsAvatar: link.capabilities.contains(Hello.avatarCapability),
                           supportsMedia: link.capabilities.contains(Hello.mediaCapability),
                           supportsUpdates: link.capabilities.contains(Hello.updateCapability))
            }
            .sorted { lhs, rhs in
                let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
        guard devices != peers else { return }
        peers = devices
        onPeersChanged?(devices)
    }

    // MARK: - Delegate handlers (main actor)

    private func handleFound(_ peerID: MCPeerID, info: [String: String]?, from browser: MCNearbyServiceBrowser) {
        guard browser === self.browser, let identity else { return }
        // Discovery info is untrusted input.
        guard let info, let id = info["id"], UUID(uuidString: id) != nil, id != identity.installationID else { return }
        let name = info["n"].flatMap(NameSanitizer.sanitizeDisplayName)
            ?? NameSanitizer.sanitizeDisplayName(peerID.displayName)
            ?? "Mac"
        let kind = info["k"].flatMap(DeviceKind.init(rawValue:)) ?? .desktop
        let version = info["v"].flatMap { Int($0) } ?? 0

        let link: PeerLink
        if let existing = links[id] {
            link = existing
        } else {
            link = PeerLink(id: id, mcPeerID: peerID, displayName: name, deviceKind: kind)
            links[id] = link
        }
        timers.cancel(.removal(id))
        discoveryRestartAttempts = 0
        link.isDiscovered = true
        link.lastSeen = .now
        if link.session != nil, link.mcPeerID != peerID {
            // The same installation is advertising a new peer ID: it restarted, so the
            // old session is dead even if Multipeer Connectivity hasn't noticed yet.
            Log.connection.info("Peer \(id.prefix(8), privacy: .public) restarted; replacing its session")
            tearDownSession(link, notify: link.handshakeComplete)
            link.reconnectAttempts = 0
        }
        if link.session == nil {
            link.mcPeerID = peerID
            link.displayName = name
            link.deviceKind = kind
        }
        link.incompatibleVersion = ProtocolCodec.supportedVersions.contains(version) ? nil : version
        publishPeers()
        connectIfNeeded(link)
    }

    private func handleLost(_ peerID: MCPeerID, from browser: MCNearbyServiceBrowser) {
        guard browser === self.browser, let link = links.values.first(where: { $0.mcPeerID == peerID }) else { return }
        link.isDiscovered = false
        // A connected peer stays until its session ends; discovery can flicker.
        if link.session == nil { scheduleRemoval(link) }
        publishPeers()
    }

    private func handleInvitation(from peerID: MCPeerID, context: Data?, advertiser: MCNearbyServiceAdvertiser,
                                  respond: @escaping (Bool, MCSession?) -> Void) {
        guard advertiser === self.advertiser, let identity, let context,
              case .hello(let hello)? = try? ProtocolCodec.decode(context),
              UUID(uuidString: hello.installationID) != nil, hello.installationID != identity.installationID else {
            respond(false, nil)
            return
        }
        let id = hello.installationID
        let link: PeerLink
        if let existing = links[id] {
            link = existing
        } else {
            link = PeerLink(id: id, mcPeerID: peerID,
                            displayName: NameSanitizer.sanitizeDisplayName(hello.displayName) ?? "Mac",
                            deviceKind: hello.deviceKind)
            links[id] = link
        }

        if link.session != nil {
            if link.sessionState == .connected {
                respond(false, nil)
                return
            }
            // Both Macs invited at once. The smaller installation ID is the designated
            // inviter, so keep its session and drop the other.
            guard id < identity.installationID else {
                respond(false, nil)
                return
            }
            tearDownSession(link, notify: false)
        }

        guard let session = makeSession() else {
            respond(false, nil)
            return
        }
        timers.cancel(.fallbackInvite(id))
        timers.cancel(.reconnect(id))
        timers.cancel(.removal(id))
        link.mcPeerID = peerID
        link.displayName = NameSanitizer.sanitizeDisplayName(hello.displayName) ?? link.displayName
        link.deviceKind = hello.deviceKind
        link.lastSeen = .now
        link.isUnavailable = false
        link.incompatibleVersion = nil
        link.session = session
        link.sessionState = .connecting
        respond(true, session)
        scheduleConnectTimeout(link)
        publishPeers()
        Log.connection.info("Accepted invitation from \(id.prefix(8), privacy: .public)")
    }

    private func handleSessionState(_ state: MCSessionState, session: MCSession, peerID: MCPeerID) {
        guard let link = link(for: session) else { return }
        switch state {
        case .connecting:
            link.sessionState = .connecting
        case .connected:
            guard link.sessionState != .connected else { return }
            timers.cancel(.connectTimeout(link.id))
            link.sessionState = .connected
            link.mcPeerID = peerID
            sendHello(to: link)
            let id = link.id
            timers.schedule(.handshake(id), after: Self.handshakeTimeout) { [weak self] in
                guard let self, let link = self.links[id], !link.handshakeComplete else { return }
                Log.connection.notice("Handshake with \(id.prefix(8), privacy: .public) timed out")
                self.tearDownSession(link, notify: false)
                self.scheduleReconnect(link)
                self.publishPeers()
            }
        case .notConnected:
            let wasReady = link.handshakeComplete
            tearDownSession(link, notify: wasReady)
            Log.connection.info("Session with \(link.id.prefix(8), privacy: .public) ended")
            scheduleReconnect(link)
        @unknown default:
            break
        }
        publishPeers()
    }

    private func sendHello(to link: PeerLink) {
        guard let identity, let session = link.session,
              let data = try? ProtocolCodec.encode(.hello(identity.hello)) else { return }
        do {
            try session.send(data, toPeers: [link.mcPeerID], with: .reliable)
        } catch {
            Log.connection.error("Could not send hello: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleData(_ data: Data, session: MCSession) {
        guard let link = link(for: session), link.sessionState == .connected else { return }
        let message: ProtocolMessage
        do {
            message = try ProtocolCodec.decode(data)
        } catch ProtocolError.unsupportedVersion(let version) {
            Log.connection.notice("Peer uses unsupported protocol version \(version)")
            link.incompatibleVersion = version
            tearDownSession(link, notify: link.handshakeComplete)
            publishPeers()
            return
        } catch {
            Log.connection.error("Dropped malformed message: \(String(describing: error), privacy: .public)")
            return
        }

        if case .hello(let hello) = message {
            handleHello(hello, link: link)
            return
        }
        guard link.handshakeComplete else {
            Log.connection.error("Dropped message received before handshake")
            return
        }
        if message.isUpdate {
            updateDelegate?.updateTransport(didReceive: message, from: link.id)
        } else if message.isChat {
            chatDelegate?.chatTransport(didReceive: message, from: link.id)
        } else {
            transferDelegate?.transport(didReceive: message, from: link.id)
        }
    }

    private func handleHello(_ hello: Hello, link: PeerLink) {
        // The hello must come from the installation this session was set up for.
        guard hello.installationID == link.id else {
            Log.connection.error("Handshake identity mismatch; disconnecting")
            tearDownSession(link, notify: false)
            publishPeers()
            return
        }
        link.displayName = NameSanitizer.sanitizeDisplayName(hello.displayName) ?? link.displayName
        link.deviceKind = hello.deviceKind
        link.capabilities = Array((hello.capabilities ?? []).prefix(16))
        link.lastSeen = .now
        let wasComplete = link.handshakeComplete
        link.handshakeComplete = true
        link.reconnectAttempts = 0
        link.isUnavailable = false
        timers.cancel(.handshake(link.id))
        publishPeers()
        if !wasComplete {
            Log.connection.info("Peer \(link.id.prefix(8), privacy: .public) ready")
            transferDelegate?.transportPeerBecameReady(link.id)
            chatDelegate?.chatTransportPeerBecameReady(link.id)
            updateDelegate?.updateTransportPeerBecameReady(link.id)
        }
    }

    private func handleDiscoveryError(_ error: Error) {
        Log.network.error("Discovery failed: \(error.localizedDescription, privacy: .public)")
        stopDiscovery()
        let failure: DiscoveryFailure
        if NetworkPermissions.isPolicyDenied(error) {
            failure = .permissionDenied
        } else if NetworkPermissions.isMisconfigured(error) {
            failure = .misconfigured
        } else {
            failure = .serviceError
        }
        state = .failed(failure)
        discoveryRestartAttempts += 1
        let delay = min(60, 5 * discoveryRestartAttempts)
        timers.schedule(.restartDiscovery, after: .seconds(delay)) { [weak self] in
            self?.startDiscovery()
        }
    }

    // MARK: - PeerTransport

    func peer(for id: String) -> PeerDevice? {
        peers.first { $0.id == id }
    }

    var readyPeers: [PeerDevice] {
        peers.filter { $0.presence == .ready }
    }

    func send(_ message: ProtocolMessage, to peerID: String) throws {
        guard let link = links[peerID], let session = link.session, link.sessionState == .connected else {
            throw TransportError.peerNotConnected
        }
        let data = try ProtocolCodec.encode(message)
        try session.send(data, toPeers: [link.mcPeerID], with: .reliable)
    }

    func sendResource(at url: URL, named name: String, to peerID: String,
                      completion: @escaping @MainActor @Sendable (Error?) -> Void) throws -> Progress {
        guard let link = links[peerID], link.handshakeComplete, let session = link.session else {
            throw TransportError.peerNotConnected
        }
        // `@Sendable` keeps this closure nonisolated: Multipeer Connectivity calls it on
        // its own queue, and an inferred main-actor closure would trap there.
        let progress = session.sendResource(at: url, withName: name, toPeer: link.mcPeerID) { @Sendable error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(error) }
            }
        }
        guard let progress else { throw TransportError.resourceRejected }
        return progress
    }

    // MARK: - Hopping to the main actor

    /// Runs `work` on the main actor in the order callbacks arrived.
    nonisolated private func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { work() }
        }
    }

    /// Multipeer Connectivity deletes a received resource's file when the delegate
    /// method returns, so it is moved somewhere DeskDrop owns first.
    nonisolated private static func claimReceivedFile(_ url: URL, inbox: URL) -> URL? {
        let fileManager = FileManager()
        do {
            try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
            let destination = inbox.appendingPathComponent(UUID().uuidString, isDirectory: false)
            try fileManager.moveItem(at: url, to: destination)
            return destination
        } catch {
            Log.files.error("Could not claim received file: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerConnectionService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Boxed separately: destructuring a tuple that holds the handler crashes the Swift 6.4 compiler.
        let advertiserBox = UncheckedSendable(advertiser)
        let peerBox = UncheckedSendable(peerID)
        let handlerBox = UncheckedSendable(invitationHandler)
        onMain {
            self.handleInvitation(from: peerBox.value, context: context, advertiser: advertiserBox.value,
                                  respond: handlerBox.value)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        let box = UncheckedSendable(advertiser)
        onMain {
            guard box.value === self.advertiser else { return }
            self.handleDiscoveryError(error)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerConnectionService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        let box = UncheckedSendable((browser, peerID))
        onMain {
            let (browser, peerID) = box.value
            self.handleFound(peerID, info: info, from: browser)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let box = UncheckedSendable((browser, peerID))
        onMain {
            let (browser, peerID) = box.value
            self.handleLost(peerID, from: browser)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        let box = UncheckedSendable(browser)
        onMain {
            guard box.value === self.browser else { return }
            self.handleDiscoveryError(error)
        }
    }
}

// MARK: - MCSessionDelegate

extension PeerConnectionService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let box = UncheckedSendable((session, peerID, state))
        onMain {
            let (session, peerID, state) = box.value
            self.handleSessionState(state, session: session, peerID: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Oversized messages are dropped before any decoding work.
        guard data.count <= ProtocolLimits.maxMessageBytes else { return }
        let box = UncheckedSendable(session)
        onMain {
            self.handleData(data, session: box.value)
        }
    }

    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {
        let box = UncheckedSendable((session, progress))
        onMain {
            let (session, progress) = box.value
            guard let link = self.link(for: session), link.handshakeComplete else {
                progress.cancel()
                return
            }
            if UpdateResource.isUpdate(resourceName) {
                // Updates arrive only when this Mac asked for them.
                guard self.updateDelegate?.updateTransport(didStartReceivingResourceNamed: resourceName, from: link.id,
                                                           progress: progress) == true else {
                    progress.cancel()
                    return
                }
                return
            }
            guard let delegate = self.transferDelegate else {
                progress.cancel()
                return
            }
            delegate.transport(didStartReceivingResourceNamed: resourceName, from: link.id, progress: progress)
        }
    }

    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        var claimed: URL?
        if let localURL, error == nil {
            claimed = Self.claimReceivedFile(localURL, inbox: inboxDirectory)
        }
        let box = UncheckedSendable(session)
        let receivedURL = claimed
        onMain {
            let failure: Error? = error ?? (receivedURL == nil ? TransportError.resourceRejected : nil)
            if UpdateResource.isUpdate(resourceName), let link = self.link(for: box.value), let delegate = self.updateDelegate {
                delegate.updateTransport(didFinishReceivingResourceNamed: resourceName, from: link.id, at: receivedURL,
                                         error: failure)
                return
            }
            guard !UpdateResource.isUpdate(resourceName), let link = self.link(for: box.value),
                  let delegate = self.transferDelegate else {
                if let receivedURL { try? FileManager.default.removeItem(at: receivedURL) }
                return
            }
            delegate.transport(didFinishReceivingResourceNamed: resourceName, from: link.id, at: receivedURL, error: failure)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                             fromPeer peerID: MCPeerID) {
        // DeskDrop never uses streams; refuse them.
        stream.close()
    }

    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID,
                             certificateHandler: @escaping (Bool) -> Void) {
        // No identity certificates are used; the session is still encrypted. See docs/SECURITY.md.
        certificateHandler(true)
    }
}
