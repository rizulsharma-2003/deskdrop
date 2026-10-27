import SwiftUI

/// The prominent action: a solid accent capsule with a glassy rim. Solid rather
/// than tinted glass, because macOS greys tinted glass in inactive windows and
/// Accept has to read as the main action even on the never-active request panel.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    var tint: Color = Theme.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 17)
            .padding(.vertical, compact ? 5 : 8)
            .background(Capsule().fill(tint.gradient).opacity(isEnabled ? 1 : 0.45))
            .overlay(GlassRim(shape: Capsule()))
            .shadow(color: tint.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A quiet action: a clear glass capsule.
struct SecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 11 : 15)
            .padding(.vertical, compact ? 5 : 8)
            .liquidGlass(interactive: true, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// A round, icon-only button for rows inside glass panels: no glass of its own
/// (glass shouldn't sit on glass), just a highlight on hover.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        HoverReactive { hovering in
            configuration.label
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? Theme.surfaceHover : .clear))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .animation(Theme.Motion.snappy, value: configuration.isPressed)
                .animation(Theme.Motion.gentle, value: hovering)
                .contentShape(Circle())
        }
    }
}

/// A round, icon-only Liquid Glass button for controls floating over content.
struct GlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.44, weight: .medium))
            .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .frame(width: size, height: size)
            .liquidGlass(tint: tint, interactive: true, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// The bright top edge and soft lower edge that make a solid shape read as glass.
struct GlassRim<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .white.opacity(0.22)],
                                         startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// Tracks hover for content built inside a ButtonStyle.
private struct HoverReactive<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}
