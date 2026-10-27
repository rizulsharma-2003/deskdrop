import Foundation

/// Answers DeskDrop's requests to install an update. Only the app this helper is
/// embedded in can connect to it.
final class UpdaterEndpoint: NSObject, UpdaterXPC, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: UpdaterXPC.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func installUpdate(_ package: FileHandle, withReply reply: @escaping @Sendable (String?, String?) -> Void) {
        do {
            let installed = try Installer(helperBundle: .main).install(from: package)
            reply(installed.path, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }
}

let endpoint = UpdaterEndpoint()
let listener = NSXPCListener.service()
listener.delegate = endpoint
listener.resume()
