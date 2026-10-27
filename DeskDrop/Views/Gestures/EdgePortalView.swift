import SwiftUI

/// The window along an assigned screen edge. While a file is being dragged it is
/// a thin, invisible strip; when the file is pushed against the edge it opens into
/// a portal showing the colleague, and releasing sends to them.
struct EdgePortalView: View {
    let edge: ScreenEdge
    /// The portal's vertical extent in global coordinates.
    let globalMaxY: CGFloat
    let state: DragOverlayState
    let model: DeskDropViewModel
    let onTargetChange: (Bool) -> Void
    let onDrop: ([URL]) -> Void

    @State private var isTargeted = false

    private var isOpen: Bool { state.openEdges.contains(edge) }
    private var peer: PeerDevice? { model.peer(for: edge) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: edge == .left ? .leading : .trailing) {
                // Windows are hit-tested by their pixels, so the strip must be
                // visibly painted to receive the drag. It doubles as a hint that
                // this edge is live while a file is being dragged.
                LinearGradient(colors: [Theme.cyan.opacity(0.35), Theme.accent.opacity(0.9), Theme.violet.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: DragOverlayController.collapsedEdgeWidth)
                    .frame(maxWidth: .infinity, alignment: edge == .left ? .leading : .trailing)
                if isOpen {
                    LinearGradient(colors: [Color.black.opacity(0.45), .clear],
                                   startPoint: edge == .left ? .leading : .trailing,
                                   endPoint: edge == .left ? .trailing : .leading)
                        .transition(.opacity)
                    card
                        .position(x: edge == .left ? 136 : geometry.size.width - 136,
                                  y: min(max(globalMaxY - state.cursor.y, 120), geometry.size.height - 120))
                        .transition(.move(edge: edge == .left ? .leading : .trailing).combined(with: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.72), value: isOpen)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(isTargeted: $isTargeted, acceptsDrop: peer != nil, onDrop: onDrop))
        .onChange(of: isTargeted) { _, targeted in onTargetChange(targeted) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Send to \(model.settings.assignment(for: edge)?.displayName ?? "")"))
        .accessibilityIdentifier("edgePortal.\(edge.rawValue)")
    }

    private var card: some View {
        let name = model.settings.assignment(for: edge)?.displayName ?? ""
        return VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.2), Color(white: 0.06)], center: .top,
                                         startRadius: 0, endRadius: 70))
                Circle()
                    .strokeBorder(AngularGradient(colors: ProximityEffects.spectrum, center: .center), lineWidth: 2.5)
                MacIllustration(kind: peer?.deviceKind ?? .desktop, initials: PeerDevice.initials(for: name),
                                glow: peer == nil ? .off : .targeted,
                                photo: model.settings.assignment(for: edge).flatMap { model.photo(forPeer: $0.installationID) })
                    .scaleEffect(0.75)
            }
            .frame(width: 112, height: 112)
            .shadow(color: Theme.accent.opacity(0.7), radius: 26)

            Text(name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(peer == nil ? String(localized: "Not nearby right now") : String(localized: "Release to send"))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(peer == nil ? .white.opacity(0.6) : Theme.cyan)
            Label(edge.title, systemImage: edge.symbolName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.62))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(AngularGradient(colors: ProximityEffects.spectrum, center: .center), lineWidth: 1))
        )
        .scaleEffect(isTargeted ? 1.04 : 1)
    }
}
