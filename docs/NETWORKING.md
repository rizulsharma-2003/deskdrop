# Networking and protocol

DeskDrop runs a small, versioned protocol over Apple's **Multipeer Connectivity** framework. Multipeer Connectivity handles Bonjour discovery, transport selection (infrastructure Wi‑Fi, peer-to-peer Wi‑Fi, Ethernet), encryption and streaming of file resources. DeskDrop adds identity, offers, consent, verification and the transfer state machine.

## Service and Info.plist

| Item | Value |
|---|---|
| Multipeer service type | `deskdrop` (1–15 lowercase letters, digits or hyphens) |
| `NSBonjourServices` | `_deskdrop._tcp`, `_deskdrop._udp` |
| `NSLocalNetworkUsageDescription` | "DeskDrop uses your local network to discover nearby colleagues running DeskDrop and transfer files directly between your Macs." |
| Entitlements | App Sandbox, `network.client`, `network.server`, Downloads read/write, user-selected read/write, app-scoped bookmarks |

## Discovery

Each instance advertises with this discovery info. It is untrusted, so every field is validated on receipt:

| Key | Value | Validation |
|---|---|---|
| `id` | Installation ID (random UUID created on first launch) | Must parse as a UUID; your own ID is ignored |
| `n` | Display name | Control and bidi characters removed, whitespace collapsed, at most 32 characters |
| `k` | `laptop` or `desktop` (used for the illustration only) | Unknown values become `desktop` |
| `v` | Protocol version | If unsupported, the peer is shown as *Update needed* and DeskDrop doesn't connect |

The `MCPeerID` is archived and reused while the display name is unchanged, as Apple recommends, so other Macs don't see a "new" device on every launch. Its display name is truncated to 63 UTF-8 bytes.

A peer that disappears from browsing is removed after a 4-second grace period, unless a session with it is still up. Discovery can flicker; sessions are authoritative.

## Connections

- **One `MCSession` per peer.** Failures stay isolated and the 8-peers-per-session limit never applies.
- **Encryption is required.** Sessions use `encryptionPreference: .required`, with no fallback to unencrypted.
- **Who invites:** the Mac with the lexicographically smaller installation ID. The other Mac invites only as a fallback if no invitation arrives within 6 seconds, which covers one-way discovery. If both invite at once, the session from the smaller ID is kept and the other is declined.
- **Invitation context:** a `hello` message, so the receiving side knows who is asking before it accepts.
- **Handshake:** once connected, both sides send `hello`. A peer is **ready** (can receive offers) only after its `hello` arrives and its installation ID matches the session. Messages received before the handshake are dropped.
- **Timeouts and backoff**

| Situation | Behaviour |
|---|---|
| Invitation unanswered | 20 s Multipeer timeout, plus a 25 s connect watchdog |
| Connected but no `hello` | 10 s, then disconnect and retry |
| Retry after failure | 2, 4, 8, 16, 30 s (capped) plus up to 1 s jitter |
| Repeated failures | After 5 attempts the peer shows *Not responding* until the user retries or presses Refresh |
| Advertiser or browser fails to start | Restart after 5 s × attempt (capped at 60 s) |
| Network change (`NWPathMonitor`) | Discovery restarts 2 s after the network changes or comes back; connected sessions are left alone |

## Local network permission

macOS has no API that reports whether local-network access was allowed. DeskDrop runs a small `NWBrowser` for its own Bonjour type and treats `PolicyDenied` (`kDNSServiceErr_PolicyDenied`, −65570) as "permission required". The header and empty state then offer to open **System Settings › Privacy & Security › Local Network**. Errors from the Multipeer Connectivity advertiser and browser are classified the same way, and −72008 means `NSBonjourServices` is missing.

## Wire format

Control messages are JSON objects sent with `MCSession.send(_:toPeers:with: .reliable)`:

```json
{ "v": 1, "type": "offer", "offer": { "transferID": "…", "totalBytes": 2457600,
  "files": [ { "path": "Report.pdf", "size": 2457600,
               "sha256": "9f2c…", "typeIdentifier": "com.adobe.pdf" } ] } }
{ "v": 1, "type": "accept",   "transferID": "…" }
{ "v": 1, "type": "decline",  "transferID": "…", "declineReason": "userDeclined" }
{ "v": 1, "type": "cancel",   "transferID": "…" }
{ "v": 1, "type": "complete", "transferID": "…" }
{ "v": 1, "type": "failure",  "transferID": "…", "failureReason": "validationFailed" }
{ "v": 1, "type": "hello",    "hello": { "installationID": "…", "displayName": "Priya’s MacBook Pro",
                                         "deviceKind": "laptop", "appVersion": "1.0.0" } }
```

