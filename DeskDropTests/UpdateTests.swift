import CryptoKit
import Foundation
import Testing
@testable import DeskDrop

/// Writes a signed package around `archive` bytes.
private func makePackage(in root: TemporaryDirectory, version: String, key: Curve25519.Signing.PrivateKey,
                         bundleID: String = "com.deskdrop.app", archive: Data = randomData(64 * 1024),
                         notes: String = "### Added\n- Things") throws -> URL {
    let archiveURL = try root.file("archive-\(UUID().uuidString).zip", contents: archive)
    let url = root.url.appendingPathComponent("DeskDrop-\(version)-\(UUID().uuidString).deskdropupdate")
    _ = try UpdatePackage.write(archive: archiveURL, bundleID: bundleID, version: version, build: "1",
                                minimumSystemVersion: "14.0", notes: notes, signingKey: key, to: url)
    return url
}

@Suite("Update packages")
struct UpdatePackageTests {
    private let key = Curve25519.Signing.PrivateKey()

    @Test("A signed package verifies, and its manifest says what it is")
    func roundTrip() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let archive = randomData(200_000)
        let url = try makePackage(in: root, version: "1.8.0", key: key, archive: archive)
        let (manifest, offer) = try UpdatePackage.verifyPackage(at: url, publicKey: key.publicKey, bundleID: "com.deskdrop.app")
        #expect(manifest.version == "1.8.0")
        #expect(manifest.archiveSize == 200_000)
        #expect(manifest.notes == "### Added\n- Things")
        #expect(try UpdatePackage.verify(offer, publicKey: key.publicKey, bundleID: "com.deskdrop.app") == manifest)

        let extracted = root.url.appendingPathComponent("out.zip")
        try UpdatePackage.extractArchive(from: url, to: extracted)
        #expect(try Data(contentsOf: extracted) == archive)
    }

    @Test("Another key, another app, or a changed byte is refused")
    func refusals() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let url = try makePackage(in: root, version: "1.8.0", key: key)
        #expect(throws: UpdatePackage.Failure.badSignature) {
            try UpdatePackage.verifyPackage(at: url, publicKey: Curve25519.Signing.PrivateKey().publicKey, bundleID: "com.deskdrop.app")
        }
        #expect(throws: UpdatePackage.Failure.wrongApp) {
            try UpdatePackage.verifyPackage(at: url, publicKey: key.publicKey, bundleID: "com.example.other")
        }

        // One flipped bit in the archive.
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count - 10] ^= 0x01
        let damaged = try root.file("damaged.deskdropupdate", contents: bytes)
        #expect(throws: UpdatePackage.Failure.archiveMismatch) {
            try UpdatePackage.verifyPackage(at: damaged, publicKey: key.publicKey, bundleID: "com.deskdrop.app")
        }

        // A manifest edited to claim another version breaks the signature.
        let (offer, _) = try UpdatePackage.readOffer(at: url)
        let edited = String(decoding: offer.manifest, as: UTF8.self).replacingOccurrences(of: "1.8.0", with: "9.9.9")
        #expect(throws: UpdatePackage.Failure.badSignature) {
            try UpdatePackage.verify(UpdateOffer(manifest: Data(edited.utf8), signature: offer.signature),
                                     publicKey: key.publicKey, bundleID: "com.deskdrop.app")
        }

        // Truncated: the archive is short.
        let truncated = try root.file("short.deskdropupdate", contents: bytes.prefix(bytes.count - 100))
        #expect(throws: UpdatePackage.Failure.archiveMismatch) {
            try UpdatePackage.verifyPackage(at: truncated, publicKey: key.publicKey, bundleID: "com.deskdrop.app")
        }
        let junk = try root.file("junk.deskdropupdate", contents: randomData(1000))
        #expect(throws: UpdatePackage.Failure.notAPackage) {
            try UpdatePackage.verifyPackage(at: junk, publicKey: key.publicKey, bundleID: "com.deskdrop.app")
        }
    }

    @Test("Versions compare number by number")
    func versions() throws {
        func v(_ s: String) throws -> AppVersion { try #require(AppVersion(s)) }
        #expect(try v("1.10.0") > v("1.9.9"))
        #expect(try v("1.7") == v("1.7.0"))
        #expect(try v("2.0") > v("1.99.99"))
        #expect(try v("1.7.1") > v("1.7"))
        #expect(AppVersion("1.7.0-beta") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("1..2") == nil)
    }

    @Test("Public keys are read from 64 hex characters only")
    func publicKeys() {
        let hex = UpdatePackage.hex(key.publicKey.rawRepresentation)
        #expect(UpdatePackage.publicKey(hex: hex)?.rawRepresentation == key.publicKey.rawRepresentation)
        #expect(UpdatePackage.publicKey(hex: hex.uppercased()) != nil)
        #expect(UpdatePackage.publicKey(hex: "") == nil, "Builds without a key have updates off")
        #expect(UpdatePackage.publicKey(hex: "$(DESKDROP_UPDATE_PUBLIC_KEY)") == nil)
        #expect(UpdatePackage.publicKey(hex: String(repeating: "z", count: 64)) == nil)
    }
}

