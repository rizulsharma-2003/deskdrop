import Foundation

/// The installer helper embedded in DeskDrop (`DeskDropUpdater.xpc`). It runs
/// outside the App Sandbox, because a sandboxed app can't replace itself or clear
/// the quarantine flag on files it writes. It only ever installs a package signed
/// with the publisher's key, newer than the copy of DeskDrop it's embedded in,
/// over that copy.
@objc protocol UpdaterXPC {
    /// Installs the package read from `package`, an open file (the helper can't
    /// look inside the app's sandbox container, and works on its own copy so the
    /// file can't change between checking and installing). Replies with the path
    /// of the installed app to relaunch, which isn't where the running copy is
    /// when macOS translocated it, or with a message to show.
    func installUpdate(_ package: FileHandle, withReply reply: @escaping @Sendable (_ installedPath: String?, _ failure: String?) -> Void)
}

enum UpdaterService {
    static let name = "com.deskdrop.app.Updater"
    /// Info.plist key holding the publisher's public key, as 64 hex characters.
    static let publicKeyInfoKey = "DeskDropUpdatePublicKey"
}
