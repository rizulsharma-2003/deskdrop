import SwiftUI

/// Bounds of each card in the stage, keyed by peer ID (or `DeskStageView.localID`).
struct CardBoundsKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Draws above the stage: the dotted beam while a drag hovers a colleague, and any
/// files currently being thrown. Never intercepts clicks or drops.
struct TransferFlightOverlay: View {
    let flights: [Flight]
    let targetedPeerID: String?
    let frames: [String: CGRect]
    let originID: String
    let onLanded: (Flight) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let target = targetedPeerID, let from = frames[originID], let to = frames[target] {
                ConnectionBeam(from: CGPoint(x: from.midX, y: from.minY + 8),
                               to: CGPoint(x: to.midX, y: to.minY + 8),
                               isAnimated: !reduceMotion)
                    .transition(.opacity)
            }
            ForEach(flights) { flight in
                if let from = frames[originID], let to = frames[flight.peerID] {
                    ThrowAnimationView(flight: flight,
                                       start: CGPoint(x: from.midX, y: from.minY + 52),
                                       end: CGPoint(x: to.midX, y: to.minY + 52)) {
                        onLanded(flight)
                    }
                }
            }
        }
        .animation(Theme.Motion.gentle, value: targetedPeerID)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A dotted arc from your Mac to the hovered colleague. The dashes drift toward
/// the recipient only while the drag is over the card.
private struct ConnectionBeam: View {
    let from: CGPoint
    let to: CGPoint
    let isAnimated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isAnimated)) { context in
            let phase = isAnimated ? -CGFloat(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 18) : 0
            ArcShape(from: from, to: to)
                .stroke(LinearGradient(colors: [Theme.cyan.opacity(0.25), Theme.accent], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.5, 8.5], dashPhase: phase))
                .shadow(color: Theme.accent.opacity(0.5), radius: 4)
        }
    }
}

private struct ArcShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        let control = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - max(36, abs(to.x - from.x) * 0.2))
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(to: to, control: control)
        return path
    }
}
