import SwiftUI

/// Messages inside the main window, styled after Apple's Messages with Liquid
/// Glass: a floating glass sidebar of conversations beside the open conversation.
struct MessagesView: View {
    @Environment(DeskDropViewModel.self) private var model
    @State private var query = ""

    var body: some View {
        HStack(spacing: 10) {
            sidebar
                .frame(width: 290)
                .sidebarGlass()
            ConversationView(conversation: model.chatSelection)
                .id(model.chatSelection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentPane()
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            if model.notificationsBlocked, model.settings.messageNotifications {
                notificationsOffNotice
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            conversationList
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 11)
        .frame(height: 32)
        // Already on glass, so a plain tinted capsule rather than more glass, but
        // strong enough to read as a field in both light and dark.
        .background(Capsule().fill(Color.primary.opacity(0.11)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
        .accessibilityIdentifier("conversationSearch")
    }

    /// Shown while macOS has DeskDrop's notifications switched off.
    private var notificationsOffNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Text("Notifications are off")
                    .font(.system(size: 12, weight: .semibold))
                Text("macOS is blocking DeskDrop’s banners, so you won’t hear about new messages while DeskDrop is in the background.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Turn On in System Settings…") { NotificationService.openSystemSettings() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.warning.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.warning.opacity(0.3)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notificationsOffNotice")
    }

    private var filtered: [DeskDropViewModel.ConversationSummary] {
        let all = model.conversationSummaries
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return all }
        return all.filter { summary in
            let haystack = (summary.title + " " + (summary.preview ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var conversationList: some View {
        let selection = Binding<ConversationID?>(
            get: { model.chatSelection },
            set: { if let id = $0 { model.chatSelection = id } }
        )
        let summaries = filtered
        return List(selection: selection) {
            ForEach(summaries) { summary in
                ConversationRow(summary: summary, isSelected: summary.id == model.chatSelection)
                    .tag(summary.id)
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
            }
            if summaries.isEmpty {
                Text(query.isEmpty ? "Colleagues appear here when they’re nearby." : "No conversations match")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if summaries.count == 1, query.isEmpty {
                Text("Colleagues appear here when they’re nearby.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("conversationList")
    }
}

/// A conversation in the list: avatar, name, time, a two-line preview and, when
/// there's something new, a blue badge with the unread count.
private struct ConversationRow: View {
    let summary: DeskDropViewModel.ConversationSummary
    let isSelected: Bool

    private var hasUnread: Bool { summary.unread > 0 }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ChatAvatar(conversation: summary.id, name: summary.title,
                       presence: summary.id.isCommunity ? nil : (summary.peer?.presence ?? .discovered), size: 42)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(summary.title)
                        .font(.system(size: 13, weight: hasUnread ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let date = summary.lastActivity {
                        Text(date.chatListString())
                            .font(.system(size: 11, weight: hasUnread ? .semibold : .regular))
                            .foregroundStyle(timeStyle)
                    }
                }
                HStack(alignment: .top, spacing: 6) {
                    Text(summary.preview ?? placeholder)
                        .font(.system(size: 12, weight: hasUnread ? .medium : .regular))
                        .foregroundStyle(previewStyle)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if hasUnread {
                        UnreadBadge(count: summary.unread, onSelection: isSelected)
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .animation(.spring(response: 0.32, dampingFraction: 0.6), value: summary.unread)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityIdentifier(summary.id.isCommunity ? "conversation.community" : "conversation.direct")
    }

    private var timeStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white.opacity(0.85)) }
        return hasUnread ? AnyShapeStyle(Theme.messageBlue) : AnyShapeStyle(.secondary)
    }

    private var previewStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white.opacity(0.85)) }
        return hasUnread ? AnyShapeStyle(.primary.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    private var placeholder: String {
        if summary.id.isCommunity { return String(localized: "Say hello to everyone nearby") }
        return summary.peer?.presence == .ready ? String(localized: "Available") : String(localized: "No messages yet")
    }

    private var accessibilityText: String {
        var text = summary.title
        if summary.unread > 0 { text += ", \(summary.unread) unread" }
        if let preview = summary.preview { text += ", \(preview)" }
        return text
    }
}

/// The unread count bubble. It pops each time the count goes up.
private struct UnreadBadge: View {
    let count: Int
    /// On the blue selection highlight the colors swap so it stays visible.
    let onSelection: Bool

    @State private var bump = false

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(count)))
            .foregroundStyle(onSelection ? Theme.messageBlue : .white)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(onSelection ? Color.white : Theme.messageBlue))
            .shadow(color: Theme.messageBlue.opacity(onSelection ? 0 : 0.35), radius: 4, y: 1)
            .scaleEffect(bump ? 1.25 : 1)
            .padding(.top, 1)
            .onChange(of: count) { old, new in
                guard new > old else { return }
                withAnimation(.spring(response: 0.18, dampingFraction: 0.5)) { bump = true }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55).delay(0.16)) { bump = false }
            }
            .accessibilityHidden(true)
    }
}
