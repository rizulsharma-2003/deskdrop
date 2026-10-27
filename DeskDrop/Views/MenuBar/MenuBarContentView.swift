import SwiftUI

/// The menu bar menu. Works whether or not the main window is open.
struct MenuBarContentView: View {
    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.networkStatus.title)
        if case .ready(let count) = model.networkStatus {
            Text(count == 1 ? "1 colleague nearby" : "\(count) colleagues nearby")
        }

        let pending = model.pendingIncoming.count
        if pending > 0 {
            Divider()
            Button(pending == 1 ? "Review Incoming File…" : "Review \(pending) Incoming Transfers…") {
                showMainWindow()
            }
        }

        if let available = model.updates.available {
            Divider()
            Button("Update to DeskDrop \(available.manifest.version)…") {
                showMainWindow()
                model.showingUpdate = true
            }
        }

        Divider()
        Toggle("Available for Sharing", isOn: Binding(get: { model.isSharingEnabled },
                                                      set: { model.setSharingEnabled($0) }))
        Button("Refresh Nearby Macs") { model.refresh() }
            .disabled(!model.isSharingEnabled)

        Divider()
        Button("Open DeskDrop") { showMainWindow() }
        Button(model.unreadMessageCount > 0 ? "Messages (\(model.unreadMessageCount) unread)" : "Messages") {
            model.showMessages()
            showMainWindow()
        }
        Button("Recent Activity") {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            openWindow(id: SceneID.history)
            NSApp.activate()
        }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()
        Button(model.settings.keepRunningInMenuBar ? "Quit DeskDrop Completely" : "Quit DeskDrop") {
            model.onQuitCompletely?()
        }
        .keyboardShortcut("q")
    }

    private func showMainWindow() {
        if let show = model.onShowMainWindow {
            show()
        } else {
            openWindow(id: SceneID.main)
            NSApp.activate()
        }
    }
}

/// The menu bar icon, which changes while requests are waiting. It exists for the
/// app's whole lifetime, so it also hands SwiftUI's `openWindow` to AppKit code
/// that needs to reopen the main window (e.g. a Dock click with no windows open).
struct MenuBarLabel: View {
    let model: DeskDropViewModel
    let onOpenWindowAvailable: (OpenWindowAction) -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.pendingIncoming.isEmpty {
                Image("MenuBarIcon")
                    .accessibilityLabel(Text("DeskDrop"))
            } else {
                Image(systemName: "tray.and.arrow.down.fill")
                    .accessibilityLabel(Text("DeskDrop, incoming transfer waiting"))
            }
        }
        .onAppear { onOpenWindowAvailable(openWindow) }
    }
}
