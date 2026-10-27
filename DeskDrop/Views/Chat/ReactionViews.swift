import SwiftUI

/// The tapback bar: the six classic reactions plus "+" for any emoji.
struct ReactionBar: View {
    /// Your current reaction, highlighted.
    let selected: String?
    let onPick: (String) -> Void
    let onMore: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(EmojiCatalog.tapbacks, id: \.self) { emoji in
                Button { onPick(emoji) } label: {
                    Text(emoji)
                        .font(.system(size: 20))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(selected == emoji ? Theme.messageBlue : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(emoji))
            }
            Divider().frame(height: 22)
            Button(action: onMore) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.surface))
            }
            .buttonStyle(.plain)
            .help("Choose any emoji")
            .accessibilityLabel(Text("More reactions"))
        }
        .padding(6)
        .accessibilityIdentifier("reactionBar")
    }
}

/// Reactions shown on a bubble's top corner, like tapbacks in Messages: a round
/// badge with two small dots trailing toward the message, blue when you're one of
/// the reactors and grey otherwise.
struct ReactionBadges: View {
    let groups: [ChatStore.ReactionGroup]
    /// The side the dots trail toward: right for your messages (badge on their
    /// top-left corner), left for everyone else's.
    let dotsOnTrailing: Bool

    var body: some View {
        // In one glass container the badges and dots melt into each other like drops.
        GlassGroup(spacing: 6) {
            HStack(spacing: -8) {
                ForEach(Array(groups.prefix(4).enumerated()), id: \.element.id) { index, group in
                    badge(group)
                        .zIndex(Double(dotsOnTrailing ? index : -index))
                }
            }
            .overlay(alignment: dotsOnTrailing ? .bottomTrailing : .bottomLeading) {
                dots(fill: tailFill)
                    .offset(x: dotsOnTrailing ? 4 : -4, y: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(groups.map { "\($0.emoji) \($0.names.joined(separator: ", "))" }.joined(separator: "; ")))
    }

    /// The dots take the tint of the badge nearest the message.
    private var tailFill: Color? {
        let nearest = dotsOnTrailing ? groups.prefix(4).last : groups.first
        return nearest?.includesMe == true ? Theme.messageBlue : nil
    }

    private func badge(_ group: ChatStore.ReactionGroup) -> some View {
        HStack(spacing: 2) {
            Text(group.emoji)
                .font(.system(size: 15))
            if group.names.count > 1 {
                Text("\(group.names.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(group.includesMe ? .white : .secondary)
            }
        }
        .frame(minWidth: 30, minHeight: 30)
        .padding(.horizontal, group.names.count > 1 ? 5 : 0)
        .modifier(TapbackSurface(mine: group.includesMe, shape: Capsule()))
        .help(group.names.joined(separator: ", "))
    }

    private func dots(fill: Color?) -> some View {
        ZStack(alignment: dotsOnTrailing ? .bottomTrailing : .bottomLeading) {
            Color.clear
                .frame(width: 10, height: 10)
                .modifier(TapbackSurface(mine: fill != nil, shape: Circle()))
                .offset(x: dotsOnTrailing ? -6 : 6, y: -6)
            Color.clear
                .frame(width: 5, height: 5)
                .modifier(TapbackSurface(mine: fill != nil, shape: Circle()))
        }
        .frame(width: 16, height: 16, alignment: dotsOnTrailing ? .bottomTrailing : .bottomLeading)
    }
}

/// Your tapbacks are solid blue like your bubbles (so they stay blue when the
/// window isn't active); everyone else's are glass.
private struct TapbackSurface<S: InsettableShape>: ViewModifier {
    let mine: Bool
    let shape: S

    func body(content: Content) -> some View {
        if mine {
            content
                .background(shape.fill(Theme.messageBlue))
                .overlay(GlassRim(shape: shape))
        } else {
            content.liquidGlass(in: shape)
        }
    }
}
