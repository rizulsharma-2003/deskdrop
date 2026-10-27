import Foundation
import Testing
@testable import DeskDrop

/// A fresh directory under the (sandboxed) temporary folder, removed by `cleanUp()`.
struct TemporaryDirectory {
    let url: URL

    init(_ label: String = "DeskDropTests") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func subdirectory(_ name: String) -> URL {
        let sub = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        return sub
    }

    @discardableResult
    func file(_ relativePath: String, contents: Data) throws -> URL {
        let fileURL = url.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: fileURL)
        return fileURL
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Polls `condition` on the main actor until it holds or the timeout passes.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ description: String = "condition",
               sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        if clock.now > deadline {
            Issue.record("Timed out waiting for \(description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

func randomData(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

/// A receiving folder and staging area inside a temporary directory.
@MainActor
final class TestDestination: ReceivingDestination {
    let directory: URL
    let stagingRoot: URL
    var duplicateHandling: DuplicateHandling = .keepBoth
    var failure: Error?

    init(root: TemporaryDirectory) {
        directory = root.subdirectory("Received")
        stagingRoot = root.subdirectory("Staging")
    }

    func prepareDestination(requiredBytes: Int64) throws -> URL {
        if let failure { throw failure }
        return directory
    }

    var receivedItems: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()) ?? []
    }
}

/// An in-process stand-in for the network. Messages go through the real
/// `ProtocolCodec`, and resources are copied as files, delivered asynchronously
/// on the main queue like Multipeer Connectivity's callbacks. It proves the
/// protocol and file handling, not that two Macs can reach each other.
@MainActor
final class LoopbackTransport: PeerTransport, ChatTransport, UpdateTransport {
    weak var transferDelegate: (any PeerTransportDelegate)?
    weak var chatDelegate: (any ChatTransportDelegate)?
    weak var updateDelegate: (any UpdateTransportDelegate)?
    var localPeer: PeerDevice
    weak var remote: LoopbackTransport?
    private let scratch: URL

    var isConnected = true
    private(set) var sentMessages: [ProtocolMessage] = []
    /// Applied to each received copy before delivery, to simulate corruption.
    var tamperWithReceivedFile: ((URL) -> Void)?
    /// When true, resources wait in `heldResources` until `releaseResources()`.
    var holdResources = false
    private var heldResources: [() -> Void] = []

    init(localPeer: PeerDevice, scratch: URL) {
        self.localPeer = localPeer
        self.scratch = scratch
    }

    static func pair(in root: TemporaryDirectory) -> (alice: LoopbackTransport, bob: LoopbackTransport) {
        let alice = LoopbackTransport(localPeer: makePeer(name: "Alice’s Mac"), scratch: root.subdirectory("AliceWire"))
        let bob = LoopbackTransport(localPeer: makePeer(name: "Bob’s Mac"), scratch: root.subdirectory("BobWire"))
        alice.remote = bob
        bob.remote = alice
        return (alice, bob)
    }

    static func makePeer(name: String) -> PeerDevice {
        PeerDevice(id: UUID().uuidString, displayName: name, deviceKind: .laptop, presence: .ready, lastSeen: .now,
                   supportsChat: true, supportsTyping: true, supportsAvatar: true, supportsMedia: true,
                   supportsUpdates: true)
    }

    var remotePeer: PeerDevice? { remote?.localPeer }

    var readyPeers: [PeerDevice] {
        guard isConnected, let remotePeer else { return [] }
        return [remotePeer]
    }

    /// Reconnects both sides and tells each one the other is ready, as the
    /// handshake would.
    func connectAndAnnounce() {
        guard let remote else { return }
        isConnected = true
        remote.isConnected = true
        chatDelegate?.chatTransportPeerBecameReady(remote.localPeer.id)
        remote.chatDelegate?.chatTransportPeerBecameReady(localPeer.id)
        updateDelegate?.updateTransportPeerBecameReady(remote.localPeer.id)
        remote.updateDelegate?.updateTransportPeerBecameReady(localPeer.id)
    }

    private func route(_ message: ProtocolMessage, from peerID: String) {
        if message.isUpdate {
            updateDelegate?.updateTransport(didReceive: message, from: peerID)
        } else if message.isChat {
            chatDelegate?.chatTransport(didReceive: message, from: peerID)
        } else {
            transferDelegate?.transport(didReceive: message, from: peerID)
        }
    }

    func peer(for id: String) -> PeerDevice? {
        guard isConnected, let remotePeer, remotePeer.id == id else { return nil }
        return remotePeer
    }

    func send(_ message: ProtocolMessage, to peerID: String) throws {
        guard isConnected, let remote, remote.localPeer.id == peerID else { throw TransportError.peerNotConnected }
        let data = try ProtocolCodec.encode(message)
        sentMessages.append(message)
        let from = localPeer.id
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard remote.isConnected, let decoded = try? ProtocolCodec.decode(data) else { return }
                remote.route(decoded, from: from)
            }
        }
    }

    /// Delivers raw bytes as if they arrived from the network, bypassing encoding.
    func deliverRaw(_ message: ProtocolMessage, from peerID: String) {
        route(message, from: peerID)
    }

    func sendResource(at url: URL, named name: String, to peerID: String,
                      completion: @escaping @MainActor @Sendable (Error?) -> Void) throws -> Progress {
        guard isConnected, let remote, remote.localPeer.id == peerID else { throw TransportError.peerNotConnected }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let senderProgress = Progress(totalUnitCount: max(size, 1))
        let receiverProgress = UncheckedSendable(Progress(totalUnitCount: max(size, 1)))
        let sender = UncheckedSendable(senderProgress)
        let copy = remote.scratch.appendingPathComponent(UUID().uuidString)
        let from = localPeer.id

        let deliver: @MainActor () -> Void = {
            guard remote.isConnected, !sender.value.isCancelled else {
                completion(CancellationError())
                return
            }
            if UpdateResource.isUpdate(name) {
                if remote.updateDelegate?.updateTransport(didStartReceivingResourceNamed: name, from: from,
                                                          progress: receiverProgress.value) != true {
                    receiverProgress.value.cancel()
                }
            } else {
                remote.transferDelegate?.transport(didStartReceivingResourceNamed: name, from: from, progress: receiverProgress.value)
            }
            guard !receiverProgress.value.isCancelled else {
                completion(CancellationError())
                return
            }
            do {
                try FileManager.default.copyItem(at: url, to: copy)
                remote.tamperWithReceivedFile?(copy)
            } catch {
                completion(error)
                return
            }
            sender.value.completedUnitCount = size
            receiverProgress.value.completedUnitCount = size
            if UpdateResource.isUpdate(name) {
                remote.updateDelegate?.updateTransport(didFinishReceivingResourceNamed: name, from: from, at: copy, error: nil)
            } else {
                remote.transferDelegate?.transport(didFinishReceivingResourceNamed: name, from: from, at: copy, error: nil)
            }
            completion(nil)
        }

        if holdResources {
            heldResources.append(deliver)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver() } }
        }
        return senderProgress
    }

    func releaseResources() {
        let pending = heldResources
        heldResources.removeAll()
        pending.forEach { $0() }
    }

    var heldResourceCount: Int { heldResources.count }

    /// Drops the link in both directions, as a lost Wi-Fi connection would.
    func disconnect() {
        guard let remote else { return }
        isConnected = false
        remote.isConnected = false
        transferDelegate?.transportPeerDisconnected(remote.localPeer.id)
        remote.transferDelegate?.transportPeerDisconnected(localPeer.id)
    }
}
