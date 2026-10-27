import SwiftUI

/// A round avatar: a colleague's profile photo (or their initials), or a group
/// glyph for everyone nearby.
struct ChatAvatar: View {
    let conversation: ConversationID
    let name: String
    var presence: PeerPresence?
    var size: CGFloat = 34

    @Environment(DeskDropViewModel.self) private var model

    /// Each colleague gets a stable pair of colors derived from their ID.
    private var colors: [Color] {
        if conversation.isCommunity { return [Theme.accent, Theme.violet] }
        let pairs: [[Color]] = [[Theme.cyan, Theme.accent], [Theme.violet, Theme.pink], [Theme.accent, Theme.violet],
                                [Theme.pink, Theme.warning], [Theme.success, Theme.cyan]]
        let seed = conversation.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return pairs[seed % pairs.count]
    }

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            if let photo = conversation.peerID.flatMap(model.photo(forPeer:)) {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .transition(.opacity)
            } else if conversation.isCommunity {
                Image(systemName: "person.3.fill")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(PeerDevice.initials(for: name).isEmpty ? "?" : PeerDevice.initials(for: name))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let presence {
                Circle()
                    .fill(presence == .ready ? Theme.success : Color.secondary)
                    .frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().strokeBorder(Theme.backgroundTop, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

/// One row of a conversation: a centred timestamp, a message or a file.
enum ChatRow: Identifiable, Equatable {
    case time(Date)
    /// `startsRun`/`endsRun`: first/last consecutive message from the same person.
    case message(ChatMessage, startsRun: Bool, endsRun: Bool)
    case file(ConversationFile)

    var id: String {
        switch self {
        case .time(let date): "time-\(date.timeIntervalSinceReferenceDate)"
        case .message(let message, _, _): message.id.uuidString
        case .file(let file): "file-\(file.id.uuidString)"
        }
    }

    private enum Item {
        case message(ChatMessage)
        case file(ConversationFile)

        var date: Date {
            switch self {
            case .message(let message): message.sentAt
            case .file(let file): file.date
            }
        }
    }

    /// As in Messages: a timestamp before the first item and after any gap of
    /// 15 minutes or more. Message runs break when the sender changes, a minute
    /// passes, or a file comes in between. Files sit at the time they were offered.
    static func rows(for messages: [ChatMessage], files: [ConversationFile] = []) -> [ChatRow] {
        // Stable merge by time: on a tie, the original order (messages first) wins.
        let items = (messages.map(Item.message) + files.map(Item.file))
            .enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
        func sameRun(_ a: Item?, _ b: Item?) -> Bool {
            guard case .message(let first)? = a, case .message(let second)? = b else { return false }
            return first.senderID == second.senderID && second.sentAt.timeIntervalSince(first.sentAt) < 60
        }
        var rows: [ChatRow] = []
        for (index, item) in items.enumerated() {
            let previous = index > 0 ? items[index - 1] : nil
            let next = index + 1 < items.count ? items[index + 1] : nil
            let showsTime = previous.map { item.date.timeIntervalSince($0.date) >= 900 } ?? true
            if showsTime { rows.append(.time(item.date)) }
            switch item {
            case .file(let file):
                rows.append(.file(file))
            case .message(let message):
                let nextShowsTime = next.map { $0.date.timeIntervalSince(item.date) >= 900 } ?? false
                let starts = showsTime || !sameRun(previous, item)
                let ends = nextShowsTime || !sameRun(item, next)
                rows.append(.message(message, startsRun: starts, endsRun: ends))
            }
        }
        return rows
    }
}

/// "Today 3:41 PM", centred between messages.
struct TimestampHeaderView: View {
    let date: Date

    var body: some View {
        (Text(date.chatDayString()).fontWeight(.semibold) + Text(" \(date.formatted(date: .omitted, time: .shortened))"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// A message in the style of Messages: blue bubbles on the right for you, grey on
/// the left for others, with a tail on the last bubble of a run and tapback
/// reactions on the corner. Double-click copies it; the smiley beside it (or
/// right-click › React) adds a reaction.
struct MessageBubbleView: View {
    let message: ChatMessage
    let startsRun: Bool
    let endsRun: Bool
    let isCommunity: Bool
    let reactions: [ChatStore.ReactionGroup]
    let myReaction: String?
    /// "Delivered", "Read 3:45 PM"…, shown under your latest one-on-one message.
    var status: String?
    let onReact: (String) -> Void

    @Environment(DeskDropViewModel.self) private var model
    @State private var showingReactions = false
    @State private var showingEmoji = false
    @State private var hovering = false
    @State private var copied = false

    private var outgoing: Bool { message.isOutgoing }

    /// Up to three emoji and nothing else are shown large, without a bubble.
    private var isJumboEmoji: Bool {
        guard message.media == nil else { return false }
        let characters = message.text.filter { !$0.isWhitespace }
        return (1...3).contains(characters.count) && characters.allSatisfy { character in
            character.unicodeScalars.first.map { $0.properties.isEmojiPresentation || character.unicodeScalars.count > 1 } ?? false
        }
    }

    var body: some View {
        VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
            if startsRun, isCommunity, !outgoing {
                Text(message.senderName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 46)
                    .padding(.top, 4)
            }
            HStack(alignment: .bottom, spacing: 6) {
                if outgoing {
                    Spacer(minLength: 60)
                } else if isCommunity {
                    Group {
                        if endsRun {
                            ChatAvatar(conversation: .direct(message.senderID), name: message.senderName, size: 28)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                // The react button rides right next to the bubble, on its inner side.
                HStack(alignment: .center, spacing: 6) {
                    if outgoing { reactButton }
                    bubble
                    if !outgoing { reactButton }
                }
                .frame(maxWidth: 560, alignment: outgoing ? .trailing : .leading)
                if !outgoing {
                    Spacer(minLength: 60)
                }
            }
            if let status {
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
                    .padding(.top, 1)
                    .transition(.opacity)
            }
        }
        .padding(.top, reactions.isEmpty ? 0 : 24)
        .padding(.bottom, endsRun ? 6 : 0)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Copy")) { copy() }
        .accessibilityAction(named: Text("React")) { showingReactions = true }
        .accessibilityIdentifier("chatMessage")
    }

    @ViewBuilder
    private var bubble: some View {
        Group {
            if let media = message.media {
                MediaMessageView(message: message, media: media)
            } else if isJumboEmoji {
                Text(verbatim: message.text)
                    .font(.system(size: 44))
                    .padding(.horizontal, 2)
            } else if let card = linkCard {
                VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                    // A message that's only the link is shown by its preview alone.
                    if !(card.preview != nil && LinkPreview.isOnlyLink(message.text)) {
                        textBubble
                    }
                    card
                }
            } else {
                textBubble
            }
        }
        .scaleEffect(copied ? 0.96 : 1, anchor: outgoing ? .trailing : .leading)
        .overlay(alignment: outgoing ? .topLeading : .topTrailing) {
            // Pinned by its inner corner to a point just inside the bubble's corner,
            // so it overlaps the bubble the same amount whatever its width.
            Color.clear
                .frame(width: 0, height: 0)
                .overlay(alignment: outgoing ? .bottomTrailing : .bottomLeading) {
                    if !reactions.isEmpty {
                        ReactionBadges(groups: reactions, dotsOnTrailing: outgoing)
                            .fixedSize()
                            .transition(.scale(scale: 0.4, anchor: outgoing ? .bottomTrailing : .bottomLeading)
                                .combined(with: .opacity))
                    }
                }
                .offset(x: outgoing ? 6 : -6, y: 4)
        }
        .overlay(alignment: .top) {
            if copied {
                Label(String(localized: "Copied"), systemImage: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .liquidGlass(in: Capsule())
                    .fixedSize()
                    .offset(y: -28)
                    .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: reactions)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: copy)
        .popover(isPresented: $showingReactions, arrowEdge: .top) {
            ReactionBar(selected: myReaction) { emoji in
                onReact(emoji)
                showingReactions = false
            } onMore: {
                showingReactions = false
                showingEmoji = true
            }
        }
        .popover(isPresented: $showingEmoji, arrowEdge: .top) {
            EmojiPickerView { emoji in
                onReact(emoji)
                showingEmoji = false
            }
        }
        .contextMenu {
            Button("Copy", action: copy)
            if let page = message.media?.giphyPage {
                Button("Open on GIPHY") { NSWorkspace.shared.open(page) }
            }
            if let hash = message.media?.hash, model.library.contains(hash), !model.library.isMySticker(hash) {
                Button("Add to My Stickers") { model.library.addSticker(hash: hash) }
            }
            Menu("React") {
                ForEach(EmojiCatalog.tapbacks, id: \.self) { emoji in
                    Button(myReaction == emoji ? "\(emoji)  ✓" : emoji) { onReact(emoji) }
                }
                Divider()
                Button("More Emoji…") { showingEmoji = true }
            }
        }
        .help(String(localized: "\(message.sentAt.formatted(date: .abbreviated, time: .shortened)) · Double-click to copy"))
    }

    private var textBubble: some View {
        messageText
            .font(.system(size: 14))
            .foregroundStyle(outgoing ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                BubbleShape(isOutgoing: outgoing, hasTail: endsRun)
                    .fill(outgoing ? Theme.messageBlue : Theme.incomingBubble)
            )
    }

    /// The link's preview: made, or (for yours) still being made.
    private var linkCard: LinkPreviewCard? {
        let isLoading = outgoing && model.chat.isPreparingPreview(message.id)
        guard message.link != nil || isLoading, let url = message.link?.url ?? LinkPreview.firstLink(in: message.text) else {
            return nil
        }
        return LinkPreviewCard(url: url, preview: message.link, isLoading: isLoading, senderID: message.senderID,
                               isOutgoing: outgoing)
    }

    /// The text, with its Markdown formatting unless that's switched off.
    @ViewBuilder
    private var messageText: some View {
        if model.settings.renderMarkdown, MessageMarkdown.mayContainMarkdown(message.text) {
            MarkdownTextView(text: message.text, outgoing: outgoing)
        } else {
            Text(verbatim: message.text)
        }
    }

    /// The image behind a GIF or sticker, as downloaded or received.
    private func mediaData(_ media: ChatMedia) -> Data? {
        if let hash = media.hash { return model.library.data(for: hash) }
        return media.url.flatMap(model.remoteImages.data(for:))
    }

    /// Copies the whole message (the Markdown as typed, or a GIF or sticker's
    /// image), with a little press and a "Copied" tag.
    private func copy() {
        NSPasteboard.general.clearContents()
        if let media = message.media {
            if let data = mediaData(media) {
                let type = ImageProcessing.isAnimated(data) ? NSPasteboard.PasteboardType("com.compuserve.gif") : .png
                NSPasteboard.general.setData(data, forType: type)
                if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                    NSPasteboard.general.setData(tiff, forType: .tiff)
                }
            }
            if let page = media.giphyPage { NSPasteboard.general.setString(page.absoluteString, forType: .string) }
        } else {
            NSPasteboard.general.setString(message.text, forType: .string)
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { copied = false }
        }
    }

    /// A small glass smiley beside the bubble on hover.
    private var reactButton: some View {
        Button { showingReactions = true } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(GlassIconButtonStyle(size: 26))
        .opacity(hovering || showingReactions ? 1 : 0)
        .scaleEffect(hovering || showingReactions ? 1 : 0.6)
        .animation(Theme.Motion.snappy, value: hovering)
        .help(String(localized: "React"))
        .accessibilityHidden(true)
        .accessibilityIdentifier("reactButton")
    }

    private var accessibilityText: String {
        let who = outgoing ? String(localized: "You") : message.senderName
        let time = message.sentAt.formatted(date: .omitted, time: .shortened)
        let content = message.media.map { media in
            [message.previewText, media.title].compactMap { $0 }.joined(separator: ", ")
        } ?? message.previewText
        var text = "\(who): \(content), \(time)"
        if !reactions.isEmpty {
            text += ", " + reactions.map { "\($0.emoji) from \($0.names.joined(separator: " and "))" }.joined(separator: ", ")
        }
        if let status { text += ", \(status)" }
        return text
    }
}
