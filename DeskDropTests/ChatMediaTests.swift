import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DeskDrop

/// A solid-colour PNG, optionally with a transparent border, for image tests.
func makePNG(width: Int, height: Int, transparentBorder: Int = 0) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
    context.fill(CGRect(x: transparentBorder, y: transparentBorder,
                        width: width - 2 * transparentBorder, height: height - 2 * transparentBorder))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// A PNG of random pixels, which doesn't compress: close to 4 bytes per pixel.
func makeNoisePNG(side: Int) -> Data {
    let bytes = randomData(side * side * 4)
    let provider = CGDataProvider(data: bytes as CFData)!
    let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Suite("Markdown in messages")
struct MessageMarkdownTests {
    @Test("Lines become paragraphs, headings, quotes, lists, code and rules")
    func blocks() {
        let text = """
        # Release
        Build is **ready**
        second line
        > from the notes
        > continued
        - one
          - nested
        2. two
        ```
        let x = 1
        ```
        ---
        """
        let blocks = MessageMarkdown.blocks(for: text)
        #expect(blocks.count == 8)
        guard blocks.count == 8 else { return }
        #expect(blocks[0] == .heading(level: 1, AttributedString("Release")))
        if case .paragraph(let string) = blocks[1] {
            #expect(String(string.characters) == "Build is ready\nsecond line", "A single line break stays")
        } else {
            Issue.record("Expected a paragraph")
        }
        #expect(blocks[2] == .quote(MessageMarkdown.inline("from the notes\ncontinued")))
        #expect(blocks[3] == .listItem(marker: "•", indent: 0, AttributedString("one")))
        #expect(blocks[4] == .listItem(marker: "•", indent: 1, AttributedString("nested")))
        #expect(blocks[5] == .listItem(marker: "2.", indent: 0, AttributedString("two")))
        #expect(blocks[6] == .code("let x = 1"))
        #expect(blocks[7] == .rule)
    }

    @Test("Things that only look like Markdown stay as typed")
    func lookalikes() {
        #expect(MessageMarkdown.blocks(for: "#hashtag").count == 1)
        #expect(MessageMarkdown.plainText("#hashtag") == "#hashtag")
        #expect(MessageMarkdown.plainText("2024. A good year") == "2024. A good year")
        #expect(MessageMarkdown.plainText("snake_case_name") == "snake_case_name")
        #expect(MessageMarkdown.plainText("1 * 2 * 3") == "1 * 2 * 3")
        #expect(MessageMarkdown.plainText("**unclosed") == "**unclosed")
    }

    @Test("Inline styles are recognised")
    func inline() {
        let string = MessageMarkdown.inline("**bold** *it* `code` ~~gone~~")
        let intents = string.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.emphasized))
        #expect(intents.contains(.code))
        #expect(intents.contains(.strikethrough))
        #expect(String(string.characters) == "bold it code gone")
    }

    @Test("Only web and email links stay clickable")
    func links() {
        let string = MessageMarkdown.inline("[a](https://apple.com) [b](javascript:alert(1)) [c](file:///etc/passwd) www.example.com me@example.com [d](x-apple-app://x)")
        let links = string.runs.compactMap(\.link).map(\.absoluteString)
        #expect(links == ["https://apple.com", "http://www.example.com", "mailto:me@example.com"])
    }

    @Test("Previews drop the symbols")
    func plainText() {
        #expect(MessageMarkdown.plainText("**Ship it** — see `v1.7`\n- notes\n```\ncode\n```")
                == "Ship it — see v1.7\n• notes\ncode")
        #expect(MessageMarkdown.plainText("```\nunclosed") == "unclosed")
    }
}

@Suite("GIF and sticker messages")
struct ChatMediaTests {
    private let giphyURL = URL(string: "https://media3.giphy.com/media/abc123/giphy.gif?cid=x&rid=giphy.gif")!

