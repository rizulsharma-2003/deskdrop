import AppKit
import Foundation
import Network
import Testing
@testable import DeskDrop

@Suite("Link previews")
struct LinkPreviewTests {
    private let hash = String(repeating: "a", count: 64)

    @Test("The first web link is found where Markdown makes links")
    func firstLink() {
        #expect(LinkPreview.firstLink(in: "see https://apple.com/mac and https://b.example")?.absoluteString
                == "https://apple.com/mac")
        #expect(LinkPreview.firstLink(in: "[the wiki](https://wiki.example/start)")?.absoluteString
                == "https://wiki.example/start")
        #expect(LinkPreview.firstLink(in: "www.example.com")?.absoluteString == "http://www.example.com")
        #expect(LinkPreview.firstLink(in: "mail me@example.com") == nil, "Email isn't a page")
        #expect(LinkPreview.firstLink(in: "`https://code.example`") == nil, "Not inside code")
        #expect(LinkPreview.firstLink(in: "```\nhttps://block.example\n```") == nil)
        #expect(LinkPreview.firstLink(in: "[x](javascript:alert(1))") == nil)
        #expect(LinkPreview.firstLink(in: "no links here") == nil)
    }

    @Test("A message that's only a link can be replaced by its preview")
    func onlyLink() {
        #expect(LinkPreview.isOnlyLink("https://apple.com"))
        #expect(LinkPreview.isOnlyLink("  https://apple.com/mac  "))
        #expect(!LinkPreview.isOnlyLink("look: https://apple.com"))
        #expect(!LinkPreview.isOnlyLink("https://a.example https://b.example"))
        #expect(!LinkPreview.isOnlyLink("hello"))
    }

    @Test("A preview must belong to the message's first link and have something to show")
    func validation() throws {
        let url = try #require(URL(string: "https://apple.com/mac"))
        let text = "New Macs: https://apple.com/mac"
        let good = LinkPreview(url: url, title: " Mac\n- Apple\u{202E} ", imageHash: hash, imageWidth: 600, imageHeight: 315)
        let clean = try #require(good.validated(for: text))
        #expect(clean.title == "Mac - Apple")
        #expect(clean.host == "apple.com")

        let other = LinkPreview(url: try #require(URL(string: "https://evil.example")), title: "Apple")
        #expect(other.validated(for: text) == nil, "A preview for a link that isn't in the message is dropped")
        #expect(LinkPreview(url: url, title: nil).validated(for: text) == nil, "Nothing to show")
        #expect(LinkPreview(url: url, title: "T", imageHash: "../x", imageWidth: 1, imageHeight: 1).validated(for: text)?
                .imageHash == nil)
        #expect(LinkPreview(url: url, title: "T", imageHash: hash, imageWidth: 0, imageHeight: 10).validated(for: text) == nil)
        #expect(LinkPreview(url: url, title: "T", imageHash: hash).validated(for: text) == nil, "An image needs its size")
        let long = LinkPreview(url: url, title: String(repeating: "t", count: 500)).validated(for: text)
        #expect(long?.title?.count == 200)
    }

    @Test("Preview images are at most 600 pixels wide; icons at most 64")
    func images() throws {
        let image = try ImageProcessing.linkImage(from: makePNG(width: 1200, height: 630))
        let size = try #require(ImageProcessing.pixelSize(of: image))
        #expect(size.width == 600 && size.height == 315)
        #expect(ImageProcessing.isAcceptableImage(image))
        let icon = try ImageProcessing.linkIcon(from: makePNG(width: 180, height: 180))
        let iconSize = try #require(ImageProcessing.pixelSize(of: icon))
        #expect(iconSize.width == 64 && iconSize.height == 64)
        #expect(throws: ImageProcessing.Failure.unreadable) { try ImageProcessing.linkImage(from: makePNG(width: 10, height: 10)) }
    }
}

/// Alice (who makes previews with a stand-in) and Bob over the loopback.
@MainActor
private final class PreviewHarness {
    let root = TemporaryDirectory("DeskDropLinks")
    let aliceWire: LoopbackTransport
    let bobWire: LoopbackTransport
    let alice: ChatService
    let bob: ChatService
    let aliceLibrary: MediaLibrary
    let bobLibrary: MediaLibrary
    /// What the stand-in previewer returns, after `delay`.
    var result: LinkPreview?
    var delay: Duration = .milliseconds(200)
    private(set) var requested: [URL] = []

