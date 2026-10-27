import SwiftUI

/// A link's preview under its message, like a rich link in Messages: the page's
/// image, then its title and site. Click to open the link; hover to see where it goes.
struct LinkPreviewCard: View {
    let url: URL
    /// Nil while your Mac is still making it.
    let preview: LinkPreview?
    let isLoading: Bool
    /// Who to ask for the images if they haven't arrived.
    let senderID: String
    let isOutgoing: Bool

    @Environment(DeskDropViewModel.self) private var model
    @State private var lastOpened = Date.distantPast

    static let width: CGFloat = 270

    private var host: String { LinkPreview(url: url).host }

    private var title: String {
        if let title = preview?.title { return title }
        return isLoading ? String(localized: "Loading preview…") : host
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if let preview, let hash = preview.imageHash, let width = preview.imageWidth, let height = preview.imageHeight {
                Group {
                    if let image = model.library.image(for: hash) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } else {
                        Rectangle().fill(Theme.incomingBubble.opacity(0.5))
                    }
                }
                .frame(width: Self.width, height: max(80, min(Self.width * CGFloat(height) / CGFloat(width), 200)))
                .clipped()
            }
            HStack(alignment: .center, spacing: 9) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else if preview?.imageHash == nil, let icon = preview?.iconHash.flatMap(model.library.image(for:)) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: host)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: Self.width, alignment: .leading)
            .background(Theme.incomingBubble)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline))
        .contentShape(shape)
        .onTapGesture(perform: open)
        .help(url.absoluteString)
        .contextMenu {
            Button("Open Link", action: open)
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        .task(id: preview?.imageHashes) {
            // Ask the sender for images that haven't arrived (now, or when they connect).
            guard !isOutgoing else { return }
            for hash in preview?.imageHashes ?? [] where !model.library.contains(hash) {
                model.chat.media?.want(hash, from: senderID)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Link: \(title), \(host)"))
        .accessibilityAddTraits(.isLink)
        .accessibilityAction { open() }
    }

    /// Opens the link once per click, even if the click was a double-click.
    private func open() {
        guard Date.now.timeIntervalSince(lastOpened) > 1 else { return }
        lastOpened = .now
        NSWorkspace.shared.open(url)
    }
}
