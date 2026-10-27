import CryptoKit
import Foundation

/// What an update says about itself. The publisher signs these exact bytes.
struct UpdateManifest: Codable, Equatable, Sendable {
    var format = 1
    let bundleID: String
    let version: String
    let build: String
    let minimumSystemVersion: String
    let archiveSize: Int64
    /// Lowercase hex SHA-256 of the archive.
    let archiveSHA256: String
    /// What's new, in Markdown.
    let notes: String
    let publishedAt: Date
}

/// An update's manifest and the publisher's signature, as Macs announce it.
struct UpdateOffer: Codable, Equatable, Sendable {
    let manifest: Data
    let signature: Data
}

/// A DeskDrop update: one `.deskdropupdate` file, made by `scripts/build-release.sh`
/// and signed with the publisher's Ed25519 key. Every Mac checks the signature
/// against the public key built into its own copy of DeskDrop, and the installer
/// helper checks it again before replacing anything.
///
///     "DDUPDATE"          8 bytes
///     manifest length     UInt32, big-endian
///     manifest            JSON (`UpdateManifest`)
///     signature length    UInt32, big-endian (64)
///     signature           Ed25519 over the manifest bytes
///     archive             zip of DeskDrop.app (`ditto -c -k --keepParent`)
enum UpdatePackage {
    enum Failure: Error, Equatable {
        case notAPackage
        case badSignature
        case wrongApp
        case tooLarge
        case archiveMismatch
        case unreadable
    }

    static let fileExtension = "deskdropupdate"
    static let maxManifestBytes = 16_384
    static let maxNotesCharacters = 8_000
    static let maxArchiveBytes: Int64 = 300_000_000
    private static let magic = Data("DDUPDATE".utf8)

    /// A public key from its 64-character hex form (as built into Info.plist).
    static func publicKey(hex: String) -> Curve25519.Signing.PublicKey? {
        let clean = hex.trimmingCharacters(in: .whitespaces).lowercased()
        guard clean.count == 64 else { return nil }
        var bytes = Data(capacity: 32)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: bytes)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Checking

    /// The manifest, if `offer` is signed by `publicKey` and is for `bundleID`.
    static func verify(_ offer: UpdateOffer, publicKey: Curve25519.Signing.PublicKey, bundleID: String) throws -> UpdateManifest {
        guard offer.manifest.count <= maxManifestBytes, offer.signature.count == 64 else { throw Failure.notAPackage }
        guard publicKey.isValidSignature(offer.signature, for: offer.manifest) else { throw Failure.badSignature }
        let manifest = try decodeManifest(offer.manifest)
        guard manifest.format == 1, manifest.bundleID == bundleID, AppVersion(manifest.version) != nil,
              manifest.archiveSize > 0, manifest.archiveSize <= maxArchiveBytes,
              manifest.archiveSHA256.count == 64, manifest.notes.count <= maxNotesCharacters else { throw Failure.wrongApp }
        return manifest
    }

    /// Reads a package's header (manifest and signature) without checking it.
    static func readOffer(at url: URL) throws -> (offer: UpdateOffer, archiveOffset: UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: magic.count) == magic else { throw Failure.notAPackage }
        let manifestLength = try readLength(handle)
        guard manifestLength > 0, manifestLength <= maxManifestBytes,
              let manifest = try handle.read(upToCount: manifestLength), manifest.count == manifestLength else {
            throw Failure.notAPackage
        }
        let signatureLength = try readLength(handle)
        guard signatureLength == 64, let signature = try handle.read(upToCount: 64), signature.count == 64 else {
            throw Failure.notAPackage
        }
        return (UpdateOffer(manifest: manifest, signature: signature), try handle.offset())
    }

    /// Checks everything: the signature, and that the archive is exactly the one signed for.
    static func verifyPackage(at url: URL, publicKey: Curve25519.Signing.PublicKey,
                              bundleID: String) throws -> (manifest: UpdateManifest, offer: UpdateOffer) {
        let (offer, offset) = try readOffer(at: url)
        let manifest = try verify(offer, publicKey: publicKey, bundleID: bundleID)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= offset, Int64(fileSize - offset) == manifest.archiveSize else { throw Failure.archiveMismatch }
        try handle.seek(toOffset: offset)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        guard hex(Data(hasher.finalize())) == manifest.archiveSHA256 else { throw Failure.archiveMismatch }
        return (manifest, offer)
    }

    /// Copies the archive out of a package into its own zip file.
    static func extractArchive(from url: URL, to destination: URL) throws {
        let (_, offset) = try readOffer(at: url)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        try input.seek(toOffset: offset)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    // MARK: - Making

    /// Writes a signed package of `archive` (a zip of the app).
    static func write(archive: URL, bundleID: String, version: String, build: String, minimumSystemVersion: String,
                      notes: String, signingKey: Curve25519.Signing.PrivateKey, to url: URL) throws -> UpdateManifest {
        let archiveData = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard Int64(archiveData.count) <= maxArchiveBytes else { throw Failure.tooLarge }
        let manifest = UpdateManifest(bundleID: bundleID, version: version, build: build,
                                      minimumSystemVersion: minimumSystemVersion, archiveSize: Int64(archiveData.count),
                                      archiveSHA256: hex(Data(SHA256.hash(data: archiveData))),
                                      notes: String(notes.prefix(maxNotesCharacters)), publishedAt: .now)
        let manifestData = try encodeManifest(manifest)
        let signature = try signingKey.signature(for: manifestData)
        var file = magic
        file.append(length(manifestData.count))
        file.append(manifestData)
        file.append(length(signature.count))
        file.append(signature)
        file.append(archiveData)
        try file.write(to: url, options: .atomic)
        return manifest
    }

    static func encodeManifest(_ manifest: UpdateManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    static func decodeManifest(_ data: Data) throws -> UpdateManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(UpdateManifest.self, from: data) else { throw Failure.notAPackage }
        return manifest
    }

    private static func length(_ value: Int) -> Data {
        withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
    }

    private static func readLength(_ handle: FileHandle) throws -> Int {
        guard let bytes = try handle.read(upToCount: 4), bytes.count == 4 else { throw Failure.notAPackage }
        return Int(bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }
}

/// A version like "1.7.0", compared number by number ("1.10" is newer than "1.9").
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else {
                return nil
            }
            numbers.append(number)
        }
        components = numbers
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
