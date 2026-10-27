import SwiftUI

/// A chat bubble. The last bubble in a run gets the curled tail at its bottom
/// corner, on the right for your messages and on the left for theirs.
struct BubbleShape: Shape {
    var isOutgoing: Bool
    var hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(17, rect.height / 2)
        let bubble = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
        guard hasTail else { return bubble }

        // Drawn for the right side, mirrored for incoming bubbles. Mirroring flips
        // the winding, so the tail is unioned in rather than added as a subpath.
        func x(_ value: CGFloat) -> CGFloat { isOutgoing ? value : rect.minX + rect.maxX - value }
        let edge = rect.maxX
        let bottom = rect.maxY
        let top = bottom - min(17, rect.height / 2)
        var tail = Path()
        tail.move(to: CGPoint(x: x(edge), y: top))
        tail.addCurve(to: CGPoint(x: x(edge + 5), y: bottom),
                      control1: CGPoint(x: x(edge), y: bottom - 6),
                      control2: CGPoint(x: x(edge + 2), y: bottom - 1.5))
        tail.addCurve(to: CGPoint(x: x(edge - 12), y: bottom - 3),
                      control1: CGPoint(x: x(edge - 2), y: bottom + 0.5),
                      control2: CGPoint(x: x(edge - 7), y: bottom - 0.5))
        tail.addLine(to: CGPoint(x: x(edge - 12), y: top))
        tail.closeSubpath()
        return bubble.union(tail)
    }
}