Chat uses seven more types:

```json
{ "v": 1, "type": "chat", "chat": { "id": "…", "scope": "direct", "senderID": "…",
                                    "senderName": "Priya’s MacBook", "text": "Lunch?", "sentAt": 783000000 } }
{ "v": 1, "type": "chatAck",     "messageID": "…" }
{ "v": 1, "type": "chatSync",    "chatSync": { "communitySince": 782990000 } }
{ "v": 1, "type": "chatHistory", "chatHistory": [ { "id": "…", "scope": "community", …,
                                                    "reactions": [ { "reactorID": "…", "reactorName": "Alex", "emoji": "❤️" } ] } ] }
{ "v": 1, "type": "chatReaction", "chatReaction": { "messageID": "…", "scope": "direct", "emoji": "👍",
                                                    "reactorID": "…", "reactorName": "Alex", "at": 783000100 } }
{ "v": 1, "type": "chatRead",    "chatRead": { "lastReadMessageID": "…", "readAt": 783000200 } }
{ "v": 1, "type": "chatTyping",  "typing": true }
```

- `chatReaction` sets, changes or (with `"emoji": null`) removes the sender's one reaction to a message. It is accepted only from the reactor's own session, only as a single emoji, and only for a message the receiver already has in the matching conversation. Reactions to group messages are also carried in `chatHistory` (up to 50 per message) so colleagues who were away catch up.
- `chatRead` is sent on a one-on-one session when the recipient opens the conversation, at most once per message, and only if they have read receipts turned on. The sender marks every one of its messages up to and including `lastReadMessageID` as read.

- `chatTyping` says the sender started (`true`) or stopped (`false`) typing a one-on-one message. It's repeated at most every 3 s while typing. The receiver drops the indicator after 6 s without an update, or when a message from that colleague arrives. It's sent only to Macs whose hello lists `"typing"`, and only if the sender's setting allows it.

Profile photos and stickers (1.7) use three more types, and chat messages may carry `media`:

```json
{ "v": 1, "type": "avatar",       "avatar": { "hash": "3f9a…" } }
{ "v": 1, "type": "mediaRequest", "hash": "3f9a…" }
{ "v": 1, "type": "media",        "media": { "hash": "3f9a…", "data": "<base64 PNG, JPEG or GIF>" } }
{ "v": 1, "type": "chat", "chat": { …, "text": "GIF: Party https://giphy.com/gifs/abc123",
    "media": { "kind": "gif", "url": "https://media2.giphy.com/media/abc123/giphy.gif",
               "width": 480, "height": 270, "title": "Party", "giphyID": "abc123" } } }
{ "v": 1, "type": "chat", "chat": { …, "text": "[Sticker]",
    "media": { "kind": "sticker", "hash": "3f9a…", "width": 320, "height": 240 } } }
```

- Images are named by the lowercase hex SHA-256 of their bytes. `avatar` announces the sender's profile photo (or `null` for none) when a colleague becomes ready and whenever it changes. A Mac that doesn't have that image yet sends `mediaRequest`, and the owner answers with `media`.
- A sticker made from a picture carries only its `hash`. The recipient asks the Mac that delivered the message (for group history, the Mac that relayed it) and asks again when that Mac next connects if it isn't there now.
- `media` is accepted only if this Mac requested that hash from that colleague (requests are repeated after 30 s at most), the bytes hash to it, and the image decodes as PNG, JPEG or GIF of at most 1,024 pixels each way and 600,000 bytes. A wrong answer cancels the request. Requests are answered at most 40 per 10 s per colleague, and only for images this Mac has.
- GIFs and GIPHY stickers carry a GIPHY media `url` instead. It must be `https` on `i.giphy.com` or `media.giphy.com`/`media0`–`media4.giphy.com`, with no user or port; anything else drops the media. Each Mac downloads the image from GIPHY itself (up to 12 MB) and caches it in `Caches/DeskDrop/GIPHY`, trimmed to 250 MB.
- The `text` of a GIF or sticker message describes it for older versions, which ignore `media`. A `kind` from a future version decodes as `unknown` and the text is shown.
- `avatar`, `mediaRequest` and `media` go only to Macs whose hello lists `"avatar"` or `"media"`.