    @Test("Only GIPHY's servers, over HTTPS, are accepted for GIFs")
    func hosts() {
        func media(_ link: String) -> ChatMedia {
            ChatMedia(kind: .gif, url: URL(string: link), hash: nil, width: 200, height: 150)
        }
        #expect(media(giphyURL.absoluteString).validated() != nil)
        #expect(media("https://i.giphy.com/abc.gif").validated() != nil)
        #expect(media("http://media.giphy.com/abc.gif").validated() == nil)
        #expect(media("https://evil.example/abc.gif").validated() == nil)
        #expect(media("https://media.giphy.com.evil.example/abc.gif").validated() == nil)
        #expect(media("https://user@media.giphy.com/abc.gif").validated() == nil)
        #expect(media("https://192.168.1.10/abc.gif").validated() == nil)
    }

    @Test("Stickers may come by hash; everything needs one source and a sane size")
    func sources() {
        let hash = String(repeating: "a", count: 64)
        #expect(ChatMedia(kind: .sticker, url: nil, hash: hash, width: 300, height: 300).validated() != nil)
        #expect(ChatMedia(kind: .gif, url: nil, hash: hash, width: 300, height: 300).validated() == nil, "GIFs come from GIPHY")
        #expect(ChatMedia(kind: .sticker, url: giphyURL, hash: hash, width: 300, height: 300).validated() == nil)
        #expect(ChatMedia(kind: .sticker, url: nil, hash: "../../etc", width: 300, height: 300).validated() == nil)
        #expect(ChatMedia(kind: .sticker, url: nil, hash: hash.uppercased(), width: 300, height: 300).validated() == nil)
        #expect(ChatMedia(kind: .gif, url: giphyURL, hash: nil, width: 0, height: 300).validated() == nil)
        #expect(ChatMedia(kind: .gif, url: giphyURL, hash: nil, width: 300, height: 9000).validated() == nil)
        let cleaned = ChatMedia(kind: .gif, url: giphyURL, hash: nil, width: 300, height: 300,
                                title: "  Party\u{202E} time ", giphyID: "../x").validated()
        #expect(cleaned?.title == "Party time")
        #expect(cleaned?.giphyID == nil)
    }

    @Test("A kind from a newer DeskDrop decodes and falls back to the text")
    func unknownKind() throws {
        let json = """
        {"id":"\(UUID().uuidString)","scope":"direct","senderID":"\(UUID().uuidString)","senderName":"Alex",
         "text":"[Hologram]","sentAt":800000000,"media":{"kind":"hologram","width":10,"height":10}}
        """
        let payload = try JSONDecoder().decode(ChatPayload.self, from: Data(json.utf8))
        #expect(payload.media?.kind == .unknown)
        let clean = try #require(ChatValidator.validate(payload, now: Date(timeIntervalSinceReferenceDate: 800_000_100)))
        #expect(clean.media == nil)
        #expect(clean.text == "[Hologram]")
    }

    @Test("Older versions see a description with a link")
    func fallback() {
        let media = ChatMedia(kind: .gif, url: giphyURL, hash: nil, width: 1, height: 1, title: "Party", giphyID: "abc123")
        #expect(media.fallbackText == "GIF: Party https://giphy.com/gifs/abc123")
        #expect(ChatMedia(kind: .sticker, url: nil, hash: String(repeating: "a", count: 64), width: 1, height: 1).fallbackText
                == "[Sticker]")
    }

    @Test("GIPHY results keep only usable images on GIPHY's servers")
    func giphyDecoding() throws {
        let json = """
        {"data":[
          {"id":"good1","title":"Happy Dance GIF by Someone","images":{
             "fixed_width_downsampled":{"url":"https://media1.giphy.com/media/good1/200w_d.gif","width":"200","height":"150"},
             "downsized":{"url":"https://media1.giphy.com/media/good1/giphy.gif","width":"480","height":"360"}}},
          {"id":"bad1","title":"Elsewhere","images":{
             "downsized":{"url":"https://example.com/x.gif","width":"480","height":"360"}}},
          {"id":"good2","title":"Thumbs Up Sticker","images":{
             "fixed_width":{"url":"https://media2.giphy.com/media/good2/200w.gif","width":"200","height":"200"}}}
        ],"pagination":{"total_count":100,"count":3,"offset":0},"meta":{"status":200}}
        """
        let page = try GiphyClient.decode(Data(json.utf8))
        #expect(page.items.map(\.id) == ["good1", "good2"])
        #expect(page.items[0].title == "Happy Dance")
        #expect(page.items[0].preview.width == 200)
        #expect(page.items[0].full.url.absoluteString.hasSuffix("giphy.gif"))
        #expect(page.items[1].title == "Thumbs Up")
        #expect(page.items[1].full == page.items[1].preview, "Falls back to the size there is")
        #expect(page.nextOffset == 3)

        let media = GiphyClient.media(for: page.items[1], catalog: .stickers)
        #expect(media.kind == .sticker)
        #expect(media.validated() == media)
        #expect(throws: GiphyClient.Failure.malformed) { try GiphyClient.decode(Data("<html>".utf8)) }
    }

    @Test("Previews say GIF or Sticker, and drop Markdown")
    func previews() {
        let now = Date.now
        var message = ChatMessage(id: UUID(), conversation: .community, senderID: "a", senderName: "A",
                                  text: "**hi** there", sentAt: now, receivedAt: now, isOutgoing: false, delivery: nil)
        #expect(message.previewText == "hi there")
        message.media = ChatMedia(kind: .gif, url: giphyURL, hash: nil, width: 1, height: 1)
        #expect(message.previewText == "GIF")
    }
}