    init(connected: Bool = true) {
        let (aliceWire, bobWire) = LoopbackTransport.pair(in: root)
        self.aliceWire = aliceWire
        self.bobWire = bobWire
        aliceWire.isConnected = connected
        bobWire.isConnected = connected
        let aliceLibrary = MediaLibrary(directory: root.subdirectory("AliceMedia"))
        self.aliceLibrary = aliceLibrary
        bobLibrary = MediaLibrary(directory: root.subdirectory("BobMedia"))
        let aliceID = aliceWire.localPeer.id
        let bobID = bobWire.localPeer.id
        weak var weakSelf: PreviewHarness?
        alice = ChatService(transport: aliceWire, store: ChatStore(fileURL: root.url.appendingPathComponent("alice.json")),
                            media: MediaExchange(transport: aliceWire, library: aliceLibrary),
                            linkPreviews: { url in
                                guard let harness = weakSelf else { return nil }
                                harness.requested.append(url)
                                try? await Task.sleep(for: harness.delay)
                                return harness.result
                            }) { (aliceID, "Alice’s Mac") }
        bob = ChatService(transport: bobWire, store: ChatStore(fileURL: root.url.appendingPathComponent("bob.json")),
                          media: MediaExchange(transport: bobWire, library: bobLibrary)) { (bobID, "Bob’s Mac") }
        weakSelf = self
    }

    var aliceID: String { aliceWire.localPeer.id }
    var bobID: String { bobWire.localPeer.id }

    deinit {
        root.cleanUp()
    }
}

@Suite("Link previews between Macs, over loopback", .serialized)
@MainActor
struct LinkPreviewExchangeTests {
    @Test("A link waits for its preview, then arrives with it, and the image follows from the sender")
    func withPreview() async throws {
        let harness = PreviewHarness()
        let image = try #require(harness.aliceLibrary.store(makePNG(width: 600, height: 315)))
        let url = try #require(URL(string: "https://example.com/post"))
        harness.result = LinkPreview(url: url, title: "A post", imageHash: image, imageWidth: 600, imageHeight: 315)

        harness.alice.send("Read this https://example.com/post", to: .direct(harness.bobID))
        let sent = try #require(harness.alice.store.messages(in: .direct(harness.bobID)).first)
        #expect(harness.alice.isPreparingPreview(sent.id))
        await waitUntil("the preview is asked for") { harness.requested == [url] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.bob.store.messages(in: .direct(harness.aliceID)).isEmpty, "Held while the preview is made")

        await waitUntil("Bob has the message and the image") {
            harness.bob.store.messages(in: .direct(harness.aliceID)).first?.link?.title == "A post"
                && harness.bobLibrary.contains(image)
        }
        #expect(!harness.alice.isPreparingPreview(sent.id))
        #expect(harness.alice.store.messages(in: .direct(harness.bobID)).first?.link?.imageHash == image)
    }

    @Test("No preview: the message goes out without one")
    func withoutPreview() async throws {
        let harness = PreviewHarness()
        harness.result = nil
        harness.alice.send("https://example.com/nothing", to: .community)
        await waitUntil("Bob receives") { !harness.bob.store.messages(in: .community).isEmpty }
        #expect(harness.bob.store.messages(in: .community).first?.link == nil)
        #expect(harness.alice.preparingPreviews.isEmpty)
    }

    @Test("Messages without links, and GIFs, don't wait")
    func noLink() async throws {
        let harness = PreviewHarness()
        harness.alice.send("just text", to: .direct(harness.bobID))
        harness.alice.send(ChatMedia(kind: .gif, url: URL(string: "https://media.giphy.com/media/x/giphy.gif"), hash: nil,
                                     width: 10, height: 10, giphyID: "x"), to: .direct(harness.bobID))
        #expect(harness.alice.preparingPreviews.isEmpty)
        #expect(harness.requested.isEmpty)
        await waitUntil("both arrive") { harness.bob.store.messages(in: .direct(harness.aliceID)).count == 2 }
    }

