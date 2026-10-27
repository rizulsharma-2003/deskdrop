import CryptoKit
import Foundation
import Security

/// Installs a DeskDrop update over the copy of DeskDrop this helper is embedded
/// in. Every check is made here, independently of the (sandboxed) app that asks:
///
/// 1. The package is signed with the public key built into this helper.
/// 2. It's for this app (bundle ID) and newer than the installed version.
/// 3. The archive is exactly the one that was signed (size and SHA-256).
/// 4. The unpacked app has a valid code signature, and if this copy is signed by
///    a developer team, the update is signed by the same team.
///
/// Then the quarantine flag is cleared (the files came from another Mac, already
/// verified) and the old app goes to the Trash as the new one takes its place.
///
/// The app replaced is the original, not the read-only copy macOS runs a
/// quarantined download from (see `AppLocation`), so the update also ends the
/// translocation: the new copy has no quarantine flag.
struct Installer {
    enum Failure: LocalizedError {
        case notConfigured
        case notInsideApp
        case readOnlyLocation(String)
        case package(UpdatePackage.Failure)
        case notNewer(String)
        case systemTooOld(String)
        case badArchive
        case badCodeSignature
        case wrongTeam
        case cantReplace(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "This copy of DeskDrop wasn’t built with an update key."
            case .notInsideApp: "The updater isn’t inside DeskDrop.app."
            case .readOnlyLocation(let folder):
                "DeskDrop can’t replace itself in “\(folder)”. Move DeskDrop to your Applications folder, open it from there, and try again."
            case .package(.badSignature): "The update isn’t signed by DeskDrop’s publisher."
            case .package(.archiveMismatch): "The update is damaged or incomplete."
            case .package: "This isn’t a DeskDrop update."
            case .notNewer(let version): "DeskDrop \(version) or newer is already installed."
            case .systemTooOld(let version): "This update needs macOS \(version) or later."
            case .badArchive: "The update’s app couldn’t be unpacked."
            case .badCodeSignature: "The update’s app has a broken code signature."
            case .wrongTeam: "The update is signed by a different developer than this copy of DeskDrop."
            case .cantReplace(let reason): "DeskDrop couldn’t be replaced: \(reason)"
            }
        }
    }

    /// The helper's own bundle: …/DeskDrop.app/Contents/XPCServices/DeskDropUpdater.xpc
    let helperBundle: Bundle

    /// Copies the package out of `handle`, then checks and installs the copy.
    /// Returns where the new app is.
    func install(from handle: FileHandle) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDrop-\(UUID().uuidString).deskdropupdate")
        FileManager.default.createFile(atPath: copy.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: copy) }
        let output = try FileHandle(forWritingTo: copy)
        var written: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            written += Int64(chunk.count)
            guard written <= UpdatePackage.maxArchiveBytes + Int64(UpdatePackage.maxManifestBytes) + 1024 else {
                try? output.close()
                throw Failure.package(.tooLarge)
            }
            try output.write(contentsOf: chunk)
        }
        try output.close()
        return try install(packageAt: copy)
    }

    @discardableResult
    func install(packageAt packageURL: URL) throws -> URL {
        guard let keyHex = helperBundle.object(forInfoDictionaryKey: UpdaterService.publicKeyInfoKey) as? String,
              let publicKey = UpdatePackage.publicKey(hex: keyHex) else { throw Failure.notConfigured }
        let runningApp = helperBundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let appURL = AppLocation.original(of: runningApp)
        guard appURL.pathExtension == "app", let app = Bundle(url: appURL), let bundleID = app.bundleIdentifier,
              let installed = (app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init) else {
            throw Failure.notInsideApp
        }
        // A disk image, or a folder this user can't change: say so before unpacking anything.
        let folder = appURL.deletingLastPathComponent()
        let readOnlyVolume = (try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        guard !readOnlyVolume, FileManager.default.isWritableFile(atPath: folder.path) else {
            throw Failure.readOnlyLocation(folder.path)
        }

        let manifest: UpdateManifest
        do {
            manifest = try UpdatePackage.verifyPackage(at: packageURL, publicKey: publicKey, bundleID: bundleID).manifest
        } catch let failure as UpdatePackage.Failure {
            throw Failure.package(failure)
        }
        guard let version = AppVersion(manifest.version), version > installed else { throw Failure.notNewer(installed.description) }
        if let minimum = AppVersion(manifest.minimumSystemVersion) {
            let system = ProcessInfo.processInfo.operatingSystemVersion
            let current = AppVersion("\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")
            if let current, current < minimum { throw Failure.systemTooOld(manifest.minimumSystemVersion) }
        }

        // Unpack on the same volume as the app, so the final move is a rename.
        let fileManager = FileManager.default
        let work: URL
        do {
            work = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        } catch {
            throw Failure.cantReplace(error.localizedDescription)
        }
        defer { try? fileManager.removeItem(at: work) }
        let zip = work.appendingPathComponent("update.zip")
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try UpdatePackage.extractArchive(from: packageURL, to: zip)
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0,
              let apps = try? fileManager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "app" }),
              apps.count == 1, let newApp = apps.first,
              let newBundle = Bundle(url: newApp), newBundle.bundleIdentifier == bundleID,
              newBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == manifest.version else {
            throw Failure.badArchive
        }
        try checkCodeSignature(of: newApp, comparedWith: appURL)
        clearQuarantine(newApp)

        // The old copy goes to the Trash, so nothing is lost if anything goes wrong.
        var trashed: NSURL?
        do {
            try fileManager.trashItem(at: appURL, resultingItemURL: &trashed)
        } catch {
            throw Failure.cantReplace(error.localizedDescription)
        }
        do {
            try fileManager.moveItem(at: newApp, to: appURL)
        } catch {
            if let trashed { try? fileManager.moveItem(at: trashed as URL, to: appURL) }
            throw Failure.cantReplace(error.localizedDescription)
        }
        return appURL
    }

    private func checkCodeSignature(of newApp: URL, comparedWith installedApp: URL) throws {
        guard let code = staticCode(newApp) else { throw Failure.badCodeSignature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw Failure.badCodeSignature }
        // A copy signed by a developer team only accepts updates from that team.
        if let team = teamID(installedApp), teamID(newApp) != team { throw Failure.wrongTeam }
    }

    private func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    private func teamID(_ url: URL) -> String? {
        guard let code = staticCode(url) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Removes the quarantine flag from every file in the new app.
    private func clearQuarantine(_ url: URL) {
        removexattr(url.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items {
            removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    private func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
