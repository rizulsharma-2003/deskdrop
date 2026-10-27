import AppKit
import Foundation
import Testing
@testable import DeskDrop

@Suite("Finder drop handling")
@MainActor
struct DropHandlingTests {
    /// `NSItemProvider` calls back on a background queue. This guards against the
    /// completion being inferred as main-actor isolated, which traps at runtime.
    @Test("File URLs load from an item provider without isolation traps")
    func loadsFileURL() async throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let file = try root.file("dropped.txt", contents: Data("hello".utf8))
        let provider = NSItemProvider(object: file as NSURL)

        let loaded = await provider.loadFileURL()

        #expect(loaded?.standardizedFileURL == file.standardizedFileURL)
    }

    @Test("Non-file URLs such as web links are ignored")
    func ignoresWebURLs() async throws {
        let url = try #require(URL(string: "https://example.com/file.pdf"))
        let provider = NSItemProvider(object: url as NSURL)
        #expect(await provider.loadFileURL() == nil)
    }
}
