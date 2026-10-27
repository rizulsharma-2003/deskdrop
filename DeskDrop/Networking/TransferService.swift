import Foundation
import Observation

/// Runs the DeskDrop transfer protocol in both directions.
///
/// It owns every transfer's state machine, talks to the network only through
/// `PeerTransport`, and never reports success on its own: an outgoing transfer is
/// complete only when the recipient says it has verified and saved every file, and
/// an incoming one only after the files are in the receiving folder.
@MainActor
@Observable
final class TransferService {
    /// Newest first. Finished transfers stay until dismissed or trimmed.
    private(set) var transfers: [Transfer] = []

    @ObservationIgnored var onIncomingOffer: ((Transfer) -> Void)?
    @ObservationIgnored var onTransferFinished: ((Transfer) -> Void)?

    @ObservationIgnored var offerTimeout = ProtocolLimits.offerTimeout
    @ObservationIgnored var completionTimeout = ProtocolLimits.completionTimeout
    @ObservationIgnored var connectionWaitTimeout = ProtocolLimits.connectionWaitTimeout
    @ObservationIgnored var stallTimeout = ProtocolLimits.stallTimeout

    @ObservationIgnored private let transport: any PeerTransport
    @ObservationIgnored private let destination: any ReceivingDestination
    @ObservationIgnored private let preparer: @Sendable ([URL]) async throws -> PreparedTransfer
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var outgoing: [UUID: OutgoingContext] = [:]
    @ObservationIgnored private var incoming: [UUID: IncomingContext] = [:]
    @ObservationIgnored private var seenOfferIDs = BoundedIDSet(capacity: 2048)
    @ObservationIgnored private let timers = ScheduledTasks<TimerKey>()
    @ObservationIgnored private var ticker: Task<Void, Never>?

    private static let maxFinishedTransfers = 40
    private static let tickInterval: Duration = .milliseconds(250)

    private enum TimerKey: Hashable {
        case offerExpiry(UUID)
        case completion(UUID)
        case connectionWait(UUID)

        static func all(for id: UUID) -> [TimerKey] {
            [.offerExpiry(id), .completion(id), .connectionWait(id)]
        }
    }

    /// Measured progress shared by both directions.
    private final class ProgressTracker {
        var estimator = ThroughputEstimator()
        var lastBytes: Int64 = 0
        var lastChange: TimeInterval

        init(now: TimeInterval) { lastChange = now }
    }

    private final class OutgoingContext {
        var preparation: Task<Void, Never>?
        var prepared: PreparedTransfer?
        var nextIndex = 0
        var currentIndex: Int?
        var currentProgress: Progress?
        var completedBytes: Int64 = 0
        var scopedURLs: [URL] = []
        let tracker: ProgressTracker

        init(now: TimeInterval) { tracker = ProgressTracker(now: now) }
    }

    private final class IncomingContext {
        let offer: TransferOffer
        var assembler: IncomingTransferAssembler?
        var destinationDirectory: URL?
        var progresses: [Int: Progress] = [:]
        var isFinalizing = false
        let tracker: ProgressTracker

        init(offer: TransferOffer, now: TimeInterval) {
            self.offer = offer
            tracker = ProgressTracker(now: now)
        }
    }

    init(transport: any PeerTransport,
         destination: any ReceivingDestination,
         preparer: @escaping @Sendable ([URL]) async throws -> PreparedTransfer = { try await FileTransferManager.prepare($0) },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport
        self.destination = destination
        self.preparer = preparer
        self.clock = clock
        transport.transferDelegate = self
    }

    func transfer(_ id: UUID) -> Transfer? {
        transfers.first { $0.id == id }
    }

    // MARK: - Outgoing