A chat message may also carry a link preview, made by the sender's Mac before the message goes out:

```json
{ "v": 1, "type": "chat", "chat": { …, "text": "New laptops? https://www.apple.com/macbook-air/",
    "link": { "url": "https://www.apple.com/macbook-air/", "title": "MacBook Air",
              "imageHash": "3f9a…", "imageWidth": 600, "imageHeight": 315, "iconHash": "77c1…" } } }
```

- The sender finds the first `http`/`https` link the same way Markdown does (not in code, not email), holds the message for at most 8 s while LinkPresentation loads the page, then sends it with or without a preview. A one-on-one message stays out of the outbox flush until then, so it's sent once.
- The preview image (at most 600 px wide, JPEG or PNG) and icon (64 px PNG) are in the sender's media library and travel with `mediaRequest`/`media` like stickers. The receiver never contacts the site.
- On arrival the preview is kept only if its `url` is exactly the first link the receiver finds in the text, it has a title or an image, and its fields pass the same checks as other media. Otherwise the message shows as plain text.

GIPHY search itself (`api.giphy.com/v1/{gifs,stickers}/{trending,search}`) happens only on the Mac doing the searching, with its API key, the search text, the content rating and the language. DeskDrop doesn't send GIPHY's analytics pings or any identifier.

### Updates