@Suite("Profile photos and sticker images")
struct ImageProcessingTests {
    @Test("A profile photo is a centred 256-pixel square JPEG")
    func profilePhoto() throws {
        let photo = try ImageProcessing.profilePhoto(from: makePNG(width: 600, height: 300))
        let size = try #require(ImageProcessing.pixelSize(of: photo))
        #expect(size.width == 256 && size.height == 256)
        let source = try #require(CGImageSourceCreateWithData(photo as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect(ImageProcessing.isAcceptableImage(photo))
        #expect(throws: ImageProcessing.Failure.unreadable) { try ImageProcessing.profilePhoto(from: Data("nope".utf8)) }
    }

    @Test("A sticker is trimmed to its content and fits in 320 pixels")
    func sticker() throws {
        let sticker = try ImageProcessing.sticker(from: makePNG(width: 800, height: 400, transparentBorder: 100),
                                                  removeBackground: false)
        let size = try #require(ImageProcessing.pixelSize(of: sticker))
        // The 600×200 coloured area, scaled to fit 320.
        #expect(size.width == 320)
        #expect((106...108).contains(size.height))
    }

    @Test("Removing the background keeps the subject and clears the rest")
    func liftSubject() throws {
        // A red disc on a white background.
        let context = CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 150, y: 150, width: 300, height: 300))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)

        let sticker: Data
        do {
            sticker = try ImageProcessing.sticker(from: data as Data, removeBackground: true)
        } catch ImageProcessing.Failure.noSubject {
            // Vision may see no subject in a plain drawing; the app then keeps the whole picture.
            return
        }
        let image = try #require(NSBitmapImageRep(data: sticker))
        #expect(max(image.pixelsWide, image.pixelsHigh) <= ImageProcessing.stickerSide)
        // Trimmed to the disc, whose corners are outside it: transparent.
        #expect(image.colorAt(x: 1, y: 1)?.alphaComponent ?? 1 < 0.1)
        let middle = image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)
        #expect(middle?.alphaComponent ?? 0 > 0.9)
    }

    @Test("Images from other Macs must be small PNG, JPEG or GIF files that decode")
    func acceptance() {
        #expect(ImageProcessing.isAcceptableImage(makePNG(width: 64, height: 64)))
        #expect(!ImageProcessing.isAcceptableImage(makePNG(width: 2000, height: 10)))
        #expect(!ImageProcessing.isAcceptableImage(randomData(4096)))
        #expect(!ImageProcessing.isAcceptableImage(Data()))
        let tiff = NSImage(data: makePNG(width: 10, height: 10))!.tiffRepresentation!
        #expect(!ImageProcessing.isAcceptableImage(tiff), "Only the common formats are decoded")
    }
}

