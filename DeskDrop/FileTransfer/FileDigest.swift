import CryptoKit
import Foundation

/// Streaming SHA-256 so large files are never read into memory at once.
enum FileDigest {
    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// Hashes the file in 1 MB chunks. Checks for task cancellation between chunks.
    static func sha256Hex(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
