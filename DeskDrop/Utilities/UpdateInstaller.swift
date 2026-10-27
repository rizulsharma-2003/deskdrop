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

    func install(packageAt url: URL) async throws {
        let connection = NSXPCConnection(serviceName: UpdaterService.name)
        connection.remoteObjectInterface = NSXPCInterface(with: UpdaterXPC.self)
        connection.resume()
        defer { connection.invalidate() }
        let message: String? = try await withCheckedThrowingContinuation { continuation in
            let resumed = UncheckedSendable(ResumeOnce(continuation))
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
                resumed.value.resume(throwing: Failure.helperUnavailable)
            }
            guard let updater = proxy as? UpdaterXPC else {
                resumed.value.resume(throwing: Failure.helperUnavailable)
                return
            }
            updater.installUpdate(atPath: url.path) { @Sendable message in
                resumed.value.resume(returning: message)
            }
        }
        if let message { throw Failure.helper(message) }
    }

    /// Opens the newly installed copy, which waits for this one to quit before it
    /// starts sharing, then quits this one.
    static func relaunch(quit: () -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [RelaunchSupport.waitArgument, String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { @Sendable _, error in
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

/// The new copy of DeskDrop waits for the old one to finish quitting, so the two
/// never share the network at once.
enum RelaunchSupport {
    static let waitArgument = "-DeskDropRelaunchedFrom"

    /// The process ID of the copy that's quitting, if this launch is a relaunch.
    static var previousProcess: pid_t? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: waitArgument), index + 1 < arguments.count else { return nil }
        return pid_t(arguments[index + 1])
    }

    /// Waits (up to 10 s) for that copy to quit.
    static func waitForPreviousCopy() async {
        guard let pid = previousProcess, let previous = NSRunningApplication(processIdentifier: pid) else { return }
        for _ in 0..<100 where !previous.isTerminated {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
