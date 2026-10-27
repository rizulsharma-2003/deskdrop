import AppKit

/// Asks the installer helper (`DeskDropUpdater.xpc`, outside the sandbox) to put
/// an update in place, then relaunches into the new version.
@MainActor
struct UpdateInstaller: UpdateInstalling {
    enum Failure: LocalizedError {
        case helperUnavailable
        case helper(String)

        var errorDescription: String? {
            switch self {
            case .helperUnavailable: String(localized: "DeskDrop’s updater couldn’t be started.")
            case .helper(let message): message
            }
        }
    }

    func install(packageAt url: URL) async throws -> URL {
        let file = UncheckedSendable(try FileHandle(forReadingFrom: url))
        defer { try? file.value.close() }
        let connection = NSXPCConnection(serviceName: UpdaterService.name)
        connection.remoteObjectInterface = NSXPCInterface(with: UpdaterXPC.self)
        connection.resume()
        defer { connection.invalidate() }
        let installedPath: String = try await withCheckedThrowingContinuation { continuation in
            let resumed = UncheckedSendable(ResumeOnce(continuation))
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
                resumed.value.resume(throwing: Failure.helperUnavailable)
            }
            guard let updater = proxy as? UpdaterXPC else {
                resumed.value.resume(throwing: Failure.helperUnavailable)
                return
            }
            updater.installUpdate(file.value) { @Sendable installedPath, failure in
                if let installedPath, failure == nil {
                    resumed.value.resume(returning: installedPath)
                } else {
                    resumed.value.resume(throwing: Failure.helper(failure ?? String(localized: "The update couldn’t be installed.")))
                }
            }
        }
        return URL(fileURLWithPath: installedPath)
    }

    /// Opens the newly installed copy at `app`, which waits for this one to quit
    /// before it starts sharing, then quits this one. (A sandboxed app can't pass
    /// launch arguments, so the new copy finds this one by its location instead.)
    static func relaunch(_ app: URL, quit: () -> Void) {
        #if DEBUG
        // A test copy must not come back as a real DeskDrop with your settings.
        if UITestSupport.isUITesting {
            Log.app.notice("UI testing: installed; quitting without relaunching")
            quit()
            return
        }
        #endif
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { @Sendable _, error in
            if let error { Log.app.error("Relaunch failed: \(error.localizedDescription, privacy: .public)") }
        }
        quit()
    }
}

/// Resumes a continuation once, whichever of the reply or the error handler comes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let taken = continuation
        continuation = nil
        return taken
    }
}

/// After an update, the new copy of DeskDrop waits for the old one (same app,
/// same place) to finish quitting, so the two never share the network at once.
enum RelaunchSupport {
    /// Other running copies of this app at this location, including one macOS
    /// ran from a translocated copy of it (the copy an update replaced).
    @MainActor
    static var previousCopies: [NSRunningApplication] {
        let me = ProcessInfo.processInfo.processIdentifier
        let path = AppLocation.original(of: Bundle.main.bundleURL).standardizedFileURL.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { other in
                guard other.processIdentifier != me, let url = other.bundleURL else { return false }
                return url.standardizedFileURL.path == path || AppLocation.original(of: url).standardizedFileURL.path == path
            }
    }

    /// Waits (up to 10 s) for them to quit.
    @MainActor
    static func waitForPreviousCopy() async {
        let previous = previousCopies
        guard !previous.isEmpty else { return }
        Log.app.notice("Waiting for the previous copy of DeskDrop to quit")
        for _ in 0..<100 where previous.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
