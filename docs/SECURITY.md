# Security and privacy

DeskDrop moves files between Macs on a shared network. Everything that arrives from the network, including names, sizes, paths, message types and file contents, is treated as untrusted.

## What DeskDrop guarantees

| Area | Protection | Where |
|---|---|---|
| Consent | Nothing is written to the receiving folder until the recipient clicks **Accept**. There is no auto-accept option. Contents that arrive for unaccepted transfers are refused and deleted. | `TransferService.accept`, `resourceStarted` |
| Encryption | Every session uses `MCEncryptionPreference.required`. There is no downgrade path. | `PeerConnectionService.makeSession` |
| Message parsing | 1 MiB size cap before parsing; version checked first; unknown types and missing fields rejected; typed `Codable` envelope, not loose dictionaries. | `ProtocolCodec` |
| Handshake | Transfer messages are ignored until the peer's `hello` arrives and matches the installation the session was set up for. | `handleData`, `handleHello` |
| Offer validation | File count, sizes (with overflow checks), total, digest format, type identifier characters, duplicate paths (case-insensitive) and file-versus-folder conflicts are all checked before the user sees anything. | `OfferValidator` |
| File names | NFC-normalized; `/` and `:` replaced; control characters and bidi overrides (e.g. U+202E, which can disguise `.app` as `.pdf`) removed; `.` and `..` rejected; limited to 255 bytes. | `NameSanitizer` |
| Path traversal | Each relative path component must already be in sanitized form. Paths are rebuilt component by component under the staging root, and the resolved URL must stay inside it. | `PathValidator` |
| Integrity | Each file's size and SHA-256 are checked against the offer before anything moves into place. A mismatch fails the whole transfer and nothing is saved. | `IncomingTransferAssembler` |
| No overwrites | `moveItem` never overwrites. Duplicates get numbered names. The optional *Replace* mode moves the old item to the Trash, and keeps both if the Trash isn't available. | `FileConflictResolver` |
| Execution | Received files are marked with the quarantine attribute, so Gatekeeper checks them before anything executable runs. DeskDrop never opens a received file unless the user clicks **Open**. File permissions, including the executable bit, are not transferred. | `markQuarantined` |
| Abuse limits | 5 pending offers per peer; repeated transfer IDs refused (last 2,048 remembered); offers expire after 120 s; stalled transfers fail after 60 s. | `TransferService` |
| Filesystem scope | App Sandbox. Writes are limited to Downloads, a folder the user picked (security-scoped bookmark), and DeskDrop's own container. Nothing else on disk can be read or written, by DeskDrop or by a peer. | Entitlements |
| Streams | Incoming Multipeer streams are closed immediately; DeskDrop doesn't use them. | `session(_:didReceive:withName:fromPeer:)` |
| Cleanup | Partial files live in the container's temporary folder and are removed when a transfer ends and on every launch. | `IncomingTransferAssembler.discard`, `removeStaleStagingFiles` |

## What DeskDrop does *not* guarantee

**Identity isn't authenticated.** Display names and installation IDs are self-declared. Someone on the same network running a modified DeskDrop could advertise "Alex's Mac" or reuse a device ID they've seen. DeskDrop shows a short device ID (the first 4 hex digits of the installation ID) next to the name to help tell Macs apart, but it isn't a credential. **Treat a display name like the "From" line of an email:** if a request is unexpected, decline it or check with the person.

**No certificate pinning.** Sessions are encrypted, but DeskDrop doesn't use Multipeer Connectivity security identities (certificates), and accepts the peer's certificate callback. That protects against passive eavesdropping. It does not prove who is on the other end, so an active attacker on the local network could in principle impersonate a peer. Adding verified identities, such as a pairing code shown on both screens or per-user certificates, would be the next step if that matters to your team.

**Offer metadata is visible to whoever you send to.** File names, sizes and types are sent with the offer so the recipient can decide. Contents are sent only after acceptance.

## Chat

