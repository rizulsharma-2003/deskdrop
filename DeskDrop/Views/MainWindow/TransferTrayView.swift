import SwiftUI

/// Active and recently finished transfers, under the stage.
struct TransferTrayView: View {
    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// Keeps the stage roomy; older items live in Recent Activity.
    private static let maxVisible = 4

    var body: some View {
        let all = model.transfers.transfers
        let ordered = all.filter { $0.phase.isActive } + all.filter { $0.phase.isTerminal }
        let items = Array(ordered.prefix(Self.maxVisible))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Transfers")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if ordered.count > items.count {
                        Button("\(ordered.count - items.count) more in Recent Activity") {
                            openWindow(id: SceneID.history)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    if items.contains(where: { $0.phase.isTerminal }) {
                        Button("Clear Finished") {
                            for transfer in model.transfers.transfers where transfer.phase.isTerminal {
                                model.dismiss(transfer.id)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    }
                }
                VStack(spacing: 6) {
                    ForEach(items) { transfer in
                        TransferRowView(transfer: transfer)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
            .animation(Theme.Motion.spring, value: items.map(\.id))
        }
    }
}

/// One transfer with real progress and the actions that make sense right now.
struct TransferRowView: View {
    let transfer: Transfer
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            FileIconView(source: transfer.iconSource, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: transfer.direction == .outgoing ? "arrow.up.right" : "arrow.down.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(transfer.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(transfer.direction == .outgoing ? "To \(transfer.peerName)" : "From \(transfer.peerName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if transfer.phase.isMovingData {
                    TransferProgressView(transfer: transfer)
                } else {
                    Text(statusLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
            }
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassBackground(cornerRadius: Theme.Radius.row)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transferRow")
    }

    private var statusLine: String {
        let size = FileSizeFormatter.string(fromBytes: transfer.totalBytes)
        switch transfer.phase {
        case .preparing: return String(localized: "Preparing…")
        case .offering, .awaitingAcceptance: return String(localized: "Waiting for \(transfer.peerName) to accept · \(size)")
        case .awaitingDecision: return String(localized: "Wants to send you \(transfer.fileCountDescription) · \(size)")
        case .completed:
            if transfer.direction == .incoming, let folder = transfer.savedURLs.first?.deletingLastPathComponent().lastPathComponent {
                return String(localized: "Saved to \(folder) · \(size)")
            }
            return String(localized: "Delivered · \(size)")
        default:
            return transfer.detail ?? ""
        }
    }

    private var statusColor: Color {
        switch transfer.phase {
        case .completed: Theme.success
        case .failed: Theme.danger
        case .expired: Theme.warning
        default: .secondary
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            switch transfer.phase {
            case .awaitingDecision:
                Button("Decline") { model.decline(transfer.id) }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Accept") { model.accept(transfer.id) }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
            case .completed where transfer.direction == .incoming:
                Button { model.revealInFinder(transfer) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help("Show in Finder")
                    .accessibilityLabel(Text("Show in Finder"))
                dismissButton
            case _ where transfer.phase.isTerminal:
                if model.canRetry(transfer) {
                    Button { model.retry(transfer.id) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle(size: 26))
                        .help("Try Again")
                        .accessibilityLabel(Text("Try Again"))
                }
                dismissButton
            case .verifying where transfer.direction == .incoming:
                EmptyView()
            default:
                Button { model.cancel(transfer.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help("Cancel Transfer")
                    .accessibilityLabel(Text("Cancel Transfer"))
            }
        }
    }

    private var dismissButton: some View {
        Button { model.dismiss(transfer.id) } label: { Image(systemName: "xmark") }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("Remove from List")
            .accessibilityLabel(Text("Remove from List"))
    }
}
