import SwiftUI

/// One Mac on the stage: yours, or a colleague's.
struct DeviceCardView: View {
    enum Content {
        case local(name: String, kind: DeviceKind, isSharing: Bool)
        case peer(PeerDevice)
    }

    let content: Content
    var activity: CardActivity?
    var isTargeted = false
    /// Incremented each time a thrown file lands, to play the catch bounce.
    var arrivalCount = 0
    /// Screen edges that send to this colleague.
    var edges: [ScreenEdge] = []
    /// Their profile photo (or yours, on your own card).
    var photo: NSImage?

    @State private var isHovering = false

    private var isLocal: Bool {
        if case .local = content { return true }
        return false
    }

    private var name: String {
        switch content {
        case .local(let name, _, _): name
        case .peer(let peer): peer.displayName
        }
    }

    private var kind: DeviceKind {
        switch content {
        case .local(_, let kind, _): kind
        case .peer(let peer): peer.deviceKind
        }
    }

    private var glow: MacIllustration.Glow {
        switch content {
        case .local(_, _, let sharing):
            return sharing ? .local : .off
        case .peer(let peer):
            if isTargeted { return peer.presence == .ready ? .targeted : .on }
            return peer.presence == .ready ? .on : .off
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            MacIllustration(kind: kind, initials: PeerDevice.initials(for: name), glow: glow, photo: photo)
                .keyframeAnimator(initialValue: 1.0, trigger: arrivalCount) { view, scale in
                    view.scaleEffect(scale)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(1.12, duration: 0.14, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
                    }
                }
                .frame(height: 78)

            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    if isLocal {
                        Text("You")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.accentGradient))
                    }
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                statusRow
            }

            activityRow
                .frame(height: 16)
        }
        .padding(.top, 22)
        .padding(.bottom, 16)
        .padding(.horizontal, 14)
        .frame(width: 180)
        .liquidGlass(tint: cardTint, interactive: !isLocal, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(cardHighlight)
        .shadow(color: isTargeted && !isLocal ? Theme.accent.opacity(0.42) : .clear, radius: 26)
        .overlay(alignment: edges.contains(.left) ? .topLeading : .topTrailing) {
            if let edge = edges.first {
                Image(systemName: edge.symbolName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.accentGradient))
                    .shadow(color: Theme.accent.opacity(0.5), radius: 6)
                    .offset(x: edge == .left ? -6 : 6, y: -6)
                    .help(String(localized: "Drag a file to the \(edge == .left ? "left" : "right") edge of your screen to send here"))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.spring, value: edges)
        .scaleEffect(isTargeted && !isLocal ? 1.06 : (isHovering && !isLocal ? 1.02 : 1))
        .animation(Theme.Motion.snappy, value: isTargeted)
        .animation(Theme.Motion.gentle, value: isHovering)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isLocal ? Text("") : Text("Drop files here, or activate to choose files to send."))
        .accessibilityIdentifier(isLocal ? "deviceCard.you" : "deviceCard.peer")
    }

    @ViewBuilder
    private var statusRow: some View {
        switch content {
        case .local(_, _, let sharing):
            if isTargeted {
                Text("Drop on a colleague instead")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    StatusDot(color: sharing ? Theme.success : .secondary)
                    Text(sharing ? "This Mac · Visible" : "This Mac · Hidden")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
        case .peer(let peer):
            if isTargeted {
                Text(peer.presence == .ready ? "Release to send" : "Release to send when connected")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .transition(.opacity)
            } else {
                HStack(spacing: 6) {
                    StatusDot(color: peer.presence.color, isPulsing: peer.presence.isInProgress)
                    Text(peer.presence.label)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var activityRow: some View {
        if let activity {
            HStack(spacing: 4) {
                Image(systemName: symbol(for: activity.style))
                    .font(.system(size: 10, weight: .semibold))
                Text(activity.text)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(color(for: activity.style))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if case .peer(let peer) = content {
            Text("ID \(peer.shortTag)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    /// Glass picks up a little accent while a file is held over the card, and a
    /// little light on hover.
    private var cardTint: Color? {
        if isTargeted && !isLocal { return Theme.accent.opacity(0.28) }
        if isHovering && !isLocal { return Theme.surfaceHover }
        return nil
    }

    @ViewBuilder
    private var cardHighlight: some View {
        if isTargeted && !isLocal {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.accentGradient, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }

    private func symbol(for style: CardActivity.Style) -> String {
        switch style {
        case .progress: "arrow.left.arrow.right"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .neutral: "minus.circle"
        }
    }

    private func color(for style: CardActivity.Style) -> Color {
        switch style {
        case .progress: Theme.accent
        case .success: Theme.success
        case .warning: Theme.warning
        case .neutral: .secondary
        }
    }

    private var accessibilityLabel: Text {
        switch content {
        case .local(let name, _, let sharing):
            return Text("Your Mac, \(name), \(sharing ? "visible to colleagues" : "hidden")")
        case .peer(let peer):
            let activityText = activity.map { ", \($0.text)" } ?? ""
            return Text("\(peer.displayName), \(peer.presence.label)\(activityText)")
        }
    }
}