**From GitHub:** at launch (after 20 s) and every 6 hours, each Mac asks `https://api.github.com/repos/<owner>/<name>/releases/latest` (repository from `DeskDropUpdateRepository` in Info.plist). If the tag (`v1.8.0`) is newer than the running version and the release has a `.deskdropupdate` asset downloadable from that repository on `github.com` over HTTPS, the package is downloaded (it redirects to GitHub's file servers) and checked exactly like one from a colleague. Drafts and pre-releases are ignored. Only a verified package is shown or installed.

**From nearby Macs:**

```json
{ "v": 1, "type": "updateAvailable", "update": { "manifest": "<base64 JSON>", "signature": "<base64, 64 bytes>" } }
{ "v": 1, "type": "updateRequest",   "version": "1.8.0" }
```

- A Mac holding a verified `.deskdropupdate` package sends `updateAvailable` to each colleague whose hello lists `"update"`, when they connect and when a package is published. The manifest (bundle ID, version, build, minimum macOS, archive size and SHA-256, notes, date) is the exact signed JSON.
- The receiver accepts an offer only if the Ed25519 signature checks against the public key built into its copy (`DeskDropUpdatePublicKey` in Info.plist, from `Config/UpdateKey.xcconfig`), the bundle ID matches, and the version is newer than its own. Builds without a key ignore updates.
- `updateRequest` asks for the package. The holder sends it as a Multipeer resource named `update/<version>` (at most 3 uploads at once). A resource with that name is accepted only from the colleague it was requested from, for that version; anything else is cancelled. If nothing starts within 20 s, the next colleague who offered it is asked.
- The received package is verified in full (signature, the manifest identical to the one offered, archive size and SHA-256) before it's kept or installed.

Files need no chat message of their own. Each Mac already knows every transfer it took part in (offer, accept, progress, outcome) and shows those in the conversation.

`hello` may carry `"capabilities": ["chat", "typing", "avatar", "media", "update"]`. Older versions omit it, and they drop the chat types as unknown without disconnecting. In the same way, 1.2.x drops `chatReaction` and `chatRead`, so its users don't see reactions or send receipts. DeskDrop therefore shows those colleagues as needing an update before you can chat.

Decoding (`ProtocolCodec`) is strict:

1. Messages larger than 1 MiB are dropped before parsing.
2. `v` is read first. Unsupported versions fail with `unsupportedVersion`, so a future envelope is never misread.
3. Unknown `type` values fail with `unknownMessageType`.
4. Each type must carry its required field. Missing fields fail with `missingField`.
5. Unknown reason strings from newer peers decode as `unknown` or `userDeclined`, never as a crash.

**File contents** travel as Multipeer Connectivity *resources* (`sendResource(at:withName:toPeer:)`), streamed from disk. Resource names are `"<transfer UUID>/<file index>"` and are parsed and range-checked on receipt.

## Transfer lifecycle

```
Sender                                         Recipient
──────                                         ─────────
preparing   expand folders, sanitize, SHA-256
offering    ── offer ─────────────────────────▶ validate offer (limits, paths, digests, dup ID)
awaitingAcceptance                              awaitingDecision  (panel shown; expires in 120 s)
            ◀──────────────────── decline ──── declined / expired       → nothing written
            ◀───────────────────── accept ──── accepted  (folder checked, free space checked,
accepted                                                 staging folder created)
transferring  file 0 ══ resource ════════════▶ transferring  stage → check size → SHA-256 ✓
              file 1 ══ resource ════════════▶               stage → check size → SHA-256 ✓
verifying   all sent; wait for receipt          verifying  move items into receiving folder,
                                                           number duplicates, mark quarantined
            ◀─────────────────── complete ──── completed
completed
```

- **Consent first.** Resources that arrive for a transfer the user hasn't accepted (unknown ID, wrong peer, wrong phase, unexpected index, duplicate) have their `Progress` cancelled immediately, and any file is deleted.
- **Empty files** never travel. The recipient creates them from the offer and checks that the digest is the SHA-256 of nothing.
- **Delivery is acknowledged only after saving.** The sender's `sendResource` completion means "handed to the network", not "delivered". The sender moves to *verifying* and shows *Delivered* only when `complete` arrives, which the recipient sends only after every file is verified and in the receiving folder.
- **Sequential per transfer, concurrent across transfers.** Files in one transfer go one at a time. Separate transfers, to one peer or several, run independently and are keyed by transfer ID.
- **The source file must be unchanged.** Before each file is sent, its size is checked against what was hashed. A missing file fails with `fileUnavailable` and a changed one with `fileChanged`, and the recipient is told.

### Phases

`preparing → offering → awaitingAcceptance` (sender) and `awaitingDecision` (recipient) → `accepted → transferring → verifying → completed`. Any active phase can end in `cancelled(local|remote)` or `failed(reason)`, and offers can also end in `declined(reason)` or `expired`. Terminal phases are final.

### Timeouts

| Timer | Value |
|---|---|
| Recipient decision | 120 s (the sender's backstop is 125 s) |
| Waiting for the peer to (re)connect before offering | 20 s |
| No measurable progress while transferring | 60 s (paused while a large file is being hashed) |
| Waiting for `complete` after the last file is sent | 300 s |

### Failure handling

| Event | Sender sees | Recipient sees |
|---|---|---|
| Recipient declines | *Declined* | *You declined.* |
| Nobody answers | *No response* | *This request expired.* |
| Sender cancels | *Cancelled* | *Sender cancelled the transfer.* |
| Connection lost mid-transfer | *Lost the connection to …* | Same; staging removed |
| Contents don't match the SHA-256 | *The files didn't arrive intact…* | Same; nothing saved |
| Not enough space when accepting | *…'s Mac doesn't have enough free space.* | Error with the sizes needed |
| Receiving folder missing or read-only | *…'s receiving folder isn't available.* | Asked to choose another folder |
| Same offer ID seen twice | *This transfer was already received.* | Ignored |
| More than 5 pending offers from one peer | *…has too many requests waiting.* | Extra offers refused automatically |

## Progress

Progress comes from the `Progress` objects Multipeer Connectivity returns for each resource, sampled every 250 ms rather than observed per byte. Bytes = verified files + `fractionCompleted × size` of the files in flight, and it never moves backwards. Speed is measured over a 4-second sliding window and shown only once at least 1 second of samples exists. Time remaining is derived from that measured speed.

## Limits

| Limit | Value |
|---|---|
| Control message | 1 MiB |
| Files per transfer | 1,000 |
| Path length / depth / name length | 1,024 bytes / 32 levels / 255 bytes |
| Single file size | 1 TiB |
| Display name | 32 characters |
| Pending offers per peer | 5 |
| Remembered transfer IDs (replay protection) | 2,048 |
| Chat message | 4,000 characters |
| Live chat messages per peer | 30 per 10 s |
| Chat history batch / per sync | 40 / 400 messages |
| Profile photo / sticker image | 600,000 bytes, 1,024 px each way, PNG, JPEG or GIF |
| Image requests answered per peer | 40 per 10 s |
| GIPHY download | 12 MB, GIPHY media hosts only |
| Update package | 300 MB archive, 16 KB manifest, 8,000 characters of notes |
| Update uploads at once | 3 |
