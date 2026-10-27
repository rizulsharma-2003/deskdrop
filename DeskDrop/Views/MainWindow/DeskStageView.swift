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
            ScrollView(.vertical, showsIndicators: false) {
                CenteredFlowLayout(spacing: 24) {
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
                .padding(.horizontal, 28)
                // Clear of the title above and the hint floating below.
                .padding(.top, 76)
                .padding(.bottom, 68)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .softScrollEdges([.top, .bottom])
        }
        .overlay(alignment: .top) { titleBar }
        .overlay(alignment: .bottom) {
            if !model.peers.isEmpty {
                dropHint
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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

    /// A large title and how many colleagues are around, with a glass refresh
    /// button floating at the other end.
    private var titleBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Nearby")
                    .font(.system(size: 22, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(GlassIconButtonStyle(size: 32))
            .help("Look for Colleagues Again")
            .accessibilityLabel(Text("Look for Colleagues Again"))
            .accessibilityIdentifier("stageRefreshButton")
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }

    private var subtitle: String {
        let peers = model.peers
        if peers.isEmpty { return model.networkStatus.title }
        let available = peers.filter { $0.presence == .ready }.count
        let people = peers.count == 1 ? String(localized: "1 colleague") : String(localized: "\(peers.count) colleagues")
        return String(localized: "\(people) · \(available) available")
    }

    /// How to send, floating over the bottom of the stage like the message field.
    private var dropHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 11.5, weight: .medium))
            Text("Drop files on a Mac to send them, or click it to choose files.")
                .font(.system(size: 12))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 15)
        .frame(height: 34)
        .liquidGlass(in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
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

/// Lays the Macs out in rows, each centred, wrapping onto a new row when the
/// stage is too narrow for the next one.
private struct CenteredFlowLayout: Layout {
    var spacing: CGFloat

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, fitting: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        if let proposed = proposal.width, proposed.isFinite { return CGSize(width: max(proposed, width), height: height) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, fitting: bounds.width) {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(of subviews: Subviews, fitting width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widened = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, widened > width {
                rows.append(row)
                row = Row(indices: [index], width: size.width, height: size.height)
            } else {
                row.indices.append(index)
                row.width = widened
                row.height = max(row.height, size.height)
            }
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