    /// Starts sending `urls` to `peer`. Returns the new transfer's ID immediately;
    /// preparation (folder expansion and hashing) continues in the background.
    @discardableResult
    func send(_ urls: [URL], to peer: PeerDevice) -> UUID {
        let id = UUID()
        var transfer = Transfer(id: id, direction: .outgoing, peerID: peer.id, peerName: peer.displayName,
                                peerTag: peer.shortTag, phase: .preparing, createdAt: .now)
        transfer.sourceURLs = urls
        transfers.insert(transfer, at: 0)

        let context = OutgoingContext(now: clock())
        context.scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        outgoing[id] = context

        let preparer = self.preparer
        context.preparation = Task { [weak self] in
            do {
                let prepared = try await preparer(urls)
                self?.didPrepare(id, prepared)
            } catch is CancellationError {
                // Cancelled by the user; the phase is already terminal.
            } catch {
                self?.preparationFailed(id, error)
            }
        }
        Log.transfer.info("Preparing outgoing transfer \(id, privacy: .public) with \(urls.count) item(s)")
        return id
    }

    /// Sends the same items again to the same peer as a new transfer.
    @discardableResult
    func retry(_ id: UUID) -> UUID? {
        guard let old = transfer(id), old.direction == .outgoing, old.phase.isTerminal, old.phase != .completed,
              !old.sourceURLs.isEmpty, let peer = transport.peer(for: old.peerID) else { return nil }
        dismiss(id)
        return send(old.sourceURLs, to: peer)
    }

    private func didPrepare(_ id: UUID, _ prepared: PreparedTransfer) {
        guard let context = outgoing[id], let index = index(of: id), transfers[index].phase == .preparing else { return }
        context.preparation = nil
        context.prepared = prepared
        transfers[index].files = prepared.files.enumerated().map { offset, file in
            TransferFile(index: offset, path: file.offered.path, size: file.offered.size,
                         typeIdentifier: file.offered.typeIdentifier)
        }
        transfers[index].totalBytes = prepared.totalBytes
        offerIfReady(id)
    }

    private func preparationFailed(_ id: UUID, _ error: Error) {
        let reason: FailureReason
        switch error as? PreparationError {
        case .tooManyFiles, .pathTooLong: reason = .tooManyFiles
        case .itemMissing: reason = .fileUnavailable
        case .unreadable: reason = .accessDenied
        default: reason = .fileUnavailable
        }
        setDetail(id, TransferMessages.preparationFailure(error))
        fail(id, reason, notifyPeer: false)
    }

    /// Sends the offer once the peer can receive it, waiting briefly for a connection.
    private func offerIfReady(_ id: UUID) {
        guard let transfer = transfer(id), transfer.phase == .preparing,
              let prepared = outgoing[id]?.prepared else { return }

        guard transport.peer(for: transfer.peerID)?.presence.canReceive == true else {
            if !timers.isScheduled(.connectionWait(id)) {
                timers.schedule(.connectionWait(id), after: connectionWaitTimeout) { [weak self] in
                    self?.fail(id, .peerUnavailable, notifyPeer: false)
                }
            }
            return
        }
        timers.cancel(.connectionWait(id))

        let offer = TransferOffer(transferID: id, files: prepared.files.map(\.offered), totalBytes: prepared.totalBytes)
        advance(id, to: .offering)
        do {
            try transport.send(.offer(offer), to: transfer.peerID)
        } catch ProtocolError.tooLarge {
            fail(id, .tooManyFiles, notifyPeer: false)
            return
        } catch {
            fail(id, .peerDisconnected, notifyPeer: false)
            return
        }
        advance(id, to: .awaitingAcceptance)
        // The recipient expires the offer first; this is a backstop if that message is lost.
        timers.schedule(.offerExpiry(id), after: offerTimeout + .seconds(5)) { [weak self] in
            self?.expireOutgoing(id)
        }
    }

    private func expireOutgoing(_ id: UUID) {
        guard let transfer = transfer(id), transfer.phase == .awaitingAcceptance else { return }
        try? transport.send(.cancel(transferID: id), to: transfer.peerID)
        advance(id, to: .expired)
    }

    private func handleAccept(_ id: UUID, from peerID: String) {
        guard let transfer = transfer(id), transfer.direction == .outgoing, transfer.peerID == peerID,
              transfer.phase == .awaitingAcceptance, let context = outgoing[id] else { return }
        timers.cancel(.offerExpiry(id))
        advance(id, to: .accepted)
        advance(id, to: .transferring)
        context.tracker.lastChange = clock()
        sendNextResource(id)
        ensureTicker()
    }

