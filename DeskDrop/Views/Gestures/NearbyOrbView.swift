import SwiftUI

/// One colleague floating around a held file. Each orb lives in its own small
/// window so the spot under the cursor stays free (spring-loaded folders keep working).
struct NearbyOrbView: View {
    /// Nil shows a "nobody nearby" orb that refuses drops.
    let peer: PeerDevice?
    let index: Int
    let state: DragOverlayState
    var photo: NSImage?
    let onDrop: ([URL]) -> Void

    @State private var appeared = false
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.07)], center: .top,
                                         startRadius: 0, endRadius: 60))
                    .opacity(0.94)
                Circle()
                    .strokeBorder(AngularGradient(colors: ProximityEffects.spectrum, center: .center,
                                                  angle: .degrees(isTargeted ? 180 : 0)),
                                  lineWidth: isTargeted ? 3 : 1.5)
                if let peer {
                    MacIllustration(kind: peer.deviceKind, initials: peer.initials,
                                    glow: isTargeted ? .targeted : (peer.presence == .ready ? .on : .off), photo: photo)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 86, height: 86)
            .shadow(color: Theme.accent.opacity(isTargeted ? 0.85 : 0.35), radius: isTargeted ? 24 : 10)
            .scaleEffect(isTargeted ? 1.18 : 1)

            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(isTargeted ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.black.opacity(0.62))))
                .frame(maxWidth: 140)
        }
        .frame(width: DragOverlayController.orbSize.width, height: DragOverlayController.orbSize.height)
        // Nearly invisible fill so the whole square is a drop target.
        .background(Color.black.opacity(0.01))
        .scaleEffect(appeared ? 1 : 0.2)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.66), value: isTargeted)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62).delay(Double(index) * 0.035)) {
                appeared = true
            }
        }
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(isTargeted: $isTargeted, acceptsDrop: peer != nil, onDrop: onDrop))
        .onChange(of: isTargeted) { _, targeted in
            guard let id = peer?.id else { return }
            if targeted {
                state.targetedOrb = id
            } else if state.targetedOrb == id {
                state.targetedOrb = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(peer.map { Text("Send to \($0.displayName)") } ?? Text("No one nearby"))
        .accessibilityIdentifier("nearbyOrb")
    }

    private var label: String {
        guard let peer else { return String(localized: "No one nearby") }
        if isTargeted { return String(localized: "Release to send") }
        return peer.presence == .ready ? peer.displayName : String(localized: "\(peer.displayName) · connecting")
    }
}
