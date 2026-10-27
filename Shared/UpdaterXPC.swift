import Foundation

/// The installer helper embedded in DeskDrop (`DeskDropUpdater.xpc`). It runs
/// outside the App Sandbox, because a sandboxed app can't replace itself or clear
/// the quarantine flag on files it writes. It only ever installs a package signed
/// with the publisher's key, newer than the copy of DeskDrop it's embedded in,
/// over that copy.
@objc protocol UpdaterXPC {
    /// Installs the package at `path`. Replies nil on success, or a message to show.
    func installUpdate(atPath path: String, withReply reply: @escaping @Sendable (String?) -> Void)
}

enum UpdaterService {
    static let name = "com.deskdrop.app.Updater"
    /// Info.plist key holding the publisher's public key, as 64 hex characters.
    static let publicKeyInfoKey = "DeskDropUpdatePublicKey"
}
