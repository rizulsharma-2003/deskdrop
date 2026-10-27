import AppKit
import SwiftUI

/// Drives the "drag a file anywhere" gestures:
///
/// - **Hold to share:** while a file is being dragged in any app, holding the
///   cursor still shows nearby colleagues as orbs around it; dropping on one sends.
/// - **Screen edges:** pushing a dragged file against the left or right edge opens
///   a portal for the colleague assigned to that edge; releasing sends.
///
/// All windows here are borderless, non-activating panels that exist only during a
/// file drag (and briefly for effects), so normal clicking is never intercepted.
/// Sending goes through the same `DeskDropViewModel.send` path as the main window,
/// so the recipient still has to accept.
@MainActor
final class DragOverlayController {
    static let orbSize = CGSize(width: 140, height: 140)
    static let collapsedEdgeWidth: CGFloat = 4
    static let openEdgeWidth: CGFloat = 280
    /// The edge starts to glow when the cursor is this close.
    static let proximityRange: CGFloat = 240

    let state = DragOverlayState()
    /// How long overlays stay after the button is released, so the drop isn't lost.
    var teardownDelay: Duration = .milliseconds(700)
    private let model: DeskDropViewModel
    private let monitor = GlobalDragMonitor()
    private let timers = ScheduledTasks<TimerKey>()
    private var orbPanels: [NSPanel] = []
    private var edgePanels: [ScreenEdge: EdgePanel] = [:]
    private var effectPanels: [String: NSPanel] = [:]

    private struct EdgePanel {
        let panel: NSPanel
        let frame: CGRect
        let visibleFrame: CGRect
    }

    private enum TimerKey: Hashable {
        case teardown
        case collapse(ScreenEdge)
        case expireBurst(UUID)
        case previewArrival
    }

    init(model: DeskDropViewModel) {
        self.model = model
        monitor.onFileDragBegan = { [weak self] point in self?.dragBegan(at: point) }
        monitor.onDragMoved = { [weak self] point in self?.dragMoved(to: point) }
        monitor.onHold = { [weak self] point in self?.held(at: point) }
        monitor.onDragEnded = { [weak self] in self?.dragEnded() }
    }

    var isEnabled: Bool { monitor.isRunning }

    func setEnabled(_ enabled: Bool) {
        monitor.holdDelay = model.settings.holdDelay.rawValue
        if enabled {
            monitor.start()
        } else {
            monitor.stop()
            tearDownInteractive()
        }
    }

    // MARK: - Drag lifecycle

    private func dragBegan(at point: CGPoint) {
        timers.cancel(.teardown)
        tearDownInteractive()
        state.isDragging = true
        state.cursor = point
        state.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if model.settings.edgeSharingEnabled {
            installEdgePortals()
        }
        if !edgePanels.isEmpty { showEffectLayers() }
    }

    private func dragMoved(to point: CGPoint) {
        state.cursor = point
        updateEdgeProximity(point)
        if let ring = state.ring, hypot(point.x - ring.center.x, point.y - ring.center.y) > ring.radius + 120 {
            dismissRing()
        }
    }

    private func held(at point: CGPoint) {
        guard model.settings.holdToShowNearby, state.targetedEdge == nil else { return }
        // Pausing right at an assigned edge means "use the edge", not the ring.
        if state.edgeProximity.values.contains(where: { $0 > 0.8 }) { return }
        if let ring = state.ring, hypot(point.x - ring.center.x, point.y - ring.center.y) < ring.radius + 120 { return }
        showRing(at: point)
    }

    private func dragEnded() {
        state.isDragging = false
        // The drop reaches our windows around the time the button is released;
        // keep them a moment so it isn't lost.
        timers.schedule(.teardown, after: teardownDelay) { [weak self] in
            self?.tearDownInteractive()
        }
    }

    private func tearDownInteractive() {
        dismissRing()
        for (edge, info) in edgePanels {
            info.panel.orderOut(nil)
            timers.cancel(.collapse(edge))
        }
        edgePanels.removeAll()
        state.edgeGeometry.removeAll()
        state.openEdges.removeAll()
        state.targetedEdge = nil
        state.edgeProximity.removeAll()
        hideEffectLayersIfIdle()
    }

    // MARK: - Ring of colleagues