- Messages travel only over the same encrypted peer sessions as files. There's no server, and history is stored only on each Mac (`Application Support/DeskDrop/chat.json`). **Settings › Receiving › Clear Message History** erases it.
- Incoming text is validated: NFC-normalized; control characters (except newline and tab) and bidi overrides removed; at most 4,000 characters; sender IDs must be UUIDs; timestamps can't be in the future. Markdown is rendered on the receiving Mac (it's never HTML: inline HTML stays as text). Links can open only `http`, `https` and `mailto` addresses, and only when you click them; other schemes (`file:`, `javascript:`, app URL schemes) are shown as plain text. A link's text can differ from its address, as in any chat app, so hover isn't a guarantee of where it goes.
- A live message must come from the Mac that wrote it (its sender ID must match the session's handshake identity). Floods are cut off at 30 messages per 10 s per Mac, and reactions count toward the same limit.
- **Reactions** must be a single emoji (one grapheme, at most 32 bytes, with an emoji code point), must come from the reactor's own session, and are applied only to a message this Mac already has in the matching conversation. Each message keeps at most 50 reactors. Relayed group reactions have the same authorship caveat as relayed messages (below).
- **Quitting keeps DeskDrop reachable.** With the default setting, ⌘Q leaves DeskDrop running in the menu bar, still discoverable and still accepting requests (which always need your approval). To be unreachable, turn off **Available for Sharing** or choose **Quit DeskDrop Completely**.
- **Sounds folder exception.** Notification sounds must be in `Library/Sounds`, which inside the sandbox is a link to `~/Library/Sounds`. DeskDrop has a read-write sandbox exception for that one folder (`com.apple.security.temporary-exception.files.home-relative-path.read-write`: `/Library/Sounds/`). It only writes, lists and removes its own `DeskDrop…` files there.
- **Notifications** show the sender's name and message text. macOS's own **Show previews** setting decides whether that text appears on the lock screen. A reply typed into a banner goes through the same validation and rate limits as one typed in the window, and only to the conversation the banner came from.
- **Typing indicators** reveal that you're writing to someone. They're one-on-one only, carry no text, and can be turned off in Settings. A typing update is accepted only from a Mac that could chat with you, and it expires on its own.
- **Files in the conversation** are the same transfers as before, shown in a new place. Nothing extra is sent between Macs. Recent Activity now also stores the colleague's installation ID, the start time and the file type. That's still metadata only, never file contents. Previews and Quick Look read only items DeskDrop already has access to: what it saved for you, and what you chose to send, until it quits.
- **Read receipts** reveal when you opened a conversation. They're sent only for one-on-one conversations, only while the window is focused on that conversation, and can be turned off in Settings. A receipt can only mark messages in the conversation with the Mac that sent it.
- **Added sounds** are decoded with AVFoundation from a file you choose in an open panel (at most 200 MB), re-encoded as PCM CAF, and stored inside DeskDrop's sandbox container. The original file is never modified or kept.
- **Profile photos and stickers** travel by SHA-256. An image is accepted only when this Mac asked that colleague for it, the bytes match the hash, and ImageIO decodes it as PNG, JPEG or GIF within 600,000 bytes and 1,024 pixels each way. Nothing else is decoded from the network. Images are stored as received (so their hash stays valid) in `Application Support/DeskDrop/Media`; an old profile photo is deleted once nobody uses it. A photo is shown for the colleague whose session announced it, with the same caveat as display names: it isn't a verified identity.
- **GIFs** carry only a GIPHY media link, and DeskDrop downloads only `https` links on GIPHY's media hosts, so a message can't make your Mac fetch an arbitrary address (no tracking pixels, nothing on your local network). Downloads are capped at 12 MB and must decode as an image.
- **Link previews** are made only on the sender's Mac, with Apple's LinkPresentation, and only for links in messages you send. Your colleagues' Macs never load the page or its images: the title travels in the message and the pictures come from your Mac by hash, checked like any other image. A preview must match the first link in its message's text, so a colleague can't attach a preview for one site to a link to another. The card shows the link's real host, and hovering shows the full address. Clicking opens it in your browser (web addresses only).
- **Making stickers** reads a picture you chose (or dropped), runs Vision's subject lifting on this Mac, and saves a new PNG. The original is never modified.
- **Group history is relayed.** When Macs connect they pass on group messages the other missed. Those relayed messages carry their original author's name and ID, but a modified client could fabricate them. Like display names, chat authorship is not cryptographically verified.

## Drag gestures

Hold-to-share and screen edges watch system-wide mouse state. They need no Accessibility or Input Monitoring permission, and DeskDrop never monitors the keyboard. While the left button is held, DeskDrop checks the button state, the cursor position, and whether the system drag pasteboard changed and *offers* file URLs. It reads only the pasteboard's list of types, never its contents. Files reach DeskDrop only when you drop them on one of its targets, the same as dropping on its window. Nothing is sent on hover. Overlay windows exist only during a file drag and are removed right after. A drop sends an *offer*; the colleague still has to accept.

The overlays are borderless panels that never take focus. An assigned edge shows a thin strip on the outer edge of your displays during file drags, and it receives drops only there. If you keep the Dock on that side with auto-hide, you may want to pick the other edge.

## Privacy

- No accounts, servers, cloud storage, analytics or telemetry. Besides GIPHY (below), DeskDrop connects to the internet only to make a preview of a link you send: your Mac loads that page and its images, as Messages does. Turn this off in **Settings › Messages**. For GIFs and GIPHY stickers: searching sends your search text, content rating, language and API key to `api.giphy.com`, and showing a GIF downloads it from GIPHY's media servers, so GIPHY sees the IP address of each Mac that shows one. No messages, names or identifiers are sent, and DeskDrop doesn't send GIPHY's analytics events. Without an API key, search never runs; GIFs colleagues send are still downloaded to show them.
- A GIPHY API key is stored in DeskDrop's preferences. GIPHY keys are meant to be shipped inside apps, so it's treated as configuration, not a secret.
- Discovery broadcasts your display name, a random installation ID, the protocol version and whether your Mac is a laptop or desktop to devices on the local network while sharing is on. Turning sharing off stops advertising.
- Recent Activity stores file names, sizes, peer names, dates and outcomes locally, plus where received items were saved. It never stores contents. **Clear History** erases it.
- Logs use the unified logging system. File names and peer names aren't logged; transfer IDs and counts are.

## Reporting

Please report security issues privately to the project maintainer rather than in a public issue tracker.
