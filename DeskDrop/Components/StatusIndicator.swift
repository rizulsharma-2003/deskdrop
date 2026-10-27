import SwiftUI

/// A small presence dot. Pulses gently only while something is in progress.
struct StatusDot: View {
    let color: Color
    var isPulsing = false
    var size: CGFloat = 7

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.55), radius: 2)
            .overlay {
                if isPulsing && !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.7), lineWidth: 1.2)
                        .scaleEffect(expanded ? 2.6 : 1)
                        .opacity(expanded ? 0 : 0.9)
                        .onAppear {
                            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                                expanded = true
                            }
                        }
                        .onDisappear { expanded = false }
                }
            }
            .accessibilityHidden(true)
    }
}

/// The header's status capsule.
struct StatusPill: View {
    let status: NetworkStatus

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(color: Theme.color(for: status.tone), isPulsing: status.isSearching)
            Text(status.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .liquidGlass(in: Capsule())
        .help(status.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Status: \(status.title)"))
        .accessibilityHint(Text(status.detail))
        .accessibilityIdentifier("networkStatus")
    }
}

/// Presence wording and color for a peer.
extension PeerPresence {
    var label: String {
        switch self {
        case .ready: String(localized: "Available")
        case .connecting, .connected: String(localized: "Connecting…")
        case .discovered: String(localized: "Nearby")
        case .unavailable: String(localized: "Not responding")
        case .incompatible: String(localized: "Update needed")
        }
    }

    var color: Color {
        switch self {
        case .ready: Theme.success
        case .connecting, .connected: Theme.accent
        case .discovered: .secondary
        case .unavailable, .incompatible: Theme.warning
        }
    }

    var isInProgress: Bool {
        self == .connecting || self == .connected
    }
}
