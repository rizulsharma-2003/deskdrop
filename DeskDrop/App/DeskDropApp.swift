import SwiftUI

enum SceneID {
    static let main = "main"
    static let history = "history"
}

@main
struct DeskDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let model = appDelegate.lifecycle.model

        Window("DeskDrop", id: SceneID.main) {
            MainWindowView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            DeskDropCommands(model: model)
        }

        Window("Recent Activity", id: SceneID.history) {
            TransferHistoryView()
                .environment(model)
        }
        .defaultSize(width: 780, height: 460)

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            MenuBarContentView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model) { openWindow in
                appDelegate.lifecycle.openWindow = openWindow
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Menu bar commands for the app menus.
struct DeskDropCommands: Commands {
    let model: DeskDropViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandMenu("Sharing") {
            Toggle("Available for Sharing", isOn: Binding(get: { model.isSharingEnabled },
                                                          set: { model.setSharingEnabled($0) }))
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Refresh Nearby Macs") { model.refresh() }
                .keyboardShortcut("r")
        }

        CommandGroup(before: .windowList) {
            Button("Nearby") {
                model.mainSection = .nearby
                openWindow(id: SceneID.main)
            }
            .keyboardShortcut("1")
            Button("Messages") {
                model.showMessages()
                openWindow(id: SceneID.main)
            }
            .keyboardShortcut("2")
            Button("Recent Activity") { openWindow(id: SceneID.history) }
                .keyboardShortcut("y")
            Divider()
        }
    }
}
