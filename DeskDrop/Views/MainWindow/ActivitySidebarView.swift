import SwiftUI

/// The Nearby sidebar, on glass like the conversation list in Messages: transfers
/// happening now, then recent activity. Everything older is in Recent Activity.
struct ActivitySidebarView: View {
    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Keeps the list quick to scan; the rest is in the Recent Activity window.
    private static let maxRecent = 40

    var body: some View {
        let live = model.transfers.transfers.filter { $0.phase.isActive }
        let recent = Array(model.history.entries.prefix(Self.maxRecent))
        VStack(spacing: 0) {
            header
            if live.isEmpty && recent.isEmpty {
                placeholder
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !live.isEmpty {
                            sectionTitle("Now")
                            ForEach(live) { transfer in
                                TransferRowView(transfer: transfer)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        if !recent.isEmpty {
                            sectionTitle("Recent")
                            ForEach(recent) { entry in
                                RecentActivityRow(entry: entry)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
                .softScrollEdges(.top)
            }
        }
        .animation(Theme.Motion.spring, value: live.map(\.id))
        .animation(Theme.Motion.spring, value: recent.first?.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activitySidebar")
    }

    // Lines up with the search field at the top of the Messages sidebar.
    private var header: some View {
        HStack {
            Text("Activity")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            Button("See All") { openWindow(id: SceneID.history) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .help("Open Recent Activity")
                .accessibilityIdentifier("seeAllActivityButton")
        }
        .frame(height: 32)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No transfers yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Files you send and receive appear here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A transfer in progress, with real progress and the actions that make sense
/// right now. Once it ends it moves to Recent.
struct TransferRowView: View {
    let transfer: Transfer
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            FileIconView(source: transfer.iconSource, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(transfer.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if canCancel {
                        Button { model.cancel(transfer.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(IconButtonStyle(size: 22))
                            .help("Cancel Transfer")
                            .accessibilityLabel(Text("Cancel Transfer"))
                    }
                }
                PeerLine(direction: transfer.direction, peerName: transfer.peerName)
                if transfer.phase.isMovingData {
                    TransferProgressView(transfer: transfer)
                } else {
                    Text(statusLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if transfer.phase == .awaitingDecision {
                    HStack(spacing: 6) {
                        Button("Decline") { model.decline(transfer.id) }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                        Button("Accept") { model.accept(transfer.id) }
                            .buttonStyle(PrimaryButtonStyle(compact: true))
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        // Already on glass, so a tinted card rather than more glass.
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transferRow")
    }

    private var canCancel: Bool {
        switch transfer.phase {
        case .awaitingDecision: false
        case .verifying: transfer.direction == .outgoing
        default: true
        }
    }

    private var statusLine: String {
        let size = FileSizeFormatter.string(fromBytes: transfer.totalBytes)
        switch transfer.phase {
        case .preparing: return String(localized: "Preparing…")
        case .offering, .awaitingAcceptance: return String(localized: "Waiting for \(transfer.peerName) to accept · \(size)")
        case .awaitingDecision: return String(localized: "Wants to send you \(transfer.fileCountDescription) · \(size)")
        default: return transfer.detail ?? ""
        }
    }
}

/// A finished transfer: what, with whom, when, and how it ended. Hovering shows
/// Show in Finder (for what you received) or Try Again (if it can be retried).
private struct RecentActivityRow: View {
    let entry: HistoryEntry
    @Environment(DeskDropViewModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(source: iconSource, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    PeerLine(direction: entry.direction, peerName: entry.peerName)
                    if let outcome {
                        Text("· \(outcome.text)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(outcome.color)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if isHovering, canReveal || retryable != nil {
                actions
            } else {
                Text(entry.date.chatListString())
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(isHovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(Theme.Motion.gentle, value: isHovering)
        .onTapGesture(count: 2) { if canReveal { model.revealHistoryItem(entry) } }
        .contextMenu {
            if canReveal {
                Button("Show in Finder") { model.revealHistoryItem(entry) }
            }
            if let retryable {
                Button("Try Again") { model.retry(retryable.id) }
            }
        }
        .help(entry.detail ?? entry.title)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Show in Finder")) { if canReveal { model.revealHistoryItem(entry) } }
        .accessibilityIdentifier("recentActivityRow")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            if let retryable {
                Button { model.retry(retryable.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Try Again")
                    .accessibilityLabel(Text("Try Again"))
            }
            if canReveal {
                Button { model.revealHistoryItem(entry) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(IconButtonStyle(size: 24))
                    .help("Show in Finder")
                    .accessibilityLabel(Text("Show in Finder"))
            }
        }
        .transition(.opacity)
    }

    private var canReveal: Bool {
        entry.direction == .incoming && entry.outcome == .completed && entry.savedPath != nil
    }

    /// The transfer itself, while DeskDrop still has it and it can be tried again.
    private var retryable: Transfer? {
        guard entry.outcome != .completed,
              let transfer = model.transfers.transfers.first(where: { $0.id == entry.id }),
              model.canRetry(transfer) else { return nil }
        return transfer
    }

    /// Something you received shows its real icon or thumbnail while it's still there.
    private var iconSource: FileIconView.Source {
        if canReveal, let path = entry.savedPath, FileManager.default.fileExists(atPath: path) {
            return .file(URL(fileURLWithPath: path))
        }
        return .type(entry.typeIdentifier, isFolder: entry.isFolder ?? false)
    }

    private var outcome: (text: String, color: Color)? {
        switch entry.outcome {
        case .completed: nil
        case .declined: (String(localized: "Declined"), .secondary)
        case .cancelled: (String(localized: "Cancelled"), .secondary)
        case .failed: (String(localized: "Failed"), Theme.danger)
        case .expired: (String(localized: "Expired"), Theme.warning)
        }
    }
}

/// "To Alex" or "From Alex", with an arrow showing which way it went.
private struct PeerLine: View {
    let direction: TransferDirection
    let peerName: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: direction == .outgoing ? "arrow.up.right" : "arrow.down.left")
                .font(.system(size: 8.5, weight: .bold))
            Text(direction == .outgoing ? "To \(peerName)" : "From \(peerName)")
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }
}
