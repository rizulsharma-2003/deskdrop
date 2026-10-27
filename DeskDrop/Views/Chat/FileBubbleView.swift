import AppKit
import QuickLook
import SwiftUI

/// A file transfer in a conversation, like an attachment in Messages: a preview
/// or icon, the name and size, live progress, and what you can do next (accept,
/// open, show in Finder, cancel, try again). Click to preview with Quick Look,
/// double-click to open, or drag it out to Finder.
struct FileBubbleView: View {
    let file: ConversationFile
    let peerName: String

    @Environment(DeskDropViewModel.self) private var model
    @State private var previewURL: URL?

    private var outgoing: Bool { file.isOutgoing }

    var body: some View {
        HStack(spacing: 0) {
            if outgoing { Spacer(minLength: 60) }
            card
            if !outgoing { Spacer(minLength: 60) }
        }
        .padding(.vertical, 4)
        .quickLookPreview($previewURL)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if file.isImage, let url = file.fileURL {
                FileIconView(source: .file(url), size: 232)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 10) {
                FileIconView(source: iconSource, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(sizeLine)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryStyle)
                }
                Spacer(minLength: 0)
            }
            status
            actions
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .foregroundStyle(outgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(outgoing ? Theme.messageBlue : Theme.incomingBubble))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture(count: 2) { open() }
        .onTapGesture { quickLook() }
        .onDrag { dragProvider() }
        .contextMenu { menu }
        .help(file.fileURL == nil ? "" : String(localized: "Click to preview, double-click to open"))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityIdentifier("chatFile")
    }

    // MARK: - Text

    private var iconSource: FileIconView.Source {
        file.fileURL.map(FileIconView.Source.file) ?? .type(file.typeIdentifier, isFolder: file.isFolder)
    }

    private var sizeLine: String {
        let size = FileSizeFormatter.string(fromBytes: file.totalBytes)
        guard file.fileCount > 1 else { return size }
        return "\(size) · " + String(localized: "\(file.fileCount) files")
    }

    private var secondaryStyle: AnyShapeStyle {
        outgoing ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private var status: some View {
        if let transfer = file.transfer, transfer.phase == .transferring || transfer.phase == .accepted {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: transfer.fractionCompleted)
                    .progressViewStyle(.linear)
                    .tint(outgoing ? .white : Theme.messageBlue)
                Text(progressLine(transfer))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(secondaryStyle)
            }
            .accessibilityElement(children: .combine)
        } else {
            Label(statusText, systemImage: statusSymbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(statusStyle)
                .lineLimit(2)
        }
    }

    private func progressLine(_ transfer: Transfer) -> String {
        var line = FileSizeFormatter.progress(transfer.bytesTransferred, of: transfer.totalBytes)
        if let seconds = transfer.secondsRemaining, let remaining = FileSizeFormatter.timeRemaining(seconds: seconds) {
            line += " · \(remaining)"
        }
        return line
    }

    private var statusText: String {
        switch file.phase {
        case .preparing: return String(localized: "Preparing…")
        case .offering, .awaitingAcceptance: return String(localized: "Waiting for \(peerName) to accept")
        case .awaitingDecision: return String(localized: "\(peerName) wants to send you this")
        case .accepted, .transferring: return String(localized: "Sending…")
        case .verifying: return String(localized: "Checking…")
        case .completed:
            if outgoing { return String(localized: "Delivered") }
            return file.fileURL == nil && file.transfer == nil ? String(localized: "Received")
                                                               : String(localized: "Saved")
        case .declined, .cancelled, .failed, .expired:
            // History only knows the outcome, so its saved explanation is the best text.
            if let detail = file.detail {
                return detail.hasSuffix(".") ? String(detail.dropLast()) : detail
            }
            switch file.phase {
            case .declined: return outgoing ? String(localized: "\(peerName) declined") : String(localized: "You declined")
            case .expired: return String(localized: "Not answered in time")
            case .cancelled: return String(localized: "Cancelled")
            default: return String(localized: "Didn’t go through")
            }
        }
    }

    private var statusSymbol: String {
        switch file.phase {
        case .completed: outgoing ? "checkmark.circle.fill" : "arrow.down.circle.fill"
        case .awaitingDecision: "tray.and.arrow.down"
        case .offering, .awaitingAcceptance, .preparing: "clock"
        case .verifying: "checkmark.shield"
        case .declined, .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .expired: "clock.badge.exclamationmark"
        case .accepted, .transferring: "arrow.left.arrow.right"
        }
    }

    private var statusStyle: AnyShapeStyle {
        switch file.phase {
        case .failed: outgoing ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.danger)
        case .completed where !outgoing: AnyShapeStyle(Theme.success)
        default: secondaryStyle
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        let transfer = file.transfer
        HStack(spacing: 6) {
            switch file.phase {
            case .awaitingDecision:
                if let transfer {
                    Button("Decline") { model.decline(transfer.id) }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                        .accessibilityIdentifier("chatFileDecline")
                    Button("Accept") { model.accept(transfer.id) }
                        .buttonStyle(PrimaryButtonStyle(compact: true))
                        .accessibilityIdentifier("chatFileAccept")
                }
            case .completed where !outgoing && (file.fileURL != nil || transfer != nil):
                Button("Open", action: open)
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Show in Finder", action: reveal)
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            case _ where file.phase.isActive && !(file.phase == .verifying && !outgoing):
                if let transfer {
                    Button("Cancel") { model.cancel(transfer.id) }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            case _ where file.phase.isTerminal:
                if let transfer, model.canRetry(transfer) {
                    Button("Try Again") { model.retry(transfer.id) }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            default:
                EmptyView()
            }
        }
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var menu: some View {
        if file.fileURL != nil {
            Button("Quick Look", action: quickLook)
            Button("Open", action: open)
            Button("Show in Finder", action: reveal)
            Button("Copy") {
                guard let url = file.fileURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
        } else if !outgoing, file.phase == .completed, file.transfer != nil {
            Button("Show in Finder", action: reveal)
        }
    }

    private func quickLook() {
        guard let url = file.fileURL else { return }
        previewURL = url
    }

    private func open() {
        if let transfer = file.transfer, !outgoing, transfer.phase == .completed {
            model.open(transfer)
        } else if let url = file.fileURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func reveal() {
        if let transfer = file.transfer, !outgoing, transfer.phase == .completed {
            model.revealInFinder(transfer)
        } else if let url = file.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func dragProvider() -> NSItemProvider {
        guard let url = file.fileURL, let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    private var accessibilityText: String {
        let who = outgoing ? String(localized: "You sent") : String(localized: "\(peerName) sent")
        return "\(who) \(file.title), \(sizeLine), \(statusText)"
    }
}

/// "…" in a grey bubble while a colleague types, as in Messages.
struct TypingIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 7, height: 7)
                            .opacity(reduceMotion ? 0.6 : dotOpacity(index: index, time: time))
                            .offset(y: reduceMotion ? 0 : -2 * dotLift(index: index, time: time))
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(BubbleShape(isOutgoing: false, hasTail: true).fill(Theme.incomingBubble))
            Spacer(minLength: 60)
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Typing"))
        .accessibilityIdentifier("typingIndicator")
    }

    /// Each dot pulses in turn, a third of a cycle apart.
    private func dotLift(index: Int, time: TimeInterval) -> Double {
        max(0, sin((time / 1.2) * 2 * .pi - Double(index) * 0.9))
    }

    private func dotOpacity(index: Int, time: TimeInterval) -> Double {
        0.35 + 0.65 * dotLift(index: index, time: time)
    }
}
