import Foundation
import Observation

/// What the drag overlays are showing right now. Points are in global screen
/// coordinates (origin at the bottom-left of the main display).
@MainActor
@Observable
final class DragOverlayState {
    /// Colleagues arranged around a held file.
    struct Ring: Equatable {
        let center: CGPoint
        let radius: CGFloat
        let positions: [String: CGPoint]
        let shownAt: Date
    }

    /// One play of the glow effect.
    struct Burst: Identifiable, Equatable {
        enum Kind: Equatable {
            /// A file leaving this Mac.
            case send
            /// A request arriving on this Mac.
            case arrival
        }

        let id = UUID()
        let origin: CGPoint
        let edge: ScreenEdge?
        let kind: Kind
        let start: Date
    }

    var isDragging = false
    var cursor = CGPoint.zero
    var ring: Ring?
    var targetedOrb: String?
    /// 0…1 as the cursor approaches an assigned edge.
    var edgeProximity: [ScreenEdge: Double] = [:]
    var openEdges: Set<ScreenEdge> = []
    var targetedEdge: ScreenEdge?
    /// Global x of each assigned edge, and the vertical range its portal covers.
    var edgeGeometry: [ScreenEdge: (x: CGFloat, minY: CGFloat, maxY: CGFloat)] = [:]
    var bursts: [Burst] = []
    var reduceMotion = false

    var isAnimating: Bool {
        ring != nil || !bursts.isEmpty || !openEdges.isEmpty || edgeProximity.values.contains { $0 > 0 }
    }
}
