import CryptoKit
import Foundation
import Observation

/// The part of the network updates need. `PeerConnectionService` provides it;
/// tests use the in-process loopback.
@MainActor
protocol UpdateTransport: AnyObject {
    var updateDelegate: (any UpdateTransportDelegate)? { get set }
    var readyPeers: [PeerDevice] { get }
    func peer(for id: String) -> PeerDevice?
    func send(_ message: ProtocolMessage, to peerID: String) throws
    func sendResource(at url: URL, named name: String, to peerID: String,
                      completion: @escaping @MainActor @Sendable (Error?) -> Void) throws -> Progress
}

@MainActor
protocol UpdateTransportDelegate: AnyObject {
    func updateTransport(didReceive message: ProtocolMessage, from peerID: String)
    func updateTransportPeerBecameReady(_ peerID: String)
    /// Return false to refuse (cancel) the resource.
    func updateTransport(didStartReceivingResourceNamed name: String, from peerID: String, progress: Progress) -> Bool
    func updateTransport(didFinishReceivingResourceNamed name: String, from peerID: String, at url: URL?, error: Error?)
}

/// Update packages travel as resources named "update/<version>".
enum UpdateResource {
    static let prefix = "update/"

    static func isUpdate(_ name: String) -> Bool { name.hasPrefix(prefix) }

    static func name(for version: String) -> String { prefix + version }
}

/// Puts a verified update in place. The app uses the installer helper (XPC);
/// tests use a stand-in.
@MainActor
protocol UpdateInstalling {
    func install(packageAt url: URL) async throws
}

/// DeskDrop updates, from GitHub Releases and from Mac to Mac.
///
/// - **Publishing:** `scripts/publish-release.sh` attaches the signed
///   `.deskdropupdate` to a GitHub release, which every copy checks for at launch
///   and every few hours. The publisher can also open the file in Settings › About
///   to offer it straight to colleagues nearby.
/// - **Automatic updates:** a newer version is downloaded in the background and,
///   when automatic updates are on, installed while DeskDrop is idle (not in front,
///   nothing transferring).
/// - **Finding:** a colleague's offer is accepted only if it's signed with the key
///   built into this copy of DeskDrop and is newer than what's installed.
/// - **Updating:** the package is downloaded from a colleague who has it, checked
///   in full, and handed to the installer helper, which checks it again, swaps
///   the app and DeskDrop relaunches. The package is kept so this Mac passes it on.
@MainActor
@Observable
final class UpdateService {
    /// A newer DeskDrop that a colleague (or this Mac) has.
    struct Available: Equatable {
        let manifest: UpdateManifest
        let offer: UpdateOffer
        /// Colleagues who offered it, first first.
        var sources: [String]
        /// The verified package is already on this Mac.
        var isDownloaded: Bool
    }

    enum Phase: Equatable {
        case idle
        case downloading(fraction: Double)
        case installing
        case failed(String)
    }

    private(set) var available: Available?
    private(set) var phase: Phase = .idle
    /// Checking the update feed (GitHub) right now.
    private(set) var isChecking = false
    private(set) var lastChecked: Date?
    /// Why the last check didn't work, if it didn't.
    private(set) var checkFailure: String?
    /// The newest verified package this Mac has, which it offers to colleagues.
    private(set) var shared: UpdateManifest?

    let currentVersion: String
    /// Updates need the publisher's public key, built in from Config/UpdateKey.xcconfig.
    var isEnabled: Bool { publicKey != nil }

    /// A newer version was found (once per version), with who offered it.
    @ObservationIgnored var onUpdateFound: ((UpdateManifest, String) -> Void)?
    /// The new version is installed; relaunch into it. True when it was installed
    /// automatically (so relaunch quietly), false when someone clicked Update.
    @ObservationIgnored var onInstalled: ((Bool) -> Void)?

    @ObservationIgnored private let transport: any UpdateTransport
    @ObservationIgnored private let publicKey: Curve25519.Signing.PublicKey?
    @ObservationIgnored private let bundleID: String
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let installer: (any UpdateInstalling)?
    /// The colleague an update was requested from, and the version.
    @ObservationIgnored private var expected: (peerID: String, version: String)?
    @ObservationIgnored private var downloadProgress: Progress?
    @ObservationIgnored private var progressObservation: NSKeyValueObservation?
    @ObservationIgnored private var requestTimeout: Task<Void, Never>?
    /// Colleagues this Mac is sending the package to right now.
    @ObservationIgnored private var uploads: Set<String> = []
    @ObservationIgnored private var announced: Set<String> = []
    @ObservationIgnored private let feed: (any UpdateFeed)?
    @ObservationIgnored private let installsAutomatically: () -> Bool
    @ObservationIgnored private let isIdle: () -> Bool
    /// Install as soon as the download finishes (someone clicked Update).
    @ObservationIgnored private var installWhenDownloaded = false
    @ObservationIgnored private var checking: Task<Void, Never>?