    /// Files are sent one at a time; empty files are skipped because the
    /// recipient creates them from the offer.
    private func sendNextResource(_ id: UUID) {
        guard let transfer = transfer(id), transfer.phase == .transferring,
              let context = outgoing[id], let prepared = context.prepared else { return }

        while context.nextIndex < prepared.files.count, prepared.files[context.nextIndex].offered.size == 0 {
            context.nextIndex += 1
        }
        guard context.nextIndex < prepared.files.count else {
            context.currentIndex = nil
            context.currentProgress = nil
            advance(id, to: .verifying)
            timers.schedule(.completion(id), after: completionTimeout) { [weak self] in
                self?.fail(id, .timedOut, notifyPeer: true)
            }
            return
        }

        let index = context.nextIndex
        let file = prepared.files[index]
        // The file must still be the one that was hashed and offered.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.sourceURL.path) else {
            fail(id, .fileUnavailable, notifyPeer: true)
            return
        }
        guard (attributes[.size] as? NSNumber)?.int64Value == file.offered.size else {
            fail(id, .fileChanged, notifyPeer: true)
            return
        }

        do {
            let name = ResourceName.make(transferID: id, index: index)
            context.currentProgress = try transport.sendResource(at: file.sourceURL, named: name, to: transfer.peerID) { [weak self] error in
                self?.resourceSent(id, index: index, error: error)
            }
            context.currentIndex = index
        } catch {
            fail(id, .peerDisconnected, notifyPeer: false)
        }
    }

    private func resourceSent(_ id: UUID, index: Int, error: Error?) {
        guard let transfer = transfer(id), transfer.phase == .transferring,
              let context = outgoing[id], context.currentIndex == index, let prepared = context.prepared else { return }
        if let error {
            Log.transfer.error("Sending file \(index) of \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            fail(id, .sendFailed, notifyPeer: true)
            return
        }
        context.completedBytes += prepared.files[index].offered.size
        context.currentIndex = nil
        context.currentProgress = nil
        context.nextIndex = index + 1
        sendNextResource(id)
    }

    private func handleDecline(_ id: UUID, reason: DeclineReason, from peerID: String) {
        guard let transfer = transfer(id), transfer.direction == .outgoing, transfer.peerID == peerID else { return }
        advance(id, to: reason == .expired ? .expired : .declined(reason))
    }

    private func handleComplete(_ id: UUID, from peerID: String) {
        guard let transfer = transfer(id), transfer.direction == .outgoing, transfer.peerID == peerID,
              transfer.phase.isMovingData, let index = index(of: id) else { return }
        // The recipient's acknowledgement is authoritative: every file was verified and saved.
        transfers[index].bytesTransferred = transfers[index].totalBytes
        advance(id, to: .completed)
    }

    // MARK: - Incoming

    private func handleOffer(_ offer: TransferOffer, from peerID: String) {
        let id = offer.transferID
        guard let peer = transport.peer(for: peerID) else { return }

        guard index(of: id) == nil, seenOfferIDs.insert(id) else {
            Log.transfer.error("Refused duplicate transfer ID \(id, privacy: .public)")
            try? transport.send(.failure(transferID: id, reason: .duplicateTransfer), to: peerID)
            return
        }
        do {
            try OfferValidator.validate(offer)
        } catch {
            Log.transfer.error("Refused invalid offer \(id, privacy: .public): \(String(describing: error), privacy: .private)")
            try? transport.send(.failure(transferID: id, reason: .validationFailed), to: peerID)
            return
        }
        let waiting = transfers.filter { $0.direction == .incoming && $0.peerID == peerID && $0.phase == .awaitingDecision }
        guard waiting.count < ProtocolLimits.maxPendingOffersPerPeer else {
            try? transport.send(.decline(transferID: id, reason: .busy), to: peerID)
            return
        }

        var transfer = Transfer(id: id, direction: .incoming, peerID: peerID, peerName: peer.displayName,
                                peerTag: peer.shortTag, phase: .awaitingDecision, createdAt: .now)
        transfer.files = offer.files.enumerated().map { offset, file in
            TransferFile(index: offset, path: file.path, size: file.size, typeIdentifier: file.typeIdentifier)
        }
        transfer.totalBytes = offer.totalBytes
        transfers.insert(transfer, at: 0)
        incoming[id] = IncomingContext(offer: offer, now: clock())

        timers.schedule(.offerExpiry(id), after: offerTimeout) { [weak self] in
            self?.expireIncoming(id)
        }
        Log.transfer.info("Incoming offer \(id, privacy: .public): \(offer.files.count) file(s), \(offer.totalBytes) bytes")
        onIncomingOffer?(transfer)
    }

    /// Accepts an incoming offer. Safe to call repeatedly; only the first call acts.
    func accept(_ id: UUID) {
        guard let transfer = transfer(id), transfer.direction == .incoming, transfer.phase == .awaitingDecision,
              let context = incoming[id] else { return }

        let directory: URL
        let assembler: IncomingTransferAssembler
        do {
            directory = try destination.prepareDestination(requiredBytes: transfer.totalBytes)
            assembler = try IncomingTransferAssembler(offer: context.offer, stagingRoot: destination.stagingRoot)
        } catch {
            let space = (error as? DestinationError)?.isSpaceProblem == true
                || (error as? CocoaError)?.code == .fileWriteOutOfSpace
            try? transport.send(.decline(transferID: id, reason: space ? .insufficientSpace : .destinationUnavailable),
                                to: transfer.peerID)
            setDetail(id, TransferMessages.destinationFailure(error))
            advance(id, to: .failed(space ? .insufficientSpace : .destinationUnavailable))
            return
        }

        context.assembler = assembler
        context.destinationDirectory = directory
        context.tracker.lastChange = clock()
        timers.cancel(.offerExpiry(id))
        advance(id, to: .accepted)
        do {
            try transport.send(.accept(transferID: id), to: transfer.peerID)
        } catch {
            fail(id, .peerDisconnected, notifyPeer: false)
            return
        }
        if assembler.isComplete {
            finalizeIncoming(id)
        } else {
            ensureTicker()
        }
    }

    /// Declines an incoming offer. Safe to call repeatedly.
    func decline(_ id: UUID) {
        guard let transfer = transfer(id), transfer.direction == .incoming, transfer.phase == .awaitingDecision else { return }
        try? transport.send(.decline(transferID: id, reason: .userDeclined), to: transfer.peerID)
        advance(id, to: .declined(.userDeclined))
    }

    private func expireIncoming(_ id: UUID) {
        guard let transfer = transfer(id), transfer.phase == .awaitingDecision else { return }
        try? transport.send(.decline(transferID: id, reason: .expired), to: transfer.peerID)
        advance(id, to: .expired)
    }

    private func resourceStarted(_ name: String, from peerID: String, progress: Progress) {
        guard let (id, index) = ResourceName.parse(name), let transfer = transfer(id),
              transfer.direction == .incoming, transfer.peerID == peerID,
              transfer.phase == .accepted || transfer.phase == .transferring,
              let context = incoming[id], let assembler = context.assembler,
              context.progresses[index] == nil, assembler.expectsResource(at: index) else {
            // Contents nobody accepted are refused and never written to the receiving folder.
            Log.transfer.error("Refused unexpected resource from peer")
            progress.cancel()
            return
        }
        context.progresses[index] = progress
        if transfer.phase == .accepted { advance(id, to: .transferring) }
        ensureTicker()
    }

    private func resourceFinished(_ name: String, from peerID: String, at url: URL?, error: Error?) {
        func discardFile() {
            if let url { try? FileManager.default.removeItem(at: url) }
        }
        guard let (id, index) = ResourceName.parse(name), let transfer = transfer(id),
              transfer.direction == .incoming, transfer.peerID == peerID,
              transfer.phase == .accepted || transfer.phase == .transferring,
              let context = incoming[id], let assembler = context.assembler,
              context.progresses[index] != nil || assembler.expectsResource(at: index) else {
            discardFile()
            return
        }
        context.progresses[index] = nil
        if let error {
            Log.transfer.error("Receiving file \(index) of \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
            discardFile()
            fail(id, .receiveFailed, notifyPeer: true)
            return
        }
        guard let url else {
            fail(id, .receiveFailed, notifyPeer: true)
            return
        }
        if transfer.phase == .accepted { advance(id, to: .transferring) }

        Task { [weak self] in
            var failure: Error?
            do {
                try await assembler.ingest(url, index: index)
            } catch {
                failure = error
            }
            guard let self else {
                assembler.discard()
                return
            }
            self.didIngest(id, assembler: assembler, failure: failure)
        }
    }

    private func didIngest(_ id: UUID, assembler: IncomingTransferAssembler, failure: Error?) {
        guard let context = incoming[id], context.assembler === assembler, transfer(id)?.phase.isActive == true else {
            // Cancelled or failed while this file was being verified.
            assembler.discard()
            return
        }
        if let failure {
            Log.transfer.error("Verification failed for \(id, privacy: .public): \(String(describing: failure), privacy: .private)")
            let reason: FailureReason = (failure as? CocoaError)?.code == .fileWriteOutOfSpace ? .insufficientSpace : .validationFailed
            fail(id, reason, notifyPeer: true)
            return
        }
        if assembler.isComplete { finalizeIncoming(id) }
    }

    private func finalizeIncoming(_ id: UUID) {
        guard let context = incoming[id], let assembler = context.assembler,
              let directory = context.destinationDirectory, !context.isFinalizing else { return }
        context.isFinalizing = true
        advance(id, to: .verifying)
        let handling = destination.duplicateHandling
        Task { [weak self] in
            do {
                let saved = try await assembler.finalize(into: directory, handling: handling)
                self?.didFinalize(id, saved: saved)
            } catch {
                Log.files.error("Saving \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .private)")
                let space = (error as? CocoaError)?.code == .fileWriteOutOfSpace
                self?.setDetail(id, TransferMessages.destinationFailure(error))
                self?.fail(id, space ? .insufficientSpace : .finalizeFailed, notifyPeer: true)
            }
        }
    }

    private func didFinalize(_ id: UUID, saved: [URL]) {
        guard let index = index(of: id) else { return }
        transfers[index].savedURLs = saved
        transfers[index].bytesTransferred = transfers[index].totalBytes
        // Acknowledge only now that every file is verified and in the receiving folder.
        try? transport.send(.complete(transferID: id), to: transfers[index].peerID)
        advance(id, to: .completed)
        Log.transfer.info("Saved incoming transfer \(id, privacy: .public)")
    }

    // MARK: - Both directions

    /// Cancels a transfer and tells the peer. Declines if the offer is still pending.
    func cancel(_ id: UUID) {
        guard let transfer = transfer(id), transfer.phase.isActive else { return }
        if transfer.direction == .incoming {
            if transfer.phase == .awaitingDecision {
                decline(id)
                return
            }
            // Files are verified and being moved into place; let that finish.
            if incoming[id]?.isFinalizing == true { return }
        }
        if transfer.phase != .preparing {
            try? transport.send(.cancel(transferID: id), to: transfer.peerID)
        }
        advance(id, to: .cancelled(.local))
    }

    /// Cancels everything in flight, e.g. when sharing is turned off or the app quits.
    func cancelAll() {
        for id in transfers.filter({ $0.phase.isActive }).map(\.id) {
            cancel(id)
        }
    }

    /// Removes a finished transfer from the list. History keeps its record.
    func dismiss(_ id: UUID) {
        guard let index = index(of: id), transfers[index].phase.isTerminal else { return }
        transfers.remove(at: index)
    }

    private func handleRemoteCancel(_ id: UUID, from peerID: String) {
        guard let transfer = transfer(id), transfer.peerID == peerID, transfer.phase.isActive else { return }
        if transfer.direction == .incoming, incoming[id]?.isFinalizing == true { return }
        advance(id, to: .cancelled(.remote))
    }

    private func handleRemoteFailure(_ id: UUID, reason: FailureReason, from peerID: String) {
        guard let transfer = transfer(id), transfer.peerID == peerID, transfer.phase.isActive else { return }
        if transfer.direction == .incoming, incoming[id]?.isFinalizing == true { return }
        advance(id, to: .failed(reason))
    }

    private func fail(_ id: UUID, _ reason: FailureReason, notifyPeer: Bool) {
        guard let transfer = transfer(id), transfer.phase.isActive else { return }
        if notifyPeer, transfer.phase != .preparing {
            try? transport.send(.failure(transferID: id, reason: reason), to: transfer.peerID)
        }
        advance(id, to: .failed(reason))
    }

    // MARK: - State machine

    @discardableResult
    private func advance(_ id: UUID, to phase: TransferPhase) -> Bool {
        guard let index = index(of: id) else { return false }
        let current = transfers[index].phase
        guard current.canTransition(to: phase) else {
            Log.transfer.debug("Ignored \(String(describing: current), privacy: .public) → \(String(describing: phase), privacy: .public)")
            return false
        }
        transfers[index].phase = phase
        guard phase.isTerminal else { return true }

        transfers[index].finishedAt = .now
        transfers[index].bytesPerSecond = nil
        transfers[index].secondsRemaining = nil
        if transfers[index].detail == nil {
            transfers[index].detail = TransferMessages.outcome(for: transfers[index])
        }
        tearDown(id, phase: phase)
        Log.transfer.info("Transfer \(id, privacy: .public) ended: \(String(describing: phase), privacy: .public)")
        onTransferFinished?(transfers[index])
        trimFinishedTransfers()
        return true
    }

    private func tearDown(_ id: UUID, phase: TransferPhase) {
        TimerKey.all(for: id).forEach(timers.cancel)
        if let context = outgoing.removeValue(forKey: id) {
            context.preparation?.cancel()
            if phase != .completed { context.currentProgress?.cancel() }
            context.scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        }
        if let context = incoming.removeValue(forKey: id) {
            context.progresses.values.forEach { $0.cancel() }
            context.assembler?.discard()
        }
    }

    private func trimFinishedTransfers() {
        var finished = 0
        transfers.removeAll { transfer in
            guard transfer.phase.isTerminal else { return false }
            finished += 1
            return finished > Self.maxFinishedTransfers
        }
    }

    private func index(of id: UUID) -> Int? {
        transfers.firstIndex { $0.id == id }
    }

    private func setDetail(_ id: UUID, _ detail: String?) {
        guard let index = index(of: id) else { return }
        transfers[index].detail = detail
    }

    // MARK: - Progress

    private func ensureTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self else { return }
                if !self.tick() {
                    self.ticker = nil
                    return
                }
            }
        }
    }

    /// Samples real progress from the transport, updates speed and time remaining,
    /// and fails transfers that stop moving. Returns false when nothing is active.
    private func tick() -> Bool {
        let now = clock()
        var anyActive = false
        var stalled: [UUID] = []

        for index in transfers.indices where transfers[index].phase.isMovingData {
            anyActive = true
            let id = transfers[index].id
            let total = transfers[index].totalBytes
            let bytes: Int64
            let tracker: ProgressTracker
            var mayStall = transfers[index].phase != .verifying

            if let context = outgoing[id] {
                var inFlight: Int64 = 0
                if let progress = context.currentProgress, let current = context.currentIndex,
                   let file = context.prepared?.files[current] {
                    inFlight = Int64(progress.fractionCompleted * Double(file.offered.size))
                }
                bytes = context.completedBytes + inFlight
                tracker = context.tracker
            } else if let context = incoming[id], let assembler = context.assembler {
                let inFlight = context.progresses.reduce(Int64(0)) { sum, entry in
                    sum + Int64(entry.value.fractionCompleted * Double(context.offer.files[entry.key].size))
                }
                bytes = assembler.verifiedBytes + inFlight
                tracker = context.tracker
                // Large files can take a while to hash after they arrive.
                if assembler.pendingVerificationCount > 0 { mayStall = false }
            } else {
                continue
            }

            let clamped = min(max(bytes, transfers[index].bytesTransferred), total)
            if clamped != transfers[index].bytesTransferred {
                transfers[index].bytesTransferred = clamped
            }
            tracker.estimator.record(bytes: clamped, at: now)
            let speed = tracker.estimator.bytesPerSecond
            if speed != transfers[index].bytesPerSecond { transfers[index].bytesPerSecond = speed }
            let remaining = tracker.estimator.secondsRemaining(totalBytes: total)
            if remaining != transfers[index].secondsRemaining { transfers[index].secondsRemaining = remaining }

            if clamped > tracker.lastBytes {
                tracker.lastBytes = clamped
                tracker.lastChange = now
            } else if mayStall, now - tracker.lastChange > stallTimeout {
                stalled.append(id)
            } else if !mayStall {
                tracker.lastChange = now
            }
        }

        for id in stalled {
            setDetail(id, TransferMessages.stalled)
            fail(id, .timedOut, notifyPeer: true)
        }
        return anyActive
    }
}

