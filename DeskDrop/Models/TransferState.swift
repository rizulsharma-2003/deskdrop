import Foundation

enum TransferDirection: String, Codable, Sendable {
    case outgoing
    case incoming
}

/// Who stopped a transfer.
enum CancelSource: String, Codable, Sendable {
    case local
    case remote
}

/// Why a recipient said no. Travels on the wire in `.decline` messages.
enum DeclineReason: String, Codable, Sendable, CaseIterable {
    case userDeclined
    case busy
    case insufficientSpace
    case destinationUnavailable
    case expired

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DeclineReason(rawValue: raw) ?? .userDeclined
    }
}

/// Why a transfer failed. Travels on the wire in `.failure` messages.
enum FailureReason: String, Codable, Sendable, CaseIterable {
    case peerDisconnected
    case peerUnavailable
    case timedOut
    case fileUnavailable
    case fileChanged
    case accessDenied
    case destinationUnavailable
    case insufficientSpace
    case validationFailed
    case sendFailed
    case receiveFailed
    case finalizeFailed
    case protocolError
    case tooManyFiles
    case duplicateTransfer
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FailureReason(rawValue: raw) ?? .unknown
    }
}

/// The explicit lifecycle of a transfer, shared by both directions.
///
/// Outgoing:  preparing → offering → awaitingAcceptance → accepted → transferring → verifying → completed
/// Incoming:  awaitingDecision → accepted → transferring → verifying → completed
///
/// Any active phase may end in `cancelled` or `failed`; offers may also end in
/// `declined` or `expired`. Terminal phases never change again, which makes repeated
/// button presses and late network messages harmless.
enum TransferPhase: Equatable, Sendable {
    case preparing
    case offering
    case awaitingAcceptance
    case awaitingDecision
    case accepted
    case transferring
    case verifying
    case completed
    case declined(DeclineReason)
    case cancelled(CancelSource)
    case failed(FailureReason)
    case expired

    var isTerminal: Bool {
        switch self {
        case .completed, .declined, .cancelled, .failed, .expired: true
        default: false
        }
    }

    var isActive: Bool { !isTerminal }

    /// True while file bytes may be moving.
    var isMovingData: Bool {
        switch self {
        case .accepted, .transferring, .verifying: true
        default: false
        }
    }

    func canTransition(to next: TransferPhase) -> Bool {
        guard !isTerminal, next != self else { return false }
        switch (self, next) {
        case (_, .cancelled), (_, .failed):
            return true
        case (.preparing, .offering),
             (.offering, .awaitingAcceptance),
             (.awaitingAcceptance, .accepted), (.awaitingDecision, .accepted),
             (.awaitingAcceptance, .declined), (.awaitingDecision, .declined),
             (.awaitingAcceptance, .expired), (.awaitingDecision, .expired),
             (.accepted, .transferring), (.accepted, .verifying), (.accepted, .completed),
             (.transferring, .verifying), (.transferring, .completed),
             (.verifying, .completed):
            return true
        default:
            return false
        }
    }
}
