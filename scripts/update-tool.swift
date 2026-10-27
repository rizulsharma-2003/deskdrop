// Signs DeskDrop updates. Built by scripts/update-key.sh and scripts/build-release.sh
// together with Shared/UpdatePackage.swift, so the file format has one definition.
//
//   update-tool keygen                           new private key (hex) on stdout
//   update-tool public-key                       private key (hex) on stdin → public key (hex)
//   update-tool package --app A --out F [--notes N]
//                                                private key on stdin → signed .deskdropupdate
//   update-tool verify --package F --public-key K
//
// The private key only ever travels through stdin, never the command line.

import CryptoKit
import Foundation

@main
struct UpdateTool {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard !arguments.isEmpty else { fail("usage: update-tool keygen | public-key | package | verify") }
        let command = arguments.removeFirst()
        do {
            switch command {
            case "keygen":
                print(UpdatePackage.hex(Curve25519.Signing.PrivateKey().rawRepresentation))
            case "public-key":
                print(UpdatePackage.hex(try readPrivateKey().publicKey.rawRepresentation))
            case "package":
                try package(options(arguments))
            case "verify":
                try verify(options(arguments))
            default:
                fail("unknown command \(command)")
            }
        } catch {
            fail("\(error)")
        }
    }

    private static func package(_ options: [String: String]) throws {
        guard let appPath = options["app"], let outPath = options["out"] else { fail("package needs --app and --out") }
        let key = try readPrivateKey()
        let appURL = URL(fileURLWithPath: appPath)
        guard let info = Bundle(url: appURL)?.infoDictionary,
              let bundleID = info["CFBundleIdentifier"] as? String,
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { fail("\(appPath) isn't an app") }
        // The new version must trust the same key, or the update after it couldn't be installed.
        let embedded = info[UpdaterService.publicKeyInfoKey] as? String ?? ""
        guard embedded.lowercased() == UpdatePackage.hex(key.publicKey.rawRepresentation) else {
            fail("the app was built with a different update key (\(embedded.isEmpty ? "none" : embedded)); rebuild it")
        }
        let notes = try options["notes"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("deskdrop-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent("DeskDrop.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", appURL.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { fail("ditto failed") }
        let manifest = try UpdatePackage.write(archive: zip, bundleID: bundleID, version: version, build: build,
                                               minimumSystemVersion: info["LSMinimumSystemVersion"] as? String ?? "14.0",
                                               notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                                               signingKey: key, to: URL(fileURLWithPath: outPath))
        print("Signed DeskDrop \(manifest.version) (\(manifest.build)), \(manifest.archiveSize) bytes")
    }

    private static func verify(_ options: [String: String]) throws {
        guard let path = options["package"], let hex = options["public-key"],
              let key = UpdatePackage.publicKey(hex: hex) else { fail("verify needs --package and --public-key") }
        let (offer, _) = try UpdatePackage.readOffer(at: URL(fileURLWithPath: path))
        let bundleID = try UpdatePackage.decodeManifest(offer.manifest).bundleID
        let (manifest, _) = try UpdatePackage.verifyPackage(at: URL(fileURLWithPath: path), publicKey: key, bundleID: bundleID)
        print("OK: DeskDrop \(manifest.version) (\(manifest.build)) for \(manifest.bundleID)")
    }

    private static func readPrivateKey() throws -> Curve25519.Signing.PrivateKey {
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let hex = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count == 64, let bytes = hexBytes(hex) else { fail("expected a 64-character hex private key on stdin") }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    }

    private static func hexBytes(_ hex: String) -> Data? {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func options(_ arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < arguments.count {
            if arguments[index].hasPrefix("--") { result[String(arguments[index].dropFirst(2))] = arguments[index + 1] }
            index += 2
        }
        return result
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("update-tool: \(message)\n".utf8))
        exit(1)
    }
}
