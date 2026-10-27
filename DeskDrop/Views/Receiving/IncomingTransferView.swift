import SwiftUI

/// Content of the floating incoming-transfer panel: the current request or
/// transfer, with any others queued behind it.
struct IncomingPanelView: View {
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            if let transfer = model.currentPanelTransfer {
                IncomingTransferView(transfer: transfer,
                                     queuedCount: model.pendingIncoming.filter { $0.id != transfer.id }.count)
                    .id(transfer.id)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .frame(width: IncomingPanelController.size.width, height: IncomingPanelController.size.height, alignment: .top)
        .animation(Theme.Motion.spring, value: model.currentPanelTransfer?.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("incomingPanel")
    }
}

/// An incoming transfer from the moment it is offered until it is saved.
struct IncomingTransferView: View {
    let transfer: Transfer
    let queuedCount: Int

    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                FileIconView(source: transfer.iconSource, size: 54)
                    .shadow(color: Theme.accent.opacity(arrived ? 0.25 : 0.6), radius: arrived ? 6 : 16)
                    .offset(y: arrived ? 0 : -28)
                    .scaleEffect(arrived ? 1 : 0.6)
                    .opacity(arrived ? 1 : 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(transfer.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("incomingTitle")
                    Text("\(FileSizeFormatter.string(fromBytes: transfer.totalBytes)) · \(transfer.fileCountDescription)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("From \(transfer.peerName) · Device ID \(transfer.peerTag)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .accessibilityIdentifier("incomingSender")
                }
                Spacer(minLength: 0)
                if transfer.phase.isTerminal {
                    Button { model.dismissFromPanel(transfer.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 24))
                        .accessibilityLabel(Text("Close"))
                        .accessibilityIdentifier("closeIncoming")
                }
            }

            footer
        }
        .padding(18)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.68).delay(0.05)) {
                arrived = true
            }
        }
    }

    private var headline: String {
        switch transfer.phase {
        case .awaitingDecision: String(localized: "\(transfer.peerName) wants to send you")
        case .completed: String(localized: "Received from \(transfer.peerName)")
        case .accepted, .transferring, .verifying: String(localized: "Receiving from \(transfer.peerName)")
        default: String(localized: "From \(transfer.peerName)")
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch transfer.phase {
        case .awaitingDecision:
            HStack(spacing: 8) {
                if queuedCount > 0 {
                    Text("+\(queuedCount) more waiting")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("queuedCount")
                }
                Spacer()
                Button("Decline") { model.decline(transfer.id) }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("declineButton")
                Button("Accept") { model.accept(transfer.id) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("acceptButton")
            }

        case .accepted, .transferring, .verifying:
            VStack(alignment: .leading, spacing: 8) {
                TransferProgressView(transfer: transfer)
                HStack {
                    Text("Saving to \(URL(fileURLWithPath: model.receivingFolderPath).lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if transfer.phase != .verifying {
                        Button("Cancel") { model.cancel(transfer.id) }
                            .buttonStyle(SecondaryButtonStyle(compact: true))
                            .accessibilityIdentifier("cancelIncoming")
                    }
                }
            }

        case .completed:
            HStack(spacing: 8) {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.success)
                Spacer()
                Button("Show in Finder") { model.revealInFinder(transfer) }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                if transfer.savedURLs.count == 1, !transfer.isSingleFolder {
                    Button("Open") { model.open(transfer) }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                }
            }

        default:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: outcomeSymbol)
                    .foregroundStyle(outcomeColor)
                Text(transfer.detail ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("incomingOutcome")
                Spacer()
            }
        }
    }

    private var outcomeSymbol: String {
        switch transfer.phase {
        case .failed: "exclamationmark.triangle.fill"
        case .expired: "clock.badge.xmark"
        default: "xmark.circle"
        }
    }

    private var outcomeColor: Color {
        switch transfer.phase {
        case .failed: Theme.danger
        case .expired: Theme.warning
        default: .secondary
        }
    }
}
