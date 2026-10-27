import AppKit
import SwiftUI

/// A floating, non-activating panel in the top-right corner of the screen that
/// presents incoming requests whether or not the main window is open, and without
/// stealing focus from whatever the recipient is doing.
@MainActor
final class IncomingPanelController {
    static let size = CGSize(width: 384, height: 196)

    private let model: DeskDropViewModel
    private var panel: NSPanel?
    private var isShown = false

    init(model: DeskDropViewModel) {
        self.model = model
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !isShown else { return }
        isShown = true
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isShown, let panel else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = IncomingPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                  styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        panel.title = String(localized: "Incoming Transfer")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.setAccessibilityIdentifier("incomingPanelWindow")

        let hosting = NSHostingView(rootView: IncomingPanelView().environment(model))
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            // Liquid Glass: the panel itself is a sheet of glass.
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Self.size))
            glass.cornerRadius = 24
            glass.autoresizingMask = [.width, .height]
            glass.contentView = hosting
            panel.isOpaque = false
            panel.contentView = glass
        } else {
            let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.autoresizingMask = [.width, .height]
            effect.addSubview(hosting)
            panel.contentView = effect
        }
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.size.width - 16,
                                     y: visible.maxY - Self.size.height - 12))
    }
}

private final class IncomingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
