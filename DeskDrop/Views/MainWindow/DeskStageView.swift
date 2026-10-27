import SwiftUI

/// The heart of DeskDrop: your Mac and nearby colleagues side by side. Drop files
/// from Finder on a colleague to send them.
struct DeskStageView: View {
    static let localID = "deskdrop.local"

    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var targetedID: String?
    @State private var flights: [Flight] = []
    @State private var arrivals: [String: Int] = [:]

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 28) {
                    localCard
                    if model.peers.isEmpty {
                        EmptyStateView(status: model.networkStatus)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else {
                        ForEach(model.peers) { peer in
                            peerCard(peer)
                                .transition(.asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity),
                                                        removal: .opacity))
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
        }
        .animation(Theme.Motion.spring, value: model.peers.map(\.id))
        .overlayPreferenceValue(CardBoundsKey.self) { anchors in
            GeometryReader { proxy in
                TransferFlightOverlay(flights: flights,
                                      targetedPeerID: targetedID == Self.localID ? nil : targetedID,
                                      frames: anchors.mapValues { proxy[$0] },
                                      originID: Self.localID,
                                      onLanded: landed)
            }
        }
    }

    private var localCard: some View {
        DeviceCardView(content: .local(name: model.settings.displayName, kind: model.localDeviceKind,
                                       isSharing: model.isSharingEnabled),
                       isTargeted: targetedID == Self.localID,
                       photo: model.profilePhoto)
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(isTargeted: targetBinding(Self.localID),
                                                               acceptsDrop: false, onDrop: { _ in }))
            .contextMenu {
                Button(model.profilePhoto == nil ? "Add Profile Photo…" : "Change Profile Photo…") {
                    model.chooseProfilePhoto()
                }
                if model.profilePhoto != nil {
                    Button("Remove Profile Photo", role: .destructive) { model.setProfilePhoto(data: nil) }
                }
            }
            .anchorPreference(key: CardBoundsKey.self, value: .bounds) { [Self.localID: $0] }
    }

    private func peerCard(_ peer: PeerDevice) -> some View {
        let canSend: Bool = if case .incompatible = peer.presence { false } else { true }
        return DeviceCardView(content: .peer(peer),
                              activity: model.activity(for: peer.id),
                              isTargeted: targetedID == peer.id,
                              arrivalCount: arrivals[peer.id, default: 0],
                              edges: model.edges(assignedTo: peer.id),
                              photo: model.photo(forPeer: peer.id))
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(isTargeted: targetBinding(peer.id), acceptsDrop: canSend) { urls in
                send(urls, to: peer)
            })
            .onTapGesture { chooseFiles(for: peer) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { chooseFiles(for: peer) }
            .accessibilityAction(named: Text("Send Files…")) { chooseFiles(for: peer) }
            .contextMenu {
                Button("Send Files…") { chooseFiles(for: peer) }
                    .disabled(!canSend)
                Button("Message \(peer.displayName)…") {
                    model.showMessages(.direct(peer.id))
                }
                if peer.presence == .unavailable {
                    Button("Try Connecting Again") { model.connection.reconnect(peer.id) }
                }
                Divider()
                ForEach(ScreenEdge.allCases) { edge in
                    if model.edges(assignedTo: peer.id).contains(edge) {
                        Button("Remove from \(edge.title)") { model.clearEdge(edge) }
                    } else {
                        Button("Assign to \(edge.title)") { model.assign(peer.id, to: edge) }
                    }
                }
            }
            .help(canSend ? "Drop files here, or click to choose files for \(peer.displayName)" : "\(peer.displayName) runs an incompatible version of DeskDrop")
            .anchorPreference(key: CardBoundsKey.self, value: .bounds) { [peer.id: $0] }
    }

    private func targetBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { targetedID == id },
            set: { isTargeted in
                if isTargeted {
                    targetedID = id
                } else if targetedID == id {
                    targetedID = nil
                }
            }
        )
    }

    private func chooseFiles(for peer: PeerDevice) {
        if case .incompatible = peer.presence { return }
        model.chooseFilesAndSend(to: peer.id) { urls in
            throwFiles(urls, to: peer.id)
        }
    }

    private func send(_ urls: [URL], to peer: PeerDevice) {
        model.send(urls, to: peer.id)
        throwFiles(urls, to: peer.id)
    }

    /// Starts the visual throw. The network transfer has already been started and
    /// runs independently; landing does not mean delivered.
    private func throwFiles(_ urls: [URL], to peerID: String) {
        guard let first = urls.first else { return }
        if reduceMotion {
            arrivals[peerID, default: 0] += 1
            return
        }
        flights.removeAll { Date.now.timeIntervalSince($0.createdAt) > 3 }
        flights.append(Flight(peerID: peerID, icon: .file(first), itemCount: urls.count))
    }

    private func landed(_ flight: Flight) {
        flights.removeAll { $0.id == flight.id }
        arrivals[flight.peerID, default: 0] += 1
    }
}