    private func showRing(at point: CGPoint) {
        dismissRing()
        Log.ui.debug("Showing nearby colleagues at \(NSStringFromPoint(point), privacy: .public)")
        let peers = Array(model.nearbyForGesture.prefix(8))
        let radius: CGFloat = peers.count > 5 ? 165 : 132
        var center = point
        // Keep every orb on screen.
        if let visible = Self.screen(containing: point)?.visibleFrame {
            let margin = radius + Self.orbSize.width / 2
            center.x = min(max(center.x, visible.minX + margin), visible.maxX - margin)
            center.y = min(max(center.y, visible.minY + margin), visible.maxY - margin)
        }

        let slots = max(peers.count, 1)
        var positions: [String: CGPoint] = [:]
        for slot in 0..<slots {
            // Start at the top and go clockwise.
            let angle = Double.pi / 2 - Double(slot) * 2 * .pi / Double(slots)
            let position = CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
            let peer = peers.indices.contains(slot) ? peers[slot] : nil
            if let peer { positions[peer.id] = position }
            let view = NearbyOrbView(peer: peer, index: slot, state: state,
                                     photo: peer.flatMap { model.photo(forPeer: $0.id) }) { [weak self] urls in
                guard let self, let peer else { return }
                self.send(urls, to: peer, from: position, edge: nil)
            }
            let panel = makePanel(frame: CGRect(center: position, size: Self.orbSize), level: .popUpMenu, clickThrough: false)
            panel.contentView = NSHostingView(rootView: view)
            panel.orderFrontRegardless()
            orbPanels.append(panel)
        }
        state.ring = DragOverlayState.Ring(center: center, radius: radius, positions: positions, shownAt: .now)
        showEffectLayers()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func dismissRing() {
        orbPanels.forEach { $0.orderOut(nil) }
        orbPanels.removeAll()
        state.ring = nil
        state.targetedOrb = nil
    }

    // MARK: - Screen edges

    private func installEdgePortals() {
        for edge in ScreenEdge.allCases {
            guard model.settings.assignment(for: edge) != nil, let screen = Self.outerScreen(for: edge) else { continue }
            let frame = screen.frame
            let visible = screen.visibleFrame
            let view = EdgePortalView(edge: edge, globalMaxY: visible.maxY, state: state, model: model,
                                      onTargetChange: { [weak self] targeted in self?.edge(edge, targeted: targeted) },
                                      onDrop: { [weak self] urls in self?.dropped(urls, on: edge) })
            let panel = makePanel(frame: Self.edgeFrame(edge, frame: frame, visible: visible, open: false),
                                  level: .popUpMenu, clickThrough: false)
            panel.contentView = NSHostingView(rootView: view)
            panel.orderFrontRegardless()
            edgePanels[edge] = EdgePanel(panel: panel, frame: frame, visibleFrame: visible)
            Log.ui.debug("Edge portal ready: \(edge.rawValue, privacy: .public) at \(NSStringFromRect(panel.frame), privacy: .public)")
            state.edgeGeometry[edge] = (x: edge == .left ? frame.minX : frame.maxX, minY: visible.minY, maxY: visible.maxY)
        }
    }

    private func edge(_ edge: ScreenEdge, targeted: Bool) {
        Log.ui.debug("Edge \(edge.rawValue, privacy: .public) targeted: \(targeted)")
        if targeted {
            timers.cancel(.collapse(edge))
            state.targetedEdge = edge
            open(edge)
        } else {
            if state.targetedEdge == edge { state.targetedEdge = nil }
            timers.schedule(.collapse(edge), after: .milliseconds(250)) { [weak self] in
                self?.collapse(edge)
            }
        }
    }

    private func open(_ edge: ScreenEdge) {
        guard let info = edgePanels[edge], !state.openEdges.contains(edge) else { return }
        dismissRing()
        state.openEdges.insert(edge)
        // The cursor is already inside the strip, so growing the window keeps it the drop target.
        info.panel.setFrame(Self.edgeFrame(edge, frame: info.frame, visible: info.visibleFrame, open: true), display: true)
        showEffectLayers()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func collapse(_ edge: ScreenEdge) {
        guard let info = edgePanels[edge], state.targetedEdge != edge else { return }
        state.openEdges.remove(edge)
        info.panel.setFrame(Self.edgeFrame(edge, frame: info.frame, visible: info.visibleFrame, open: false), display: true)
    }

    private func dropped(_ urls: [URL], on edge: ScreenEdge) {
        Log.ui.info("Dropped \(urls.count) item(s) on the \(edge.rawValue, privacy: .public) edge")
        guard let peer = model.peer(for: edge), let x = state.edgeGeometry[edge]?.x else { return }
        send(urls, to: peer, from: CGPoint(x: x, y: state.cursor.y), edge: edge)
        state.targetedEdge = nil
        collapse(edge)
    }

    private func updateEdgeProximity(_ point: CGPoint) {
        var proximity: [ScreenEdge: Double] = [:]
        for (edge, geometry) in state.edgeGeometry where (geometry.minY...geometry.maxY).contains(point.y) {
            let distance = abs(point.x - geometry.x)
            if distance < Self.proximityRange {
                proximity[edge] = Double(1 - distance / Self.proximityRange)
            }
        }
        if proximity != state.edgeProximity { state.edgeProximity = proximity }
    }

    static func edgeFrame(_ edge: ScreenEdge, frame: CGRect, visible: CGRect, open: Bool) -> CGRect {
        let width = open ? openEdgeWidth : collapsedEdgeWidth
        let x = edge == .left ? frame.minX : frame.maxX - width
        return CGRect(x: x, y: visible.minY, width: width, height: visible.height)
    }

    /// The display whose outer side is this edge (the leftmost or rightmost one).
    static func outerScreen(for edge: ScreenEdge) -> NSScreen? {
        switch edge {
        case .left: NSScreen.screens.min { $0.frame.minX < $1.frame.minX }
        case .right: NSScreen.screens.max { $0.frame.maxX < $1.frame.maxX }
        }
    }

    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    // MARK: - Sending and effects

    private func send(_ urls: [URL], to peer: PeerDevice, from origin: CGPoint, edge: ScreenEdge?) {
        model.send(urls, to: peer.id)
        playBurst(at: origin, edge: edge, kind: .send)
        dismissRing()
    }

    /// Plays on this Mac when a request arrives, just above the request panel.
    func playArrival() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        playBurst(at: CGPoint(x: visible.maxX - IncomingPanelController.size.width / 2 - 16, y: visible.maxY),
                  edge: nil, kind: .arrival)
    }

    /// For Settings: plays the send effect at the outer right edge, then the
    /// arrival glow a colleague would see.
    func previewEffect() {
        guard let screen = Self.outerScreen(for: .right) else { return }
        playBurst(at: CGPoint(x: screen.frame.maxX, y: screen.visibleFrame.midY), edge: .right, kind: .send)
        timers.schedule(.previewArrival, after: .milliseconds(1400)) { [weak self] in
            self?.playArrival()
        }
    }

    private func playBurst(at origin: CGPoint, edge: ScreenEdge?, kind: DragOverlayState.Burst.Kind) {
        guard model.settings.proximityEffects else { return }
        state.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let burst = DragOverlayState.Burst(origin: origin, edge: edge, kind: kind, start: .now)
        state.bursts.append(burst)
        showEffectLayers()
        timers.schedule(.expireBurst(burst.id), after: .milliseconds(Int(ProximityEffects.burstDuration * 1000) + 100)) { [weak self] in
            self?.state.bursts.removeAll { $0.id == burst.id }
            self?.hideEffectLayersIfIdle()
        }
    }

    private func showEffectLayers() {
        guard model.settings.proximityEffects else { return }
        for screen in NSScreen.screens {
            let key = NSStringFromRect(screen.frame)
            if effectPanels[key] == nil {
                // Click-through and below the interactive panels.
                let panel = makePanel(frame: screen.frame, level: .statusBar, clickThrough: true)
                panel.contentView = NSHostingView(rootView: ProximityEffectView(screenFrame: screen.frame, state: state))
                effectPanels[key] = panel
            }
            effectPanels[key]?.orderFrontRegardless()
        }
    }

    private func hideEffectLayersIfIdle() {
        guard !state.isAnimating, !state.isDragging else { return }
        effectPanels.values.forEach { $0.orderOut(nil) }
    }

    private func makePanel(frame: CGRect, level: NSWindow.Level, clickThrough: Bool) -> NSPanel {
        let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = clickThrough
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

/// Never takes focus from the app the user is dragging from.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension CGRect {
    init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}