/// Records what it was asked to install.
@MainActor
private final class FakeInstaller: UpdateInstalling {
    var installed: [Data] = []
    var failure: String?

    func install(packageAt url: URL) async throws {
        if let failure { throw UpdateInstaller.Failure.helper(failure) }
        installed.append(try Data(contentsOf: url))
    }
}

/// A publisher (Alice) and a colleague (Bob), both on 1.7.0, over the loopback.
@MainActor
private final class UpdateHarness {
    let root = TemporaryDirectory("DeskDropUpdates")
    let key = Curve25519.Signing.PrivateKey()
    let aliceWire: LoopbackTransport
    let bobWire: LoopbackTransport
    let alice: UpdateService
    var bob: UpdateService
    let bobInstaller = FakeInstaller()
    var found: [String] = []
    var relaunched = 0

    init(connected: Bool = true, bobKey: Curve25519.Signing.PublicKey? = nil) {
        let (aliceWire, bobWire) = LoopbackTransport.pair(in: root)
        self.aliceWire = aliceWire
        self.bobWire = bobWire
        aliceWire.isConnected = connected
        bobWire.isConnected = connected
        alice = UpdateService(transport: aliceWire, publicKey: key.publicKey, bundleID: "com.deskdrop.app",
                              currentVersion: "1.7.0", directory: root.subdirectory("AliceUpdates"), installer: nil)
        bob = UpdateService(transport: bobWire, publicKey: bobKey ?? key.publicKey, bundleID: "com.deskdrop.app",
                            currentVersion: "1.7.0", directory: root.subdirectory("BobUpdates"), installer: bobInstaller)
        bob.onUpdateFound = { [unowned self] manifest, _ in found.append(manifest.version) }
        bob.onInstalled = { [unowned self] _ in relaunched += 1 }
    }

    func package(_ version: String, signedWith signer: Curve25519.Signing.PrivateKey? = nil) throws -> URL {
        try makePackage(in: root, version: version, key: signer ?? key)
    }

    deinit {
        root.cleanUp()
    }
}

@Suite("Updates between Macs, over loopback", .serialized)
@MainActor
struct UpdateServiceTests {
    @Test("A published update reaches a colleague, downloads, verifies and installs")
    func endToEnd() async throws {
        let harness = UpdateHarness()
        let package = try harness.package("1.8.0")
        try harness.alice.publish(package)
        #expect(harness.alice.shared?.version == "1.8.0")

        await waitUntil("Bob hears about it") { harness.bob.available?.manifest.version == "1.8.0" }
        #expect(harness.found == ["1.8.0"])
        #expect(harness.bob.available?.sources == [harness.aliceID])
        #expect(harness.bob.available?.isDownloaded == false)

        harness.bob.update()
        await waitUntil("installed") { harness.relaunched == 1 }
        #expect(harness.bobInstaller.installed == [try Data(contentsOf: package)])
        #expect(harness.bob.shared?.version == "1.8.0", "Bob keeps it to pass on")
    }

    @Test("After relaunching on the new version, a Mac passes the update on and doesn't offer it to itself")
    func relay() async throws {
        let harness = UpdateHarness()
        try harness.alice.publish(try harness.package("1.8.0"))
        await waitUntil("offer") { harness.bob.available != nil }
        harness.bob.update()
        await waitUntil("installed") { harness.relaunched == 1 }

        // Bob's Mac restarts on 1.8.0, with the package it kept.
        let relaunched = UpdateService(transport: harness.bobWire, publicKey: harness.key.publicKey, bundleID: "com.deskdrop.app",
                                       currentVersion: "1.8.0", directory: harness.root.url.appendingPathComponent("BobUpdates"),
                                       installer: nil)
        #expect(relaunched.shared?.version == "1.8.0")
        #expect(relaunched.available == nil)
        harness.aliceWire.connectAndAnnounce()
        await waitUntil("Bob offers it back") {
            harness.aliceWire.sentMessages.contains { $0.kind == .updateAvailable }
                && harness.bobWire.sentMessages.contains { $0.kind == .updateAvailable }
        }
    }