// MARK: - PeerTransportDelegate

extension TransferService: PeerTransportDelegate {
    func transport(didReceive message: ProtocolMessage, from peerID: String) {
        switch message {
        case .hello, .chat, .chatAck, .chatSync, .chatHistory, .chatReaction, .chatRead, .chatTyping,
             .avatar, .mediaRequest, .media, .updateAvailable, .updateRequest:
            break
        case .offer(let offer):
            handleOffer(offer, from: peerID)
        case .accept(let id):
            handleAccept(id, from: peerID)
        case .decline(let id, let reason):
            handleDecline(id, reason: reason, from: peerID)
        case .cancel(let id):
            handleRemoteCancel(id, from: peerID)
        case .complete(let id):
            handleComplete(id, from: peerID)
        case .failure(let id, let reason):
            handleRemoteFailure(id, reason: reason, from: peerID)
        }
    }

    func transport(didStartReceivingResourceNamed name: String, from peerID: String, progress: Progress) {
        resourceStarted(name, from: peerID, progress: progress)
    }

    func transport(didFinishReceivingResourceNamed name: String, from peerID: String, at url: URL?, error: Error?) {
        resourceFinished(name, from: peerID, at: url, error: error)
    }

    func transportPeerBecameReady(_ peerID: String) {
        for transfer in transfers where transfer.peerID == peerID && transfer.direction == .outgoing && transfer.phase == .preparing {
            offerIfReady(transfer.id)
        }
    }

