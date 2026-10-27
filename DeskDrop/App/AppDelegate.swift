import AppKit

/// Closing the main window keeps DeskDrop running in the menu bar so colleagues
/// can still send you files and messages. By default ⌘Q does the same (and leaves
/// the Dock); "Quit DeskDrop Completely" in the menu bar stops it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let lifecycle = AppLifecycleManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        lifecycle.didFinishLaunching()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { lifecycle.showMainWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle.shouldTerminate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycle.willTerminate()
    }
}
