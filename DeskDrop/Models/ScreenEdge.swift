import Foundation

/// A side of the screen that can be assigned to a colleague. Dragging a file
/// against that edge opens a portal that sends to them.
enum ScreenEdge: String, Codable, CaseIterable, Identifiable, Sendable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: String(localized: "Left edge")
        case .right: String(localized: "Right edge")
        }
    }

    var symbolName: String {
        switch self {
        case .left: "arrow.left.to.line"
        case .right: "arrow.right.to.line"
        }
    }
}

/// Which colleague an edge sends to. The display name is remembered so the
/// assignment still reads well while that Mac is offline.
struct EdgeAssignment: Codable, Equatable, Sendable {
    let installationID: String
    var displayName: String
}
