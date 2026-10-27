import Foundation
import Testing
@testable import DeskDrop

@Suite("Drag gestures and screen edges")
@MainActor
struct GestureTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "DeskDropGestureTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test("Gesture settings default on and persist, including edge assignments")
    func settingsPersist() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults) { "Test Mac" }
        #expect(settings.holdToShowNearby)
        #expect(settings.edgeSharingEnabled)
        #expect(settings.proximityEffects)
        #expect(settings.holdDelay == .medium)
        #expect(settings.leftEdge == nil && settings.rightEdge == nil)

        let alex = EdgeAssignment(installationID: UUID().uuidString, displayName: "Alex’s Mac")
        settings.setAssignment(alex, for: .left)
        settings.holdDelay = .long
        settings.proximityEffects = false

        let reloaded = SettingsStore(defaults: defaults) { "Test Mac" }
        #expect(reloaded.assignment(for: .left) == alex)
        #expect(reloaded.assignment(for: .right) == nil)
        #expect(reloaded.holdDelay == .long)
        #expect(!reloaded.proximityEffects)

        reloaded.setAssignment(nil, for: .left)
        #expect(SettingsStore(defaults: defaults) { "Test Mac" }.leftEdge == nil)
    }

    @Test("Corrupt or forged edge assignments are ignored")
    func invalidAssignment() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("nonsense".utf8), forKey: SettingsKey.leftEdge)
        defaults.set(try JSONEncoder().encode(EdgeAssignment(installationID: "../not-a-uuid", displayName: "x")),
                     forKey: SettingsKey.rightEdge)
        let settings = SettingsStore(defaults: defaults) { "Test Mac" }
        #expect(settings.leftEdge == nil)
        #expect(settings.rightEdge == nil)
    }

    @Test("A colleague belongs to one edge at a time and resolves only while nearby")
    func assignments() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let model = DeskDropViewModel(defaults: defaults, historyURL: root.url.appendingPathComponent("history.json"))
        model.injectPeerForUITesting(assignToLeftEdge: false)
        let peer = try #require(model.peers.first)

        model.assign(peer.id, to: .left)
        #expect(model.edges(assignedTo: peer.id) == [.left])
        #expect(model.peer(for: .left)?.id == peer.id)

        model.assign(peer.id, to: .right)
        #expect(model.edges(assignedTo: peer.id) == [.right])
        #expect(model.settings.leftEdge == nil)

        model.assign(UUID().uuidString, to: .left)
        #expect(model.settings.leftEdge == nil, "Only colleagues who are nearby can be assigned")

        model.clearEdge(.right)
        #expect(model.edges(assignedTo: peer.id).isEmpty)
        #expect(model.peer(for: .right) == nil)
    }

    @Test("Edge portals sit on the outer side of the display, collapsed or open")
    func edgeFrames() {
        let frame = CGRect(x: -1920, y: 340, width: 1920, height: 1080)
        let visible = CGRect(x: -1920, y: 340, width: 1920, height: 1050)
        let leftClosed = DragOverlayController.edgeFrame(.left, frame: frame, visible: visible, open: false)
        let rightOpen = DragOverlayController.edgeFrame(.right, frame: frame, visible: visible, open: true)
        #expect(leftClosed.minX == -1920)
        #expect(leftClosed.width == DragOverlayController.collapsedEdgeWidth)
        #expect(leftClosed.minY == visible.minY && leftClosed.height == visible.height)
        #expect(rightOpen.maxX == frame.maxX)
        #expect(rightOpen.width == DragOverlayController.openEdgeWidth)
    }

    @Test("Effect layers convert global points into each screen's top-left space")
    func effectCoordinates() {
        let state = DragOverlayState()
        let screen = CGRect(x: -1920, y: 340, width: 1920, height: 1080)
        state.cursor = CGPoint(x: -1900, y: 900)
        state.edgeGeometry[.left] = (x: -1920, minY: 340, maxY: 1390)
        state.edgeProximity[.left] = 0.9
        state.bursts = [DragOverlayState.Burst(origin: CGPoint(x: -1920, y: 900), edge: .left, kind: .send, start: .now),
                        DragOverlayState.Burst(origin: CGPoint(x: 500, y: 500), edge: nil, kind: .arrival, start: .now)]

        let snapshot = EffectSnapshot(state: state, screen: screen)
        #expect(snapshot.glows.count == 1)
        #expect(snapshot.glows.first?.x == 0)
        #expect(snapshot.glows.first?.y == CGFloat(1420 - 900))
        #expect(snapshot.flashes.count == 1, "Only bursts on this screen are drawn here")
        #expect(snapshot.flashes.first?.origin == CGPoint(x: 0, y: 520))
        #expect(snapshot.isAnimating)

        let elsewhere = EffectSnapshot(state: state, screen: CGRect(x: 0, y: 0, width: 1470, height: 956))
        #expect(elsewhere.glows.isEmpty)
        #expect(elsewhere.flashes.count == 1)
    }

    @Test("Animation curves stay in range")
    func curves() {
        for step in 0...20 {
            let x = Double(step) / 20
            #expect((0...1).contains(ProximityEffects.easeOutCubic(x)))
            #expect((0...1).contains(ProximityEffects.smoothstep(0, 1, x)))
            #expect((0..<1).contains(ProximityEffects.hash(step, 3)))
        }
        #expect(ProximityEffects.easeOutCubic(1) == 1)
        #expect(ProximityEffects.easeOutBack(1) == 1)
        #expect(ProximityEffects.easeOutBack(0.6) > 1, "The halo overshoots slightly before settling")
        #expect(ProximityEffects.hash(4, 1) == ProximityEffects.hash(4, 1), "Sparks must not flicker between frames")
    }
}