    @Test("Colleagues who connect later are told on connecting")
    func onConnect() async throws {
        let harness = UpdateHarness(connected: false)
        try harness.alice.publish(try harness.package("1.8.0"))
        #expect(harness.bob.available == nil)
        harness.aliceWire.connectAndAnnounce()
        await waitUntil("offer") { harness.bob.available?.manifest.version == "1.8.0" }
    }

    @Test("Offers signed with another key, or not newer, are ignored")
    func ignored() async throws {
        let harness = UpdateHarness()
        let stranger = Curve25519.Signing.PrivateKey()
        let forged = try UpdatePackage.readOffer(at: try harness.package("9.0.0", signedWith: stranger)).offer
        harness.bobWire.deliverRaw(.updateAvailable(forged), from: harness.aliceID)
        let same = try UpdatePackage.readOffer(at: try harness.package("1.7.0")).offer
        harness.bobWire.deliverRaw(.updateAvailable(same), from: harness.aliceID)
        let older = try UpdatePackage.readOffer(at: try harness.package("1.6.0")).offer
        harness.bobWire.deliverRaw(.updateAvailable(older), from: harness.aliceID)
        #expect(harness.bob.available == nil)
        #expect(harness.found.isEmpty)
        #expect(throws: UpdateService.PublishError.self) { try harness.alice.publish(try harness.package("2.0.0", signedWith: stranger)) }
    }

    @Test("A newer offer replaces an older one; the same one from someone else adds a source")
    func newerWins() async throws {
        let harness = UpdateHarness()
        let first = try UpdatePackage.readOffer(at: try harness.package("1.8.0")).offer
        let second = try UpdatePackage.readOffer(at: try harness.package("1.9.0")).offer
        harness.bobWire.deliverRaw(.updateAvailable(first), from: harness.aliceID)
        harness.bobWire.deliverRaw(.updateAvailable(first), from: "someone-else")
        #expect(harness.bob.available?.sources == [harness.aliceID, "someone-else"])
        harness.bobWire.deliverRaw(.updateAvailable(second), from: harness.aliceID)
        #expect(harness.bob.available?.manifest.version == "1.9.0")
        harness.bobWire.deliverRaw(.updateAvailable(first), from: harness.aliceID)
        #expect(harness.bob.available?.manifest.version == "1.9.0")
        #expect(harness.found == ["1.8.0", "1.9.0"])
    }

    @Test("Update files nobody asked for are refused, and requests for unknown versions go unanswered")
    func unsolicited() async throws {
        let harness = UpdateHarness()
        let package = try harness.package("1.8.0")
        _ = try harness.aliceWire.sendResource(at: package, named: UpdateResource.name(for: "1.8.0"), to: harness.bobID) { _ in }
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.bob.shared == nil)
        #expect(harness.bob.available == nil)