@Suite("Media library")
@MainActor
struct MediaLibraryTests {
    @Test("Photos and stickers survive relaunch; replaced photos are deleted")
    func persistence() throws {
        let root = TemporaryDirectory()
        defer { root.cleanUp() }
        let library = MediaLibrary(directory: root.url)
        let peer = UUID().uuidString
        let first = makePNG(width: 20, height: 20)
        let second = makePNG(width: 30, height: 30)
        let mine = try #require(library.setMyAvatar(first))
        let theirs = try #require(library.store(second))
        library.setAvatar(theirs, forPeer: peer)
        let sticker = try #require(library.addSticker(makePNG(width: 40, height: 40)))

        let reloaded = MediaLibrary(directory: root.url)
        #expect(reloaded.myAvatarHash == mine)
        #expect(reloaded.avatarHashes[peer] == theirs)
        #expect(reloaded.myStickers == [sticker])
        #expect(reloaded.avatar(forPeer: peer) != nil)

        reloaded.setMyAvatar(nil)
        #expect(!reloaded.contains(mine), "An unused old photo is removed")
        reloaded.setAvatar(theirs, forPeer: "someone-else")
        #expect(reloaded.contains(theirs))
        reloaded.removeSticker(sticker)
        #expect(reloaded.myStickers.isEmpty)
        #expect(reloaded.contains(sticker), "Messages may still show it")
    }
}

/// Alice and Bob with chat and image exchange over the loopback.
@MainActor
private final class MediaHarness {
    let root = TemporaryDirectory("DeskDropMedia")
    let aliceWire: LoopbackTransport
    let bobWire: LoopbackTransport
    let alice: ChatService
    let bob: ChatService
    let aliceLibrary: MediaLibrary
    let bobLibrary: MediaLibrary

    init(connected: Bool = true) {
        let (aliceWire, bobWire) = LoopbackTransport.pair(in: root)
        self.aliceWire = aliceWire
        self.bobWire = bobWire
        aliceWire.isConnected = connected
        bobWire.isConnected = connected
        aliceLibrary = MediaLibrary(directory: root.subdirectory("AliceMedia"))
        bobLibrary = MediaLibrary(directory: root.subdirectory("BobMedia"))
        let aliceID = aliceWire.localPeer.id
        let bobID = bobWire.localPeer.id
        alice = ChatService(transport: aliceWire, store: ChatStore(fileURL: root.url.appendingPathComponent("alice.json")),
                            media: MediaExchange(transport: aliceWire, library: aliceLibrary)) { (aliceID, "Alice’s Mac") }
        bob = ChatService(transport: bobWire, store: ChatStore(fileURL: root.url.appendingPathComponent("bob.json")),
                          media: MediaExchange(transport: bobWire, library: bobLibrary)) { (bobID, "Bob’s Mac") }
    }

    var aliceID: String { aliceWire.localPeer.id }
    var bobID: String { bobWire.localPeer.id }

    deinit {
        root.cleanUp()
    }
}

@Suite("Photos and stickers between Macs, over loopback", .serialized)
@MainActor
struct MediaExchangeTests {
    @Test("A new profile photo reaches a connected colleague, and so does removing it")
    func avatarChange() async throws {
        let harness = MediaHarness()
        let hash = try #require(harness.aliceLibrary.setMyAvatar(makePNG(width: 32, height: 32)))
        harness.alice.media?.announceAvatar()
        await waitUntil("Bob has Alice's photo") { harness.bobLibrary.avatarHashes[harness.aliceID] == hash }
        #expect(harness.bobLibrary.avatar(forPeer: harness.aliceID) != nil)

        harness.aliceLibrary.setMyAvatar(nil)
        harness.alice.media?.announceAvatar()
        await waitUntil("Bob drops it") { harness.bobLibrary.avatarHashes[harness.aliceID] == nil }
    }

