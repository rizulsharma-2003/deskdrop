import SwiftUI

/// A message's text with its Markdown formatting: inline styles, links, code
/// blocks, quotes, lists, headings and rules, coloured for a blue (yours) or
/// grey bubble.
struct MarkdownTextView: View {
    let text: String
    let outgoing: Bool

    private var blocks: [MessageMarkdown.Block] { MessageMarkdown.blocks(for: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .tint(outgoing ? .white : Theme.messageBlue)
    }

    @ViewBuilder
    private func view(for block: MessageMarkdown.Block) -> some View {
        switch block {
        case .paragraph(let string):
            styled(string)
        case .heading(let level, let string):
            styled(string)
                .font(.system(size: [17, 15.5, 14.5][level - 1], weight: level == 3 ? .semibold : .bold))
                .padding(.top, 1)
        case .quote(let string):
            HStack(alignment: .top, spacing: 7) {
                Capsule()
                    .fill(outgoing ? Color.white.opacity(0.55) : Color.secondary.opacity(0.5))
                    .frame(width: 3)
                styled(string)
                    .opacity(0.88)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .listItem(let marker, let indent, let string):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: marker)
                    .monospacedDigit()
                    .frame(minWidth: 10, alignment: .trailing)
                styled(string)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .code(let code):
            Text(verbatim: code)
                .font(.system(size: 12.5, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(codeBackground))
        case .rule:
            Rectangle()
                .fill(outgoing ? Color.white.opacity(0.4) : Color.secondary.opacity(0.35))
                .frame(height: 1)
                .frame(minWidth: 60)
                .padding(.vertical, 3)
        }
    }

    private var codeBackground: Color {
        outgoing ? Color.black.opacity(0.18) : Color.primary.opacity(0.07)
    }

    /// Inline code gets a tinted background; links are underlined so they stand
    /// out on either bubble.
    private func styled(_ source: AttributedString) -> some View {
        var string = source
        for run in source.runs {
            if run.link != nil {
                string[run.range][AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                string[run.range][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = codeBackground
                string[run.range][AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(size: 13, design: .monospaced)
            }
        }
        return Text(string)
            .fixedSize(horizontal: false, vertical: true)
    }
}