        harness.aliceWire.deliverRaw(.updateRequest(version: "1.8.0"), from: harness.bobID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.aliceWire.heldResourceCount == 0)
        #expect(!harness.aliceWire.sentMessages.contains { $0.kind == .updateAvailable })
    }

    @Test("When the installer refuses, the reason is shown and nothing relaunches")
    func installFailure() async throws {
        let harness = UpdateHarness()
        harness.bobInstaller.failure = "DeskDrop couldn’t be replaced: permission denied"
        try harness.alice.publish(try harness.package("1.8.0"))
        await waitUntil("offer") { harness.bob.available != nil }
        harness.bob.update()
        await waitUntil("failed") { harness.bob.phase == .failed("DeskDrop couldn’t be replaced: permission denied") }
        #expect(harness.relaunched == 0)
    }

    @Test("A build without an update key ignores updates entirely")
    func disabled() async throws {
        let harness = UpdateHarness()
        let noKey = UpdateService(transport: harness.bobWire, publicKey: nil, bundleID: "com.deskdrop.app",
                                  currentVersion: "1.7.0", directory: harness.root.subdirectory("NoKey"), installer: nil)
        #expect(!noKey.isEnabled)
        try harness.alice.publish(try harness.package("1.8.0"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(noKey.available == nil)
        #expect(throws: UpdateService.PublishError.self) { try noKey.publish(try harness.package("1.8.0")) }
    }
}

private extension UpdateHarness {
    var aliceID: String { aliceWire.localPeer.id }
    var bobID: String { bobWire.localPeer.id }
}

@Suite("GitHub releases feed")
struct GitHubReleasesTests {
    private func json(tag: String = "v1.8.0", assets: String, prerelease: Bool = false) -> Data {
        Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/rizulsharma-2003/deskdrop/releases/tag/\(tag)",
         "draft":false,"prerelease":\(prerelease),"assets":[\(assets)]}
        """.utf8)
    }

    private func asset(_ name: String, _ url: String, size: Int = 5_000_000) -> String {
        "{\"name\":\"\(name)\",\"browser_download_url\":\"\(url)\",\"size\":\(size)}"
    }

    @Test("The release's version and its .deskdropupdate are found")
    func decodes() throws {
        let data = json(assets: [
            asset("DeskDrop-1.8.0.dmg", "https://github.com/rizulsharma-2003/deskdrop/releases/download/v1.8.0/DeskDrop-1.8.0.dmg"),
            asset("DeskDrop-1.8.0.deskdropupdate",
                  "https://github.com/rizulsharma-2003/deskdrop/releases/download/v1.8.0/DeskDrop-1.8.0.deskdropupdate"),
        ].joined(separator: ","))
        let release = try #require(try GitHubReleases.decode(data, repository: "rizulsharma-2003/deskdrop"))
        #expect(release.version == "1.8.0")
        #expect(release.packageURL.lastPathComponent == "DeskDrop-1.8.0.deskdropupdate")
        #expect(release.size == 5_000_000)
    }

    @Test("Packages from elsewhere, pre-releases and odd tags are ignored")
    func ignores() throws {
        let elsewhere = json(assets: asset("DeskDrop.deskdropupdate", "https://evil.example/DeskDrop.deskdropupdate"))
        #expect(try GitHubReleases.decode(elsewhere, repository: "rizulsharma-2003/deskdrop") == nil)
        let otherRepo = json(assets: asset("DeskDrop.deskdropupdate",
                                           "https://github.com/someone/else/releases/download/v1/DeskDrop.deskdropupdate"))
        #expect(try GitHubReleases.decode(otherRepo, repository: "rizulsharma-2003/deskdrop") == nil)
        let plainHTTP = json(assets: asset("DeskDrop.deskdropupdate",
                                           "http://github.com/rizulsharma-2003/deskdrop/releases/download/v1/DeskDrop.deskdropupdate"))
        #expect(try GitHubReleases.decode(plainHTTP, repository: "rizulsharma-2003/deskdrop") == nil)
        let pre = json(assets: asset("DeskDrop.deskdropupdate",
                                     "https://github.com/rizulsharma-2003/deskdrop/releases/download/v1/DeskDrop.deskdropupdate"),
                       prerelease: true)
        #expect(try GitHubReleases.decode(pre, repository: "rizulsharma-2003/deskdrop") == nil)
        let tag = json(tag: "nightly", assets: asset("DeskDrop.deskdropupdate",
                                                     "https://github.com/rizulsharma-2003/deskdrop/releases/download/nightly/DeskDrop.deskdropupdate"))
        #expect(try GitHubReleases.decode(tag, repository: "rizulsharma-2003/deskdrop") == nil)
        #expect(throws: GitHubReleases.Failure.malformed) { try GitHubReleases.decode(Data("<html>".utf8), repository: "a/b") }
    }

    @Test("Repository names are owner/name only")
    func repositories() {
        #expect(GitHubReleases.isValidRepository("rizulsharma-2003/deskdrop"))
        #expect(GitHubReleases.isValidRepository("a.b/c_d"))
        #expect(!GitHubReleases.isValidRepository(""))
        #expect(!GitHubReleases.isValidRepository("deskdrop"))
        #expect(!GitHubReleases.isValidRepository("a/b/c"))
        #expect(!GitHubReleases.isValidRepository("../x"))
        #expect(!GitHubReleases.isValidRepository("a/b?x=1"))
        #expect(!GitHubReleases.isValidRepository("$(DESKDROP_UPDATE_REPOSITORY)"))
    }
}

/// A feed that serves a local package.
private struct FakeFeed: UpdateFeed {
    let version: String
    let package: URL?
    var fails = false

    func latest() async throws -> FeedRelease? {
        if fails { throw GitHubReleases.Failure.unavailable }
        guard let package else { return nil }
        return FeedRelease(version: version, packageURL: package, size: 0, pageURL: nil)
    }

    func download(_ release: FeedRelease) async throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("feed-test-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: release.packageURL, to: copy)
        return copy
    }
}

@Suite("Automatic updates", .serialized)
@MainActor
struct AutomaticUpdateTests {
    private final class Box {
        var automatic = true
        var idle = true
        var installed: [Bool] = []
        var found: [String] = []
    }

    private func service(_ root: TemporaryDirectory, key: Curve25519.Signing.PrivateKey, feed: FakeFeed?, box: Box,
                         installer: FakeInstaller = FakeInstaller()) -> (UpdateService, LoopbackTransport) {
        let wire = LoopbackTransport.pair(in: root).alice
        let service = UpdateService(transport: wire, publicKey: key.publicKey, bundleID: "com.deskdrop.app",
                                    currentVersion: "1.7.0", directory: root.subdirectory("Updates-\(UUID().uuidString)"),
                                    installer: installer, feed: feed, installsAutomatically: { box.automatic },
                                    isIdle: { box.idle })
        service.onInstalled = { box.installed.append($0) }
        service.onUpdateFound = { manifest, from in box.found.append("\(manifest.version) from \(from)") }
        return (service, wire)
    }

    @Test("A newer release on GitHub is downloaded, verified and installed while idle")
    func fromGitHub() async throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let key = Curve25519.Signing.PrivateKey()
        let box = Box()
        let (updates, _) = service(root, key: key, feed: FakeFeed(version: "1.8.0", package: try makePackage(in: root, version: "1.8.0", key: key)),
                                   box: box)
        await updates.checkFeed()
        #expect(updates.available?.isDownloaded == true)
        #expect(updates.shared?.version == "1.8.0", "Shared with colleagues too")
        #expect(box.found == ["1.8.0 from GitHub"])
        await waitUntil("installed") { box.installed == [true] }
        #expect(updates.checkFailure == nil)
    }

    @Test("Not while you're using DeskDrop, and not with automatic updates off")
    func waitsForIdle() async throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let key = Curve25519.Signing.PrivateKey()
        let box = Box()
        box.idle = false
        let (updates, _) = service(root, key: key, feed: FakeFeed(version: "1.8.0", package: try makePackage(in: root, version: "1.8.0", key: key)),
                                   box: box)
        await updates.checkFeed()
        #expect(updates.available?.isDownloaded == true)
        updates.installIfIdle()
        box.automatic = false
        box.idle = true
        updates.installIfIdle()
        try await Task.sleep(for: .milliseconds(50))
        #expect(box.installed.isEmpty)

        box.automatic = true
        updates.installIfIdle()
        await waitUntil("installed once idle") { box.installed == [true] }
    }

    @Test("A release signed with another key, or not newer, is ignored")
    func refusesFeed() async throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let key = Curve25519.Signing.PrivateKey()
        let box = Box()
        let forged = try makePackage(in: root, version: "9.0.0", key: Curve25519.Signing.PrivateKey())
        let (updates, _) = service(root, key: key, feed: FakeFeed(version: "9.0.0", package: forged), box: box)
        await updates.checkFeed()
        #expect(updates.available == nil)
        #expect(updates.checkFailure != nil)

        let (current, _) = service(root, key: key, feed: FakeFeed(version: "1.7.0", package: try makePackage(in: root, version: "1.7.0", key: key)),
                                   box: box)
        await current.checkFeed()
        #expect(current.available == nil)
        #expect(current.checkFailure == nil)
        #expect(current.lastChecked != nil)

        let (offline, _) = service(root, key: key, feed: FakeFeed(version: "1.8.0", package: nil, fails: true), box: box)
        await offline.checkFeed()
        #expect(offline.checkFailure != nil)
        #expect(box.installed.isEmpty)
    }

    @Test("An update offered by a nearby Mac downloads by itself and installs when idle")
    func fromColleague() async throws {
        let harness = UpdateHarness()
        harness.bob.onInstalled = { _ in harness.relaunched += 1 }
        try harness.alice.publish(try harness.package("1.8.0"))
        await waitUntil("offer") { harness.bob.available != nil }
        // Bob's harness has automatic updates off: nothing downloads until he clicks.
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.bob.available?.isDownloaded == false)

        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let box = Box()
        let carol = UpdateService(transport: harness.bobWire, publicKey: harness.key.publicKey, bundleID: "com.deskdrop.app",
                                  currentVersion: "1.7.0", directory: root.subdirectory("Carol"), installer: FakeInstaller(),
                                  installsAutomatically: { box.automatic }, isIdle: { box.idle })
        carol.onInstalled = { box.installed.append($0) }
        harness.aliceWire.connectAndAnnounce()
        await waitUntil("downloaded and installed quietly") { box.installed == [true] }
    }
}