    func transportPeerDisconnected(_ peerID: String) {
        let affected = transfers.filter { transfer in
            guard transfer.peerID == peerID, transfer.phase.isActive else { return false }
            // Still hashing: it will wait for the peer to come back.
            if transfer.direction == .outgoing, transfer.phase == .preparing { return false }
            // Already verified locally and being saved; finishing does not need the sender.
            if transfer.direction == .incoming, incoming[transfer.id]?.isFinalizing == true { return false }
            return true
        }
        for transfer in affected {
            fail(transfer.id, .peerDisconnected, notifyPeer: false)
        }
    }
}

#if DEBUG
extension TransferService {
    /// UI tests only: presents an offer without a network peer so the incoming
    /// window can be exercised. Accepting it fails honestly because nobody is connected.
    func injectOfferForUITesting(_ offer: TransferOffer, from peer: PeerDevice) {
        var transfer = Transfer(id: offer.transferID, direction: .incoming, peerID: peer.id, peerName: peer.displayName,
                                peerTag: peer.shortTag, phase: .awaitingDecision, createdAt: .now)
        transfer.files = offer.files.enumerated().map { offset, file in
            TransferFile(index: offset, path: file.path, size: file.size, typeIdentifier: file.typeIdentifier)
        }
        transfer.totalBytes = offer.totalBytes
        transfers.insert(transfer, at: 0)
        incoming[offer.transferID] = IncomingContext(offer: offer, now: clock())
        onIncomingOffer?(transfer)
    }
}
#endif
