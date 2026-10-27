import Foundation

/// The boundary between the transfer protocol and the network.
///
/// `PeerConnectionService` implements it with Multipeer Connectivity; tests use an
/// in-process loopback so the protocol and file handling can be exercised without
/// two Macs. Peers are identified by their installation ID.
@MainActor
protocol PeerTransport: AnyObject {
    var transferDelegate: (any PeerTransportDelegate)? { get set }

    func peer(for id: String) -> PeerDevice?

    /// Sends a control message reliably. Throws if the peer is not connected.
    func send(_ message: ProtocolMessage, to peerID: String) throws

    /// Streams a file to the peer. `completion` runs on the main actor once the
    /// transport has finished sending (not when the recipient has saved it).
    func sendResource(at url: URL, named name: String, to peerID: String,
                      completion: @escaping @MainActor @Sendable (Error?) -> Void) throws -> Progress
}

@MainActor
protocol PeerTransportDelegate: AnyObject {
    func transport(didReceive message: ProtocolMessage, from peerID: String)
    func transport(didStartReceivingResourceNamed name: String, from peerID: String, progress: Progress)
    /// The delegate owns `url` and must move or delete it.
    func transport(didFinishReceivingResourceNamed name: String, from peerID: String, at url: URL?, error: Error?)
    func transportPeerBecameReady(_ peerID: String)
    func transportPeerDisconnected(_ peerID: String)
}

enum TransportError: Error, Equatable {
    case peerNotConnected
    case resourceRejected
}
