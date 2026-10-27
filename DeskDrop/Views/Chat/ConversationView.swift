import SwiftUI

/// One conversation, laid out like Messages: the history with timestamps and
/// receipts scrolls under a floating Liquid Glass header and message bar.
struct ConversationView: View {
    let conversation: ConversationID

    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var draft = ""
    @State private var confirmingDelete = false
    @State private var isDropTargeted = false
    @State private var showingEmoji = false
    @State private var showingMedia = false
    @FocusState private var composerFocused: Bool
    /// Whether the newest message is in view. When it is, new messages scroll in;
    /// when you've scrolled up to read, they don't yank you down.
    @State private var isAtBottom = true
    /// Messages from others that arrived while you were scrolled up.
    @State private var newWhileAway = 0
    /// Bumped to ask the message list to scroll to the newest message.
    @State private var jumpRequest = 0

    private static let bottomID = "conversation-bottom"

    private var messages: [ChatMessage] { model.chat.store.messages(in: conversation) }
    /// Files sent and received with this colleague, shown among the messages.
    private var files: [ConversationFile] { conversation.peerID.map(model.conversationFiles(with:)) ?? [] }
    private var isTyping: Bool { conversation.peerID.map(model.chat.isTyping) ?? false }
    private var title: String { model.title(for: conversation) }
    private var availability: ChatAvailability? { conversation.peerID.map(model.chat.availability(of:)) }
    private var canSend: Bool {
        availability != .needsUpdate && ChatValidator.sanitizeText(draft) != nil
    }