    @Test("Photos are exchanged when Macs connect, and not downloaded twice")
    func avatarOnConnect() async throws {
        let harness = MediaHarness(connected: false)
        let aliceHash = try #require(harness.aliceLibrary.setMyAvatar(makePNG(width: 32, height: 32)))
        let bobHash = try #require(harness.bobLibrary.setMyAvatar(makePNG(width: 48, height: 48)))
        harness.aliceWire.connectAndAnnounce()
        await waitUntil("both photos arrive") {
            harness.bobLibrary.avatarHashes[harness.aliceID] == aliceHash
                && harness.aliceLibrary.avatarHashes[harness.bobID] == bobHash
        }
        let requestsBefore = harness.bobWire.sentMessages.filter { $0.kind == .mediaRequest }.count
        harness.aliceWire.connectAndAnnounce()
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.bobWire.sentMessages.filter { $0.kind == .mediaRequest }.count == requestsBefore,
                "A photo this Mac already has isn't requested again")
    }

    @Test("Your own sticker reaches a colleague: the message, then the image")
    func stickerMessage() async throws {
        let harness = MediaHarness()
        let hash = try #require(harness.aliceLibrary.addSticker(makePNG(width: 120, height: 90)))
        let media = ChatMedia(kind: .sticker, url: nil, hash: hash, width: 120, height: 90)
        #expect(harness.alice.send(media, to: .direct(harness.bobID)))

        await waitUntil("Bob has the image") { harness.bobLibrary.contains(hash) }
        let received = try #require(harness.bob.store.messages(in: .direct(harness.aliceID)).first)
        #expect(received.media?.hash == hash)
        #expect(received.text == "[Sticker]")
        #expect(harness.bobLibrary.image(for: hash) != nil)
        #expect(!harness.bobLibrary.isMySticker(hash), "Received stickers aren't added to yours automatically")
    }

    @Test("A GIF travels as a GIPHY link, with a description for older Macs")
    func gifMessage() async throws {
        let harness = MediaHarness()
        let media = ChatMedia(kind: .gif, url: URL(string: "https://media0.giphy.com/media/xyz/giphy.gif"), hash: nil,
                              width: 480, height: 270, title: "Wave", giphyID: "xyz")
        harness.alice.send(media, to: .community)
        await waitUntil("Bob receives") { !harness.bob.store.messages(in: .community).isEmpty }
        let received = try #require(harness.bob.store.messages(in: .community).first)
        #expect(received.media == media)
        #expect(received.text == "GIF: Wave https://giphy.com/gifs/xyz")
        #expect(harness.bobWire.sentMessages.allSatisfy { $0.kind != .mediaRequest }, "Nothing to fetch from Alice")
    }

    @Test("Images nobody asked for, or that don't match their hash, are dropped")
    func rejects() async throws {
        let harness = MediaHarness()
        let png = makePNG(width: 16, height: 16)
        let hash = MediaLibrary.hash(of: png)
        // Unsolicited.
        harness.bobWire.deliverRaw(.media(MediaBlob(hash: hash, data: png)), from: harness.aliceID)
        #expect(!harness.bobLibrary.contains(hash))

        // Asked for, but the bytes don't match the hash.
        harness.bob.media?.want(hash, from: harness.aliceID)
        harness.bobWire.deliverRaw(.media(MediaBlob(hash: hash, data: makePNG(width: 17, height: 17))), from: harness.aliceID)
        #expect(!harness.bobLibrary.contains(hash))

        // Asked for, matching, but not an image.
        let junk = randomData(512)
        let junkHash = MediaLibrary.hash(of: junk)
        harness.bob.media?.want(junkHash, from: harness.aliceID)
        harness.bobWire.deliverRaw(.media(MediaBlob(hash: junkHash, data: junk)), from: harness.aliceID)
        #expect(!harness.bobLibrary.contains(junkHash))

        // A bad answer cancels the request, so ask again; this time it's right.
        harness.bob.media?.want(hash, from: harness.aliceID)
        harness.bobWire.deliverRaw(.media(MediaBlob(hash: hash, data: png)), from: harness.aliceID)
        #expect(harness.bobLibrary.contains(hash))
    }

    @Test("Requests for images this Mac doesn't have go unanswered")
    func unknownRequest() async throws {
        let harness = MediaHarness()
        harness.aliceWire.deliverRaw(.mediaRequest(hash: String(repeating: "f", count: 64)), from: harness.bobID)
        harness.aliceWire.deliverRaw(.mediaRequest(hash: "../../secret"), from: harness.bobID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.aliceWire.sentMessages.isEmpty)
    }
}