    /// How often the feed is checked, and how long after launch the first check waits.
    static let checkInterval: Duration = .seconds(6 * 3600)
    static let firstCheckDelay: Duration = .seconds(20)
    /// How often an automatic install looks for a quiet moment.
    static let idleCheckInterval: Duration = .seconds(60)

    static let maxUploads = 3
    static let requestWait: Duration = .seconds(20)

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DeskDrop", isDirectory: true).appendingPathComponent("Updates", isDirectory: true)
    }

    init(transport: any UpdateTransport, publicKey: Curve25519.Signing.PublicKey?, bundleID: String,
         currentVersion: String, directory: URL = UpdateService.defaultDirectory, installer: (any UpdateInstalling)?,
         feed: (any UpdateFeed)? = nil, installsAutomatically: @escaping () -> Bool = { false },
         isIdle: @escaping () -> Bool = { true }) {
        self.transport = transport
        self.feed = feed
        self.installsAutomatically = installsAutomatically
        self.isIdle = isIdle
        self.publicKey = publicKey
        self.bundleID = bundleID
        self.currentVersion = currentVersion
        self.directory = directory
        self.installer = installer
        transport.updateDelegate = self
        loadStoredPackage()
    }

    private var packageURL: URL { directory.appendingPathComponent("DeskDrop.\(UpdatePackage.fileExtension)") }

    private func isNewer(_ version: String) -> Bool {
        guard let candidate = AppVersion(version), let current = AppVersion(currentVersion) else { return false }
        return candidate > current
    }

    // MARK: - Publishing

    enum PublishError: LocalizedError {
        case notEnabled
        case invalid(UpdatePackage.Failure)
        case older(String)

        var errorDescription: String? {
            switch self {
            case .notEnabled: String(localized: "This copy of DeskDrop wasn’t built with an update key, so it can’t check updates.")
            case .invalid(.badSignature): String(localized: "This update isn’t signed with the key built into this copy of DeskDrop.")
            case .invalid(.archiveMismatch): String(localized: "This update is damaged or incomplete.")
            case .invalid: String(localized: "That isn’t a DeskDrop update for this app.")
            case .older(let version): String(localized: "This Mac already shares DeskDrop \(version), which is newer.")
            }
        }
    }

    /// Checks a package and starts offering it to colleagues.
    @discardableResult
    func publish(_ url: URL) throws -> UpdateManifest {
        guard let publicKey else { throw PublishError.notEnabled }
        let checked: (manifest: UpdateManifest, offer: UpdateOffer)
        do {
            checked = try UpdatePackage.verifyPackage(at: url, publicKey: publicKey, bundleID: bundleID)
        } catch let failure as UpdatePackage.Failure {
            throw PublishError.invalid(failure)
        }
        if let shared, let existing = AppVersion(shared.version), let new = AppVersion(checked.manifest.version),
           new < existing {
            throw PublishError.older(shared.version)
        }
        try keep(url, manifest: checked.manifest, offer: checked.offer)
        announced.removeAll()
        for peer in transport.readyPeers { announce(to: peer.id) }
        return checked.manifest
    }

    // MARK: - Updating

    /// Downloads the update if needed, then installs it and relaunches.
    func update() {
        guard let available else { return }
        installWhenDownloaded = true
        if available.isDownloaded {
            install()
            return
        }
        guard !isDownloading else { return }
        requestFromNextSource(after: nil)
    }

    // MARK: - The update feed (GitHub)

    var hasFeed: Bool { feed != nil && isEnabled }

    /// Checks the feed now, then every few hours; and installs downloaded updates
    /// automatically when DeskDrop is idle (if that's on).
    func startAutomaticUpdates() {
        guard isEnabled, checking == nil else { return }
        checking = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            var sinceCheck = Duration.zero
            while !Task.isCancelled {
                guard let self else { return }
                if sinceCheck == .zero { await self.checkFeed() }
                self.installIfIdle()
                try? await Task.sleep(for: Self.idleCheckInterval)
                sinceCheck += Self.idleCheckInterval
                if sinceCheck >= Self.checkInterval { sinceCheck = .zero }
            }
        }
    }

    /// Asks the feed for a newer version and, if there is one, downloads and
    /// checks it. Only a verified package becomes `available`.
    func checkFeed() async {
        guard let feed, isEnabled, !isChecking else { return }
        isChecking = true
        defer {
            isChecking = false
            lastChecked = .now
        }
        do {
            guard let release = try await feed.latest(), isNewer(release.version),
                  !(available?.isDownloaded == true && available?.manifest.version == release.version) else {
                checkFailure = nil
                return
            }
            let file = try await feed.download(release)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let publicKey,
                  let checked = try? UpdatePackage.verifyPackage(at: file, publicKey: publicKey, bundleID: bundleID),
                  isNewer(checked.manifest.version) else {
                checkFailure = String(localized: "The update on GitHub isn’t signed with this copy’s key, so it was ignored.")
                return
            }
            let isNew = available?.manifest.version != checked.manifest.version
            try keep(file, manifest: checked.manifest, offer: checked.offer)
            checkFailure = nil
            if !isDownloading, phase != .installing { phase = .idle }
            if isNew { onUpdateFound?(checked.manifest, "GitHub") }
            announced.removeAll()
            for peer in transport.readyPeers { announce(to: peer.id) }
            if installWhenDownloaded { install() } else { installIfIdle() }
        } catch GitHubReleases.Failure.rateLimited {
            checkFailure = String(localized: "GitHub asked DeskDrop to wait; it will check again later.")
        } catch {
            checkFailure = String(localized: "Couldn’t reach GitHub to check for updates.")
        }
    }

    /// With automatic updates on: installs a downloaded update while DeskDrop is
    /// in the background and nothing is being sent or received.
    func installIfIdle() {
        guard installsAutomatically(), available?.isDownloaded == true, phase == .idle, isIdle() else { return }
        Log.app.notice("Installing an update automatically")
        install()
    }

    private var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    private func requestFromNextSource(after previous: String?) {
        guard let available else { return }
        let candidates = available.sources.drop { previous != nil && $0 != previous }.dropFirst(previous == nil ? 0 : 1)
        guard let source = candidates.first(where: { transport.peer(for: $0)?.presence == .ready }) else {
            expected = nil
            // A background download just tries again when someone offers it next.
            phase = installWhenDownloaded
                ? .failed(String(localized: "Nobody who has DeskDrop \(available.manifest.version) is connected right now. Try again when they’re nearby."))
                : .idle
            return
        }
        do {
            try transport.send(.updateRequest(version: available.manifest.version), to: source)
        } catch {
            requestFromNextSource(after: source)
            return
        }
        expected = (source, available.manifest.version)
        phase = .downloading(fraction: 0)
        requestTimeout?.cancel()
        requestTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.requestWait)
            guard !Task.isCancelled, let self, self.expected?.peerID == source, self.downloadProgress == nil else { return }
            self.requestFromNextSource(after: source)
        }
    }

    private func install() {
        guard let available, available.isDownloaded, let installer else { return }
        phase = .installing
        let url = packageURL
        Task {
            do {
                try await installer.install(packageAt: url)
                Log.app.notice("Installed DeskDrop \(available.manifest.version, privacy: .public)")
                onInstalled?(!installWhenDownloaded)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func clearFailure() {
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Packages on this Mac

    /// Keeps a verified package as the one this Mac shares.
    private func keep(_ url: URL, manifest: UpdateManifest, offer: UpdateOffer) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if url.standardizedFileURL != packageURL.standardizedFileURL {
            let staging = directory.appendingPathComponent("incoming-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: url, to: staging)
            if FileManager.default.fileExists(atPath: packageURL.path) {
                _ = try FileManager.default.replaceItemAt(packageURL, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: packageURL)
            }
        }
        shared = manifest
        if isNewer(manifest.version) {
            let sources = available?.manifest.version == manifest.version ? available?.sources ?? [] : []
            available = Available(manifest: manifest, offer: offer, sources: sources, isDownloaded: true)
        }
    }

    /// At launch: the package this Mac kept, if it's still worth sharing.
    private func loadStoredPackage() {
        guard let publicKey, FileManager.default.fileExists(atPath: packageURL.path) else { return }
        guard let checked = try? UpdatePackage.verifyPackage(at: packageURL, publicKey: publicKey, bundleID: bundleID),
              let version = AppVersion(checked.manifest.version), let current = AppVersion(currentVersion),
              version >= current else {
            // Damaged, or older than what's installed: nobody needs it.
            try? FileManager.default.removeItem(at: packageURL)
            return
        }
        shared = checked.manifest
        if version > current {
            available = Available(manifest: checked.manifest, offer: checked.offer, sources: [], isDownloaded: true)
        }
    }

    // MARK: - Talking to colleagues

    private func announce(to peerID: String) {
        guard isEnabled, shared != nil, let peer = transport.peer(for: peerID), peer.supportsUpdates,
              !announced.contains(peerID), let offer = try? UpdatePackage.readOffer(at: packageURL).offer else { return }
        if (try? transport.send(.updateAvailable(offer), to: peerID)) != nil { announced.insert(peerID) }
    }

    private func receiveOffer(_ offer: UpdateOffer, from peerID: String) {
        guard let publicKey, let manifest = try? UpdatePackage.verify(offer, publicKey: publicKey, bundleID: bundleID),
              isNewer(manifest.version) else { return }
        if let available, let known = AppVersion(available.manifest.version), let offered = AppVersion(manifest.version) {
            if offered < known { return }
            if offered == known {
                if !available.sources.contains(peerID) { self.available?.sources.append(peerID) }
                return
            }
        }
        available = Available(manifest: manifest, offer: offer, sources: [peerID], isDownloaded: false)
        let name = transport.peer(for: peerID)?.displayName ?? String(localized: "a colleague")
        onUpdateFound?(manifest, name)
        // With automatic updates, fetch it now; it installs at a quiet moment.
        if installsAutomatically(), !isDownloading { requestFromNextSource(after: nil) }
    }

    private func receiveRequest(_ version: String, from peerID: String) {
        guard shared?.version == version, !uploads.contains(peerID), uploads.count < Self.maxUploads,
              transport.peer(for: peerID)?.supportsUpdates == true else { return }
        do {
            _ = try transport.sendResource(at: packageURL, named: UpdateResource.name(for: version), to: peerID) {
                @Sendable [weak self] _ in
                MainActor.assumeIsolated { _ = self?.uploads.remove(peerID) }
            }
            uploads.insert(peerID)
        } catch {
            Log.transfer.info("Update not sent: peer not reachable")
        }
    }

    private func downloaded(_ url: URL?, from peerID: String, error: Error?) {
        let source = expected?.peerID
        expected = nil
        downloadProgress = nil
        progressObservation = nil
        requestTimeout?.cancel()
        defer { if let url { try? FileManager.default.removeItem(at: url) } }
        guard let url, error == nil, let available, let publicKey,
              let checked = try? UpdatePackage.verifyPackage(at: url, publicKey: publicKey, bundleID: bundleID),
              checked.offer.manifest == available.offer.manifest else {
            Log.transfer.error("Downloaded update was incomplete or invalid")
            requestFromNextSource(after: source)
            return
        }
        do {
            try keep(url, manifest: checked.manifest, offer: checked.offer)
        } catch {
            phase = .failed(String(localized: "DeskDrop couldn’t save the update: \(error.localizedDescription)"))
            return
        }
        phase = .idle
        if installWhenDownloaded { install() } else { installIfIdle() }
    }
}

extension UpdateService: UpdateTransportDelegate {
    func updateTransport(didReceive message: ProtocolMessage, from peerID: String) {
        switch message {
        case .updateAvailable(let offer): receiveOffer(offer, from: peerID)
        case .updateRequest(let version): receiveRequest(version, from: peerID)
        default: break
        }
    }

    func updateTransportPeerBecameReady(_ peerID: String) {
        announced.remove(peerID)
        announce(to: peerID)
    }

    func updateTransport(didStartReceivingResourceNamed name: String, from peerID: String, progress: Progress) -> Bool {
        guard let expected, expected.peerID == peerID, name == UpdateResource.name(for: expected.version),
              downloadProgress == nil else { return false }
        downloadProgress = progress
        progressObservation = progress.observe(\.fractionCompleted) { @Sendable [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(fraction: fraction)
                }
            }
        }
        return true
    }

    func updateTransport(didFinishReceivingResourceNamed name: String, from peerID: String, at url: URL?, error: Error?) {
        guard let expected, expected.peerID == peerID, name == UpdateResource.name(for: expected.version) else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }
        downloaded(url, from: peerID, error: error)
    }
}
