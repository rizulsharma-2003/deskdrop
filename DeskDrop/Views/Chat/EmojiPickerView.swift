import AppKit
import SwiftUI

/// DeskDrop's emoji keyboard: categories, search and recently used, plus a way
/// into the full macOS Character Viewer.
struct EmojiPickerView: View {
    let onPick: (String) -> Void

    @Environment(DeskDropViewModel.self) private var model
    @State private var query = ""
    @State private var category: EmojiCatalog.Category = .smileys
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 2), count: 9)

    private var visible: [String] {
        if !query.isEmpty { return EmojiCatalog.search(query) }
        if category == .recent { return model.settings.recentEmoji }
        return EmojiCatalog.emoji(in: category)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Emoji", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))

            if query.isEmpty {
                HStack(spacing: 2) {
                    ForEach(EmojiCatalog.Category.allCases) { item in
                        Button { category = item } label: {
                            Image(systemName: item.symbolName)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 30, height: 24)
                                .foregroundStyle(category == item ? Theme.messageBlue : .secondary)
                                .background(RoundedRectangle(cornerRadius: 6).fill(category == item ? Theme.messageBlue.opacity(0.14) : .clear))
                        }
                        .buttonStyle(.plain)
                        .help(item.title)
                    }
                }
            }

            ScrollView {
                if visible.isEmpty {
                    Text(category == .recent && query.isEmpty ? "Emoji you use will appear here." : "No emoji found")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 70)
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(visible, id: \.self) { emoji in
                            EmojiCell(emoji: emoji) {
                                model.settings.noteEmojiUsed(emoji)
                                onPick(emoji)
                            }
                        }
                    }
                }
            }
            .frame(height: 236)

            HStack {
                Text(query.isEmpty ? category.title : String(localized: "Search Results"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("All Emoji & Symbols…") {
                    NSApp.orderFrontCharacterPalette(nil)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(10)
        .frame(width: 330)
        .onAppear {
            if !model.settings.recentEmoji.isEmpty { category = .recent }
            searchFocused = true
        }
        .accessibilityIdentifier("emojiPicker")
    }
}

private struct EmojiCell: View {
    let emoji: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 22))
                .frame(width: 34, height: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.surfaceHover : .clear))
                .scaleEffect(hovering ? 1.12 : 1)
                .animation(Theme.Motion.snappy, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(emoji.unicodeScalars.first?.properties.name?.capitalized ?? emoji))
    }
}
