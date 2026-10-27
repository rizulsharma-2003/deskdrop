import AppKit

/// Notices file drags that start in any app (usually Finder).
///
/// macOS doesn't tell apps when a file is long-pressed, and a sandboxed app can't
/// inspect Finder's selection. What it can observe is system-wide state: a global
/// mouse-down, whether the left button is still held, where the cursor is, and
/// whether the drag pasteboard changed and now offers file URLs. Only the
/// pasteboard's *types* are checked — the files themselves reach DeskDrop through
/// an ordinary drop that the user performs.
@MainActor
final class GlobalDragMonitor {
    var onFileDragBegan: ((CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    /// The cursor stayed (almost) still for `holdDelay` while dragging files.
    var onHold: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    var holdDelay: TimeInterval = 0.75
    /// Movement under this many points still counts as holding still.
    var holdTolerance: CGFloat = 6

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var monitor: Any?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var baselineChangeCount = 0
    private var isFileDrag = false
    private var anchor = CGPoint.zero
    private var anchorTime: TimeInterval = 0
    private var holdFired = false

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        // Mouse events can be observed globally without Accessibility permission.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { @Sendable [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handle(type) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        finishTracking()
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            baselineChangeCount = dragPasteboard.changeCount
            beginTracking()
        case .leftMouseDragged where timer == nil:
            // A press that began before monitoring started.
            baselineChangeCount = dragPasteboard.changeCount
            beginTracking()
        default:
            break
        }
    }

    /// Polls at display rate only while the button is down. During a drag the
    /// source app owns the mouse events, so polling is the reliable signal.
    private func beginTracking() {
        guard timer == nil else { return }
        Log.ui.debug("Mouse down elsewhere; watching for a file drag")
        isFileDrag = false
        // Keep App Nap from throttling the timer during the gesture.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Following a drag")
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { @Sendable [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        // The combined session state includes posted events (remote control,
        // accessibility tools), not just the physical mouse.
        guard CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            Log.ui.debug("Button released; pasteboard changed: \(self.dragPasteboard.changeCount != self.baselineChangeCount)")
            finishTracking()
            return
        }
        let location = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime

        guard isFileDrag else {
            guard dragPasteboard.changeCount != baselineChangeCount else { return }
            guard dragPasteboard.types?.contains(.fileURL) == true else {
                // Text, a selection or something else is being dragged; ignore it.
                baselineChangeCount = dragPasteboard.changeCount
                return
            }
            isFileDrag = true
            resetHold(at: location, time: now)
            Log.ui.info("File drag detected")
            onFileDragBegan?(location)
            return
        }

        onDragMoved?(location)
        if hypot(location.x - anchor.x, location.y - anchor.y) > holdTolerance {
            resetHold(at: location, time: now)
        } else if !holdFired, now - anchorTime >= holdDelay {
            holdFired = true
            Log.ui.info("Dragged file held still")
            onHold?(location)
        }
    }

    private func resetHold(at location: CGPoint, time: TimeInterval) {
        anchor = location
        anchorTime = time
        holdFired = false
    }

    private func finishTracking() {
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if isFileDrag {
            isFileDrag = false
            onDragEnded?()
        }
    }
}
