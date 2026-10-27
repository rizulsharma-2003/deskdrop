import SwiftUI

/// A GIF or sticker in a conversation. GIFs sit in a rounded frame, like a photo
/// in Messages; stickers float on their own. GIPHY images download from GIPHY;
/// your colleagues' own stickers come from their Mac.
struct MediaMessageView: View {
    let message: ChatMessage
    let media: ChatMedia

    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var downloaded: NSImage?
    @State private var failed = false
    @State private var hovering = false
    @State private var attempt = 0

    private var isSticker: Bool { media.kind == .sticker }

    /// Fits the image in a box (smaller for stickers), keeping its shape.
    static func displaySize(for media: ChatMedia) -> CGSize {
        let box: CGFloat = media.kind == .sticker ? 150 : 250
        let width = CGFloat(max(media.width, 1))
        let height = CGFloat(max(media.height, 1))
        let scale = min(box / width, box / height, media.kind == .sticker ? 1 : 2)
        // Very thin images still get a usable size.
        return CGSize(width: max(60, (width * scale).rounded()), height: max(48, (height * scale).rounded()))
    }

    private var image: NSImage? {
        if let hash = media.hash { return model.library.image(for: hash) }
        return downloaded ?? media.url.flatMap(model.remoteImages.cachedImage(for:))
    }

    private var animates: Bool {
        !reduceMotion && (model.settings.autoplayGIFs || hovering)
    }

    var body: some View {
        let size = Self.displaySize(for: media)
        Group {
            if let image {
                AnimatedImageView(image: image, animates: animates)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: isSticker ? 0 : 16, style: .continuous))
                    .shadow(color: isSticker ? .black.opacity(0.18) : .clear, radius: 3, y: 1)
                    .transition(.opacity)
            } else {
                placeholder
                    .frame(width: size.width, height: size.height)
            }
        }
        .onHover { hovering = $0 }
        .task(id: attempt) { await load() }
        .accessibilityLabel(Text(accessibilityText))
    }

    private var placeholder: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return ZStack {
            shape.fill(Theme.incomingBubble.opacity(isSticker ? 0.5 : 1))
            if failed {
                Button {
                    failed = false
                    attempt += 1
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                        Text(isSticker ? "Sticker didn’t load" : "GIF didn’t load")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Try again"))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func load() async {
        if let hash = media.hash {
            // Ask the sender (now, or when they next connect) if it hasn't arrived.
            if !model.library.contains(hash), !message.isOutgoing {
                model.chat.media?.want(hash, from: message.senderID)
            }
            return
        }
        guard let url = media.url, downloaded == nil else { return }
        do {
            let image = try await model.remoteImages.image(for: url)
            withAnimation(Theme.Motion.gentle) { downloaded = image }
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }

    private var accessibilityText: String {
        let kind = isSticker ? String(localized: "Sticker") : String(localized: "GIF")
        guard let title = media.title, !title.isEmpty else { return kind }
        return "\(kind), \(title)"
    }
}