    var body: some View {
        Group {
            if messages.isEmpty && files.isEmpty {
                emptyState
            } else {
                messageList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .background(Theme.chatBackground)
        .overlay { dropOverlay }
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(isTargeted: $isDropTargeted, acceptsDrop: canDropFiles) { urls in
            if let peerID = conversation.peerID { model.send(urls, to: peerID) }
        })
        .onAppear {
            updateActiveConversation()
            composerFocused = true
            #if DEBUG
            if UITestSupport.opensMediaPicker { showingMedia = true }
            #endif
        }
        .onDisappear {
            if model.chat.activeConversation == conversation { model.chat.activeConversation = nil }
            model.chat.draftChanged(in: conversation, isEmpty: true)
        }
        .onChange(of: draft) { _, text in
            model.chat.draftChanged(in: conversation, isEmpty: text.allSatisfy(\.isWhitespace))
        }
        .onChange(of: controlActiveState) { _, _ in updateActiveConversation() }
        .confirmationDialog(String(localized: "Delete this conversation from this Mac?"), isPresented: $confirmingDelete) {
            Button(String(localized: "Delete Conversation"), role: .destructive) {
                model.chat.store.deleteConversation(conversation)
            }
        } message: {
            Text("Colleagues keep their own copies.")
        }
    }

    /// Messages count as read while this conversation is in a focused window.
    private func updateActiveConversation() {
        if controlActiveState == .key {
            model.chat.activeConversation = conversation
        } else if model.chat.activeConversation == conversation {
            model.chat.activeConversation = nil
        }
    }

    // MARK: - Header

    /// The avatar with the name in a glass pill beneath it, as in Messages, and
    /// round glass buttons on the right.
    private var header: some View {
        ZStack(alignment: .top) {
            VStack(spacing: -5) {
                ChatAvatar(conversation: conversation, name: title,
                           presence: conversation.peerID.map { model.peer($0)?.presence ?? .discovered }, size: 40)
                    .zIndex(1)
                VStack(spacing: 1) {
                    HStack(spacing: 3) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 5)
                .liquidGlass(in: Capsule())
                .help(subtitle)
            }
            .frame(maxWidth: 420)

            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    Spacer()
                    Menu {
                        Button(String(localized: "Delete Conversation…"), role: .destructive) { confirmingDelete = true }
                            .disabled(messages.isEmpty)
                    } label: {
                        Image(systemName: "info")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 32, height: 32)
                    .liquidGlass(interactive: true, in: Circle())
                    .accessibilityLabel(Text("Details"))
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var subtitle: String {
        if conversation.isCommunity {
            let count = model.chat.nearbyChatPeers.count
            switch count {
            case 0: return String(localized: "Nobody nearby right now · they catch up when they connect")
            case 1: return String(localized: "1 colleague here")
            default: return String(localized: "\(count) colleagues here")
            }
        }
        switch availability {
        case .available: return String(localized: "Available")
        case .needsUpdate: return String(localized: "Needs a newer DeskDrop to chat")
        default: return String(localized: "Not connected · messages are delivered when they’re back")
        }
    }

    // MARK: - Messages

    /// The newest message or file, to follow as things arrive.
    private struct Latest: Equatable {
        let id: String
        let isOutgoing: Bool
    }

    private func latest(of files: [ConversationFile]) -> Latest? {
        let message = messages.last.map { (date: $0.sentAt, item: Latest(id: $0.id.uuidString, isOutgoing: $0.isOutgoing)) }
        let file = files.last.map { (date: $0.date, item: Latest(id: "file-\($0.id.uuidString)", isOutgoing: $0.isOutgoing)) }
        switch (message, file) {
        case let (m?, f?): return f.date > m.date ? f.item : m.item
        case let (m?, nil): return m.item
        case let (nil, f?): return f.item
        case (nil, nil): return nil
        }
    }

    private var messageList: some View {
        let files = self.files
        let rows = ChatRow.rows(for: messages, files: files)
        let newest = latest(of: files)
        // As in Messages, the receipt goes once anything newer arrives (a reply or a
        // file); a message still waiting to be sent stays marked.
        let lastOutgoing = messages.last { $0.isOutgoing }
        let lastOutgoingID = lastOutgoing.flatMap { message -> UUID? in
            let isNewest = message.id == messages.last?.id && (files.last.map { $0.date <= message.sentAt } ?? true)
            return isNewest || message.delivery == .pending ? message.id : nil
        }
        let me = model.chat.myID
        let store = model.chat.store
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        switch row {
                        case .time(let date):
                            TimestampHeaderView(date: date)
                        case .message(let message, let startsRun, let endsRun):
                            MessageBubbleView(message: message, startsRun: startsRun, endsRun: endsRun,
                                              isCommunity: conversation.isCommunity,
                                              reactions: store.reactionGroups(for: message.id, me: me),
                                              myReaction: store.myReaction(to: message.id, me: me),
                                              status: message.id == lastOutgoingID ? status(of: message) : nil) { emoji in
                                model.chat.toggleReaction(emoji, on: message)
                            }
                            .id(message.id)
                            .transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: message.isOutgoing ? .bottomTrailing : .bottomLeading)
                                                        .combined(with: .opacity),
                                                    removal: .opacity))
                        case .file(let file):
                            FileBubbleView(file: file, peerName: title)
                                .id(row.id)
                                .transition(.scale(scale: 0.9, anchor: file.isOutgoing ? .bottomTrailing : .bottomLeading)
                                    .combined(with: .opacity))
                        }
                    }
                    if isTyping {
                        TypingIndicatorView()
                            .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
                    }
                }
                .animation(Theme.Motion.snappy, value: isTyping)
                .padding(.horizontal, 16)
                .padding(.top, 10)

                // The end of the conversation: scroll target, and (before macOS 15)
                // the way to tell whether the newest message is in view.
                Color.clear
                    .frame(height: 10)
                    .id(Self.bottomID)
                    .onAppear { if !Self.tracksScrollGeometry { isAtBottom = true } }
                    .onDisappear { if !Self.tracksScrollGeometry { isAtBottom = false } }
            }
            .modifier(StartsAtBottom())
            .softScrollEdges([.top, .bottom])
            .modifier(BottomTracking(isAtBottom: $isAtBottom))
            .animation(Theme.Motion.spring, value: rows.count)
            .onChange(of: newest) { old, new in
                guard old != nil, let new else { return }
                if new.isOutgoing || isAtBottom {
                    scrollToBottom(proxy)
                } else {
                    newWhileAway += 1
                }
            }
            .onChange(of: isTyping) { _, typing in
                if typing, isAtBottom { scrollToBottom(proxy) }
            }
            // Link previews and images that arrive make rows taller; stay at the end.
            .onChange(of: model.chat.preparingPreviews) { _, _ in
                if isAtBottom { scrollToBottom(proxy) }
            }
            .onChange(of: model.library.arrivals) { _, _ in
                if isAtBottom { scrollToBottom(proxy) }
            }
            .onChange(of: isAtBottom) { _, atBottom in
                if atBottom { newWhileAway = 0 }
            }
            .onChange(of: jumpRequest) { _, _ in
                newWhileAway = 0
                scrollToBottom(proxy)
            }
            #if DEBUG
            .task {
                // UI tests only: start scrolled to the oldest message.
                guard UITestSupport.startsScrolledUp, let first = messages.first else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(first.id, anchor: .top)
            }
            #endif
        }
        .accessibilityIdentifier("chatMessages")
    }

    private static var tracksScrollGeometry: Bool {
        if #available(macOS 15.0, *) { true } else { false }
    }

    /// Waits a moment so a row that was just added is laid out before scrolling
    /// to it; scrolling in the same update can stop short of the new message.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(Theme.Motion.spring) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    /// While you're scrolled up: "N New Messages" if something arrived, otherwise
    /// a round arrow. Either takes you to the newest message.
    @ViewBuilder
    private var jumpToLatest: some View {
        if !isAtBottom {
            Group {
                if newWhileAway > 0 {
                    Button { jumpRequest += 1 } label: {
                        Label(newWhileAway == 1 ? String(localized: "1 New Message")
                                                : String(localized: "\(newWhileAway) New Messages"),
                              systemImage: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Theme.messageBlue))
                            .overlay(GlassRim(shape: Capsule()))
                            .shadow(color: Theme.messageBlue.opacity(0.4), radius: 8, y: 3)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("newMessagesButton")
                    .frame(maxWidth: .infinity)
                } else {
                    Button { jumpRequest += 1 } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(GlassIconButtonStyle(size: 36))
                    .help(String(localized: "Jump to the newest message"))
                    .accessibilityLabel(Text("Jump to newest message"))
                    .accessibilityIdentifier("jumpToLatestButton")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 18)
                }
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    /// Receipts under your latest one-on-one message, as in Messages.
    private func status(of message: ChatMessage) -> String? {
        guard !conversation.isCommunity else { return nil }
        if model.chat.isPreparingPreview(message.id) { return String(localized: "Sending…") }
        switch message.delivery {
        case .pending: return String(localized: "Waiting for \(title) to connect")
        case .sent: return String(localized: "Sent")
        case .delivered: return String(localized: "Delivered")
        case .read:
            guard let readAt = message.readAt else { return String(localized: "Read") }
            let time = Calendar.current.isDateInToday(readAt)
                ? readAt.formatted(date: .omitted, time: .shortened)
                : readAt.chatListString()
            return String(localized: "Read \(time)")
        case nil: return nil
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            ChatAvatar(conversation: conversation, name: title, size: 64)
            Text(conversation.isCommunity ? String(localized: "Everyone nearby") : title)
                .font(.system(size: 17, weight: .semibold))
            Text(conversation.isCommunity
                 ? String(localized: "Messages here go to every colleague running DeskDrop nearby. People who aren’t around catch up when they connect.")
                 : String(localized: "Start a conversation. Messages stay on your Macs — nothing goes through a server."))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chatEmptyState")
    }

    @ViewBuilder
    private var notice: some View {
        if availability == .needsUpdate {
            Label(String(localized: "\(title) needs to update DeskDrop before you can chat."), systemImage: "arrow.down.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .liquidGlass(in: Capsule())
        }
    }

    // MARK: - Files

    /// Files can be dropped on a one-on-one conversation to send them to that colleague.
    private var canDropFiles: Bool {
        guard let peerID = conversation.peerID, let peer = model.peer(peerID) else { return false }
        if case .incompatible = peer.presence { return false }
        return true
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
            ZStack {
                shape.fill(Theme.messageBlue.opacity(canDropFiles ? 0.1 : 0.04))
                shape.strokeBorder(canDropFiles ? Theme.messageBlue : Theme.hairlineStrong,
                                   style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                Label(canDropFiles ? String(localized: "Release to send to \(title)")
                                   : String(localized: "Open a colleague’s conversation to send files"),
                      systemImage: canDropFiles ? "arrow.down.doc.fill" : "person.crop.circle.badge.questionmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canDropFiles ? AnyShapeStyle(Theme.messageBlue) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .liquidGlass(in: Capsule())
            }
            .padding(8)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    // MARK: - Composer

    /// Notices, transfers with this colleague and the message bar, floating at the bottom.
    private var bottomBar: some View {
        VStack(spacing: 8) {
            notice
            composer
        }
        .padding(.bottom, 12)
        .padding(.top, 6)
        .overlay(alignment: .top) {
            jumpToLatest
                .offset(y: -46)
                .animation(Theme.Motion.snappy, value: isAtBottom)
                .animation(Theme.Motion.snappy, value: newWhileAway)
        }
    }

    /// As in Messages: a round glass + for sending files, then the message field
    /// with the emoji button and, once there's text, the send arrow inside it.
    private var composer: some View {
        GlassGroup(spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                if let peerID = conversation.peerID {
                    let ready = model.peer(peerID)?.presence == .ready
                    Button {
                        model.chooseFilesAndSend(to: peerID)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .buttonStyle(GlassIconButtonStyle(size: 36))
                    .disabled(!ready)
                    .opacity(ready ? 1 : 0.45)
                    .help(ready ? String(localized: "Send Files…")
                                : String(localized: "You can send files when \(title) is connected"))
                    .accessibilityLabel(Text("Send Files"))
                    .accessibilityIdentifier("sendFilesButton")
                }

                HStack(alignment: .bottom, spacing: 2) {
                    TextField(String(localized: "Message"), text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .onSubmit(send)
                        .modifier(ComposerKeys(isActive: composerFocused))
                        .disabled(availability == .needsUpdate)
                        .padding(.leading, 14)
                        .padding(.vertical, 9)
                        .accessibilityIdentifier("chatComposer")

                    Button { showingMedia.toggle() } label: {
                        Text(verbatim: "GIF")
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 1.5)
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(lineWidth: 1.4))
                            .foregroundStyle(showingMedia ? Theme.messageBlue : .secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 3)
                    .disabled(availability == .needsUpdate)
                    .help(String(localized: "GIFs and Stickers"))
                    .accessibilityLabel(Text("GIFs and Stickers"))
                    .accessibilityIdentifier("mediaButton")
                    .popover(isPresented: $showingMedia, arrowEdge: .top) {
                        MediaPickerView(onPick: sendMedia)
                    }

                    Button { showingEmoji.toggle() } label: {
                        Image(systemName: "face.smiling")
                            .font(.system(size: 17))
                            .foregroundStyle(showingEmoji ? Theme.messageBlue : .secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 3)
                    .padding(.trailing, canSend ? 0 : 4)
                    .help(String(localized: "Emoji"))
                    .accessibilityLabel(Text("Emoji"))
                    .accessibilityIdentifier("emojiButton")
                    .popover(isPresented: $showingEmoji, arrowEdge: .top) {
                        EmojiPickerView { emoji in
                            draft += emoji
                            composerFocused = true
                        }
                    }

                    if canSend {
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Theme.messageBlue))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                        .padding(.bottom, 4)
                        .help(String(localized: "Send (Return). Shift-Return adds a new line, and continues a list."))
                        .accessibilityLabel(Text("Send"))
                        .accessibilityIdentifier("chatSendButton")
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
                .frame(minHeight: 36)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .animation(Theme.Motion.snappy, value: canSend)
            }
        }
        .padding(.horizontal, 14)
    }

    private func sendMedia(_ pick: MediaPickerView.Pick) {
        showingMedia = false
        switch pick {
        case .giphy(let media): model.send(media, to: conversation)
        case .mine(let hash): model.sendSticker(hash, to: conversation)
        }
        jumpRequest += 1
        composerFocused = true
    }

    private func send() {
        guard canSend else { return }
        if model.chat.send(draft, to: conversation) {
            draft = ""
            jumpRequest += 1
        }
    }
}

/// Opens at the newest message. On macOS 15 and later only the initial position
/// is anchored: anchoring size changes too would drag you back to the bottom
/// whenever a message arrives while you're reading further up.
private struct StartsAtBottom: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// Keeps `isAtBottom` current from the scroll position (macOS 15 and later).
/// Earlier systems use the end-of-conversation marker's appearance instead.
private struct BottomTracking: ViewModifier {
    @Binding var isAtBottom: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 60
            } action: { _, atBottom in
                isAtBottom = atBottom
            }
        } else {
            content
        }
    }
}
