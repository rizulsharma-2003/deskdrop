import SwiftUI

/// Which Liquid Glass variant to use: `regular` for controls and panels,
/// `clear` for small elements floating over busy content.
enum GlassVariant {
    case regular
    case clear
}

extension View {
    /// Liquid Glass on macOS 26 and later. Earlier systems get a frosted material
    /// with a fine border, so the layout is identical everywhere.
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(_ variant: GlassVariant = .regular, tint: Color? = nil, interactive: Bool = false,
                               in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = variant == .clear ? .clear : .regular
            glassEffect(base.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(tint.map { AnyShapeStyle($0.opacity(0.85)) } ?? AnyShapeStyle(Theme.surface)))
                    .overlay(shape.strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                    .shadow(color: Theme.shadow, radius: 10, y: 4)
            }
        }
    }

    /// Lets neighbouring glass elements blend and morph into each other (macOS 26+).
    @ViewBuilder
    func glassUnion(id: String, namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            glassEffectUnion(id: id, namespace: namespace)
        } else {
            self
        }
    }

    /// Content scrolling under floating glass fades softly at that edge (macOS 26+).
    @ViewBuilder
    func softScrollEdges(_ edges: Edge.Set) -> some View {
        if #available(macOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}

/// Groups glass elements so they render together and merge when close (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A glass surface for panels and cards.
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color = .clear

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content.liquidGlass(tint: tint == .clear ? nil : tint, in: shape)
    }
}

extension View {
    func glassBackground(cornerRadius: CGFloat = Theme.Radius.panel, tint: Color = .clear) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, tint: tint))
    }

    /// The main window's floating glass sidebar (Messages and Nearby).
    func sidebarGlass() -> some View {
        liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.pane, style: .continuous))
    }

    /// The pane beside the sidebar: rounded, with a fine edge and a soft shadow.
    func contentPane() -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.pane, style: .continuous)
        return clipShape(shape)
            .overlay(shape.strokeBorder(Theme.hairline))
            .shadow(color: Theme.shadow, radius: 14, y: 6)
    }
}

/// A padded glass container.
struct GlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = Theme.Radius.panel
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .glassBackground(cornerRadius: cornerRadius)
    }
}