    @Test("A colleague connecting while the preview is made gets the message once, with it")
    func connectWhilePreparing() async throws {
        let harness = PreviewHarness(connected: false)
        let url = try #require(URL(string: "https://example.com/a"))
        harness.result = LinkPreview(url: url, title: "Page A")
        harness.delay = .milliseconds(400)
        harness.alice.send("https://example.com/a", to: .direct(harness.bobID))
        harness.aliceWire.connectAndAnnounce()
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.bob.store.messages(in: .direct(harness.aliceID)).isEmpty)
        await waitUntil("delivered with the preview") {
            harness.bob.store.messages(in: .direct(harness.aliceID)).first?.link?.title == "Page A"
        }
        #expect(harness.aliceWire.sentMessages.filter { $0.kind == .chat }.count == 1)
    }

    @Test("A preview for a different link than the message's is dropped on arrival")
    func forgedPreview() async throws {
        let harness = PreviewHarness()
        let payload = ChatPayload(id: UUID(), scope: .direct, senderID: harness.aliceID, senderName: "Alice",
                                  text: "https://bank.example", sentAt: .now,
                                  link: LinkPreview(url: URL(string: "https://phish.example")!, title: "Your Bank"))
        harness.bobWire.deliverRaw(.chat(payload), from: harness.aliceID)
        let received = try #require(harness.bob.store.messages(in: .direct(harness.aliceID)).first)
        #expect(received.link == nil)
        #expect(received.text == "https://bank.example")
    }
}

/// An opaque picture: a gradient with a few shapes.
private func makePicturePNG(width: Int, height: Int) -> Data {
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
        NSGradient(colors: [.systemIndigo, .systemTeal])?.draw(in: rect, angle: 30)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.35, dy: rect.height * 0.25)).fill()
        NSColor.systemOrange.setFill()
        NSBezierPath(rect: NSRect(x: 40, y: 40, width: rect.width / 4, height: rect.height / 5)).fill()
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// A tiny web server on this Mac's loopback, for LinkPresentation to read.
private final class LocalWebServer: @unchecked Sendable {
    private let listener: NWListener
    private let pages: [String: (type: String, body: Data)]
    private let queue = DispatchQueue(label: "LocalWebServer")
    private(set) var port: UInt16 = 0

    init(pages: [String: (type: String, body: Data)]) throws {
        self.pages = pages
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = UncheckedSendable(NSLock())
            nonisolated(unsafe) var done = false
            listener.stateUpdateHandler = { state in
                resumed.value.lock()
                defer { resumed.value.unlock() }
                guard !done else { return }
                switch state {
                case .ready: done = true; continuation.resume()
                case .failed(let error): done = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [pages] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let page = pages[path]
            let body = page?.body ?? Data("Not found".utf8)
            let header = "HTTP/1.1 \(page == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(page?.type ?? "text/plain")\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

@Suite("Link previews with LinkPresentation", .serialized)
@MainActor
struct LinkPresentationTests {
    @Test("A page's title and og:image become a preview, with the image in the library", .timeLimit(.minutes(1)))
    func realFetch() async throws {
        let root = TemporaryDirectory("DeskDropLP")
        defer { root.cleanUp() }
        let library = MediaLibrary(directory: root.url)
        // LinkPresentation ignores blank images, so this one has a picture on it.
        var pages: [String: (type: String, body: Data)] = ["/og.png": ("image/png", makePicturePNG(width: 1200, height: 630))]
        let server = try LocalWebServer(pages: pages)
        try await server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)"
        let html = """
        <!doctype html><html><head><title>Fallback title</title>
        <meta property="og:title" content="DeskDrop test page">
        <meta property="og:image" content="\(base)/og.png">
        </head><body><p>Hello</p></body></html>
        """
        pages["/"] = ("text/html; charset=utf-8", Data(html.utf8))
        let site = try LocalWebServer(pages: pages)
        try await site.start()
        defer { site.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(site.port)/"))

        let preview = try #require(await LinkPreviewer.preview(for: url, library: library))
        #expect(preview.url == url)
        #expect(preview.title == "DeskDrop test page")
        let hash = try #require(preview.imageHash)
        #expect(library.contains(hash))
        #expect(preview.imageWidth == 600 && preview.imageHeight == 315)
    }
}
