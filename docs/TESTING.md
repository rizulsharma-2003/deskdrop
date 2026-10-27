# Testing

## Automated suites

| Suite | Framework | Needs | What it proves |
|---|---|---|---|
| `DeskDropTests` (unit and integration) | Swift Testing | Nothing | Codec, validation, sanitization, state machine, files, history, and the full transfer protocol over a loopback |
| `DeskDropTests/MultipeerOnThisMacTests` | Swift Testing, opt-in | Local network permission | Real Multipeer Connectivity between two peers in one process |
| `DeskDropUITests/DeskDropUITests` | XCTest UI | A logged-in desktop session | Main window, empty state, Settings, Recent Activity, incoming panel |
| `DeskDropUITests/ChatUITests` | XCTest UI; the typing test is opt-in | An idle Mac | Messages opens inside the main window (no separate window), saved history, unread counts, switching conversations and back to Nearby; opt-in: Return to send, outbox for an offline colleague |
| `DeskDropUITests/DragGestureUITests` | XCTest UI, opt-in | An idle Mac (drives the real mouse through Finder) | Real Finder drags: hold to share, drop on an orb, drop on a card, drop on a screen edge; optional effect screenshots |

### Commands

```sh
# Unit + integration
xcodebuild test -project DeskDrop.xcodeproj -scheme DeskDrop -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -only-testing:DeskDropTests

# UI (drives the mouse and keyboard for about 20 s)
xcodebuild test -project DeskDrop.xcodeproj -scheme DeskDrop -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -only-testing:DeskDropUITests

# Real Finder drags (run one at a time on an idle Mac; each opens and closes its own Finder window)
TEST_RUNNER_DESKDROP_FINDER_DRAG_TESTS=1 xcodebuild test -project DeskDrop.xcodeproj -scheme DeskDrop \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:DeskDropUITests/DragGestureUITests/testHoldingADraggedFileShowsNearbyColleagues
#   …/testDroppingOnAColleagueAroundAHeldFileSendsIt, …/testDroppingAFileOnAColleagueCardSendsIt,
#   …/testDraggingAFileToTheLeftEdgeSendsIt. Add TEST_RUNNER_DESKDROP_CAPTURE_EFFECTS=1 and run
#   …/testCaptureEffectScreenshots to save screenshots of the effects mid-animation.

# Real Multipeer Connectivity on this Mac
TEST_RUNNER_DESKDROP_NETWORK_TESTS=1 xcodebuild test -project DeskDrop.xcodeproj -scheme DeskDrop \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:DeskDropTests/MultipeerOnThisMacTests
```

### Coverage

- **Protocol codec:** round trip of every message type; version checked before decoding; malformed JSON, wrong types, bad UUIDs, unknown message types, missing fields; 1 MiB cap on decode and encode; unknown reasons from newer peers; resource-name parsing.
- **Names and paths:** separators, control and bidi characters, `.` and `..`, Unicode normalization, 255-byte truncation keeping the extension, display names; traversal (`../`, absolute, `a//b`, `./`), depth and length limits, containment.
- **Offer validation:** counts, negative or overflowing sizes, total mismatch, digest and type-identifier format, case-insensitive duplicates, file-versus-folder conflicts, traversal.
- **State machine:** both happy paths, terminal immutability, illegal jumps, cancel and fail from any active phase, duplicate transfer-ID memory, history mapping, titles.
- **Files:** sender preparation (digest, folder expansion, skipping links and `.DS_Store`, empty files, duplicate names, missing items, empty folders), streaming SHA-256, conflict resolution (Keep both and Replace), destination validation and free space, custom folder bookmark, assembler (verify, quarantine, cleanup, size and digest tampering, unexpected indices), history persistence, size cap, corrupt-file recovery.
- **Formatting:** sizes, progress, speed, time remaining, sliding-window throughput, relative dates.
- **End to end over loopback** (two real `TransferService`s, real files, real codec): accept and byte-identical delivery; decline writes nothing; idempotent Accept and Decline; folders with structure and empty files; empty-file transfer; no overwrites; corrupted contents rejected on both sides; sender cancel; recipient cancel mid-transfer cleans staging; disconnect fails both sides; expiry; duplicate transfer ID; traversal offer refused before display; unsolicited offers and resources ignored; pending-offer flood limit; no space at accept; two simultaneous transfers; source deleted before sending; retry.
- **Drop handling:** `NSItemProvider` callbacks off the main thread (guards against an isolation trap), web URLs ignored.
- **Chat:** text sanitization and validation (control and bidi characters, length, future timestamps, bad sender IDs); storage (time order, duplicates, reload after relaunch, unread and mark-read, delivery only moving forward, deleting and clearing, corrupt file); service over loopback (one-on-one delivery and receipt, offline outbox flushed on connect, community broadcast, catching up after being away without a notification per message, forged sender dropped, rate limit, open conversation marked read, older peers queue); codec (all chat types, optional hello capabilities, oversized history batch refused); reactions (sent, changed and removed between Macs; impostor, cross-conversation, non-emoji and unknown-message reactions refused; reactions arrive with the group catch-up; grouping and persistence); read receipts (opening a conversation turns the sender's messages to *Read* with a time, later messages are read while it stays open, and with receipts off the sender only sees *Delivered*); emoji validation and name search.
- **Messages 1.7:** Markdown parsing and link filtering; GIF and sticker validation and fallbacks; GIPHY decoding; image processing and acceptance; media library persistence; profile photos and sticker images exchanged over loopback, with forged, mismatched and unsolicited images refused.
- **Sounds:** the bundled sound is a CAF under 30 s; built-in choices and fallback for a missing custom sound; added files are converted to CAF and trimmed to the limit; non-audio files are refused.
- **Gestures:** gesture settings and edge assignments persist, forged assignments are ignored, a colleague belongs to one edge and resolves only while nearby, portal frames sit on the outer edge, overlay coordinates convert per display, animation curves stay in range.

The loopback stands in for the network. It runs everything above the transport for real, but **it is not evidence that two Macs can talk to each other.** The Multipeer test and the two-Mac checklist cover that.

### Results in this environment (2026-10-23 to 2026-10-26, macOS 27.0, Xcode 27.0, Apple silicon)

| Run | Result |
|---|---|
| `DeskDropTests` (v1.0.0) | **81 tests in 14 suites passed**; the Multipeer suite is skipped unless opted in |
| `MultipeerOnThisMacTests` with `DESKDROP_NETWORK_TESTS=1` | **Passed**: discovery, invitation, encrypted session, handshake, 8 MiB transfer verified byte-for-byte (about 2.6 s) |
| `DeskDropTests` (v1.2.0) | **104 tests in 18 suites passed** |
| `DeskDropTests` (v1.3.0) | **115 tests in 19 suites passed** |
| `MultipeerOnThisMacTests` (v1.3.0) | **Passed**, now also sending a ❤️ reaction and a read receipt over real Multipeer Connectivity (about 2.7 s in total) |
| `DeskDropTests` (v1.4.0) | **120 tests in 20 suites passed**, adding the alert policy (banner, sound or nothing) and replying from a notification |
| `MultipeerOnThisMacTests` (v1.4.0) | **Passed** |
| Liquid Glass UI (v1.4.0) | Checked in background-window screenshots: Nearby, Messages (group and one-on-one), unread badges, tapbacks, and the incoming panel's buttons. A window-only capture can't show glass over the desktop, so the panel's glass itself was not visually confirmed |
| `DeskDropTests` (v1.5.0) | **121 tests in 20 suites passed**, adding a check that a chosen macOS sound and an added sound can be written where notifications find them. Inside the sandbox this failed with "permission denied" before the new entitlement exception |
| `DeskDropTests` (v1.6.0) | **126 tests in 21 suites passed**, adding: files merged into the timeline (order, a file breaks a run, its own timestamp after a gap); history keeps the colleague, start and type, and 1.5 entries still load; a conversation shows only that colleague's files (old entries by unambiguous name); the list previews the latest file; typing starts, stops and is replaced by the message; no typing when it's switched off or for Macs without the capability; codec round trip of `chatTyping` |
| `DeskDropTests` (v1.7.0) | **167 tests in 31 suites passed**, adding: link previews (first-link detection like Markdown, link-only messages, a preview must match its message's link, image and icon sizes; over loopback a link message waits for its preview, then arrives with it and the image follows from the sender, goes without one when there's none, isn't sent twice when the colleague connects meanwhile, and a forged preview is dropped; and the real LinkPresentation reading a page's title and og:image from a small web server inside the test, in the sandbox); lists while typing (`- `/`* ` become bullets only right after the marker at a line start; Shift-Return continues bullets and numbers, ends the list on an empty item, splits an item at the cursor); Shift-Return and Shift-Enter insert a line break at the cursor (through AppKit's event dispatch too, and in a real SwiftUI vertical `TextField`, whose bound text follows) while Return, other modifiers and input-method composition are left alone; Markdown blocks, inline styles, look-alikes left alone, links limited to web and email, plain previews; GIF and sticker media (GIPHY hosts only, one source, sizes, unknown kinds fall back to text, description for older Macs); GIPHY response decoding; profile photo and sticker processing; image acceptance rules; the media library surviving relaunch; photos exchanged on change and on connect without re-downloading; a sticker's image fetched by hash; unsolicited, mismatched and non-image answers dropped; unknown requests unanswered; codec round trip of `avatar`, `mediaRequest`, `media` and chat `media` |
| `MultipeerOnThisMacTests` (v1.7.0) | **Passed**, now also sending a profile photo and a 530 KB sticker image over real Multipeer Connectivity, byte for byte (3.3 s in total) |
| Messages UI (v1.7.0) | Checked in background screenshots of a test copy (`-DeskDropUITestChatHistory`, which now seeds photos, Markdown, a locally drawn GIF and a sticker): formatted bubbles, the GIF playing, the sticker, photos in the list, header and on the desk card, the **GIF** button and the picker's GIPHY key screen (`-DeskDropUITestMediaPicker`). GIPHY search itself wasn't exercised: there's no API key on this Mac |
| `MultipeerOnThisMacTests` (v1.6.0) | **Passed**, now also showing the typing indicator over real Multipeer Connectivity (the capability travels in the real hello) |
| Files in chat (v1.6.0) | Checked in a background screenshot of a test copy (`-DeskDropUITestChatHistory -DeskDropUITestIncomingOffer -DeskDropUITestTyping`): received image preview with **Open** / **Show in Finder**, sent file declined, live request with **Accept** / **Decline**, typing bubble and *typing…* in the list. `ChatUITests.testFilesAndTypingShowInConversation` (opt-in) checks the same |
| Scrolling (v1.5.0) | Checked with background test copies launched with `-DeskDropUITestLiveMessages`, which adds 40 older messages and then one new message a second, plus `-DeskDropUITestScrolledUp`. At the bottom, the newest message scrolled into view. Scrolled up, the ↓ button appeared, then **↓ 5 New Messages**, and the view stayed put. `ChatUITests.testNewMessagesScrollIntoView` and `testJumpToNewestMessage` cover this; they're opt-in (interactive) |
| Quit to menu bar (v1.5.0) | Not exercised automatically: sending a quit event to a test copy could also hit the user's own running DeskDrop (same bundle ID). Disabled under UI and unit tests |
| Notifications (v1.4.0) | A test copy logs the permission status without asking. On this Mac it reported **denied** (status 1), which is why message banners never appeared. The fix is in System Settings › Notifications; the Settings row now points there. The banner path itself still needs a check with notifications allowed. Note: in zsh, `log` is a shell builtin, so read logs with `/usr/bin/log show` |
| Messages UI (v1.3.0) | Checked in background-window screenshots of a test copy launched with `-DeskDropUITestChatHistory` (bubbles and tails, tapbacks on the corner, *Read* time, group names and avatars) |
| `MultipeerOnThisMacTests` (v1.2.0) | **Passed**, now also sending a one-on-one message (receipt *Delivered*) and a group message over real Multipeer Connectivity |
| `ChatUITests` | History and unread rendering verified in the window (screenshot). The interactive tests weren't run to completion because the Mac was in use and synthesized keystrokes went to the frontmost app. On this Mac, XCUITest's `typeText(" ")` also stalls for 10+ s, so the tests type spaces as key presses |
| `DeskDropTests` (v1.1.0) | **87 tests in 15 suites passed** |
| `DeskDropUITests/DeskDropUITests` | **4 tests passed** |
| `DragGestureUITests` (real Finder drags, run individually) | **All 4 passed.** Logs confirm each step: global mouse-down seen in the sandbox → file drag detected from the drag pasteboard → hold → ring / portal → drop → transfer created |
| `DragGestureUITests` run back-to-back as one suite | Flaky: a synthesized Finder drag sometimes doesn't start, more so while the Mac is in use. That's why the suite is opt-in and documented to run per test |
| Two app instances on one Mac (see below) | Each listed the other as **Available**; header **Ready to share** |
| Debug and universal Release builds | Succeeded with no compiler warnings |
| `scripts/build-release.sh` | Produced an ad-hoc-signed universal `.app` and ZIP; the packaged app launched |

The Finder-drag tests found two problems that unit tests couldn't. `NSEvent.pressedMouseButtons` ignores synthesized input (now `CGEventSource` combined state). A nearly transparent edge strip is skipped by the window server's hit-testing (now painted as a visible glow line).

Running the real-network test exposed a bug that the loopback tests could not: a Multipeer completion handler inferred as main-actor isolated trapped on Multipeer's callback queue. It is fixed, and the same pattern in drop handling now has a regression test.

## Quick check with one Mac

Two instances of the same build can run side by side with different identities. The values come from the command line and are not saved:

```sh
APP=build/DerivedData/Build/Products/Debug/DeskDrop.app
open -n "$APP" --args -installationID 11111111-2222-4333-8444-555555555555 -displayName "Test Mac A"
open -n "$APP" --args -installationID 99999999-8888-4777-8666-555555555555 -displayName "Test Mac B"
```

Start both before transferring: each launch clears the shared temporary staging folder. Both instances share one sandbox container (settings and history). This checks discovery, connection, the UI and drag and drop between real processes, but not radio range, peer-to-peer Wi‑Fi or roaming.

## Two-Mac acceptance test

Use two physical Macs (A sends, B receives) with the same build. Record each result. Steps marked † are the ones that can't be done on a single Mac.

| # | Step | Expected result | Result |
|---|---|---|---|
| 1 | Launch DeskDrop on Mac A and Mac B. | Main window opens; header shows *Discovering nearby Macs*. | |
| 2 | Click **Allow** for local network access on both. | No *Network permission required* status. | |
| 3 † | Wait up to 15 s. | Each Mac shows the other's card with its display name. | |
| 4 † | Check the cards. | Status moves Nearby → Connecting… → **Available**; header shows *Ready to share*. No stale or duplicate cards. | |
| 5 † | On A, drag a small text file from Finder onto B's card; hover, then release. | While hovering, B's card enlarges, glows and says *Release to send*, with a dotted arc from A's card. Nothing is sent until release. | |
| 6 † | Watch A after releasing. | The file arcs from A's card to B's card and bounces in; the card shows *Waiting for response…*. | |
| 7 † | Look at B. | The top-right panel shows A's name, device ID, file name, size and *1 file*, plus Decline and Accept. The main window lists the same request. | |
| 8 † | On B, click **Decline**. | A shows *Declined* and a banner. Nothing new in B's Downloads. | |
| 9 † | Send again; on B click **Accept**. | Both sides show progress, then A shows *Delivered* and B shows *Saved* with Open and Show in Finder. | |
| 10 † | Compare: `shasum -a 256` on both copies. | Hashes match. | |
| 11 † | Send a file of 2 GB or more. | Percentage, bytes, speed and time remaining move steadily; Activity Monitor shows DeskDrop's memory staying flat (no whole-file buffering). | |
| 12 † | Drop three files at once, then a folder with subfolders. | One request each (*3 files*, folder name); structure preserved under Downloads. | |
| 13 † | Send `notes.txt` twice. | B ends up with `notes.txt` and `notes 2.txt`; nothing overwritten. | |
| 14 † | Start a large transfer and click Cancel on A, then repeat cancelling on B. | Both sides show *Cancelled*; no partial file in Downloads. | |
| 15 † | During a large transfer, turn off Wi‑Fi on B (and separately, quit B). | Within about a minute both sides show a clear failure; no spinner left running; A offers **Try Again**. | |
| 16 † | Turn Wi‑Fi back on or relaunch B. | B reappears on A and becomes Available without restarting A. | |
| 17 † | Quit and relaunch both apps. | They find each other again; Recent Activity still lists earlier transfers. | |
| 18 | Do everything above without Terminal. | All of it works from Finder, the window, the panel and the menu bar. | |
| 19 | Watch network activity (e.g. Little Snitch or `nettop -p DeskDrop`). | Only local-network peer traffic. The only internet hosts are `api.giphy.com` (while searching GIFs) and GIPHY's `media*.giphy.com` (while showing GIFs). | |
| 20 † | Send to B, but leave the request unanswered for 2 minutes; also send while B has sharing off. | B's request expires with nothing written; A shows *No response*. With sharing off, B isn't listed at all. | |

| 21 † | On A, assign B to the right edge (right-click B's card). Drag a file in Finder and push it against the far right of A's screen. | A thin glowing line marks the edge during the drag; pushing into it opens a portal showing B; releasing sends, with a light burst from the edge. B gets the request with an arrival glow. | |
| 22 † | On A, drag a file in Finder, pause for about a second over an empty spot. | B appears as an orb around the cursor; moving onto it says *Release to send*; releasing sends. Moving away instead dismisses the ring. | |
| 23 | Drag a file onto a folder in Finder and hover until it springs open, with hold to share on. | The folder still springs open: the orbs never cover the cursor. | |
| 24 | With two displays, drag a file from one display to the other. | No portal opens at the boundary; portals live only on the outer edges. | |

| 25 † | On A, click **Messages** in the header switcher (it opens in the same window), choose B and send a message. | B gets a notification (if DeskDrop isn't in front) and an unread badge; the message shows *Delivered* on A. | |
| 26 † | Quit DeskDrop on B. On A, send B two messages, then relaunch B. | A shows *Waiting for B to connect*; after B relaunches, both arrive and A shows *Delivered*. | |
| 27 † | Quit B. On A, post two messages in **Everyone nearby**. Relaunch B. | B catches up on both group messages, marked unread. | |
| 28 | Quit and relaunch DeskDrop. | All conversations and unread counts are still there. | |

| 29 † | On A, choose a profile photo in **Settings › General**. | Within a few seconds B shows it on A's Mac on the desk, in the conversation list and in the conversation header. Removing it on A brings back A's initials on B. | |
| 30 † | Quit B, change A's photo, relaunch B. | B shows the new photo once it connects. | |
| 31 † | On A, send B a message with `**bold**`, a `- list`, a ```` ``` ```` code block and a link. | B shows it formatted; clicking the link opens the browser; double-clicking copies the Markdown as typed. | |
| 32 † | On A, paste a GIPHY key into the GIF picker, search for a GIF and send it to B. | B shows the GIF playing; right-click › **Open on GIPHY** works. | |
| 33 † | On A, make a sticker from a photo of a person or pet in **My Stickers** and send it to B. | The subject is cut out on A; B shows the same sticker within a second or two, and can **Add to My Stickers**. | |
| 34 † | On A, send B a news article or product page link. Watch B's network activity. | A shows *Sending…* briefly; B gets a card with the picture, title and site, and B's Mac makes no connection to that site. Clicking the card opens it. | |

Also worth checking: closing B's main window still shows requests (panel and menu bar); Reduce Motion (System Settings › Accessibility › Display) replaces the throw with a simple bounce; the receiving folder can be changed in Settings › Receiving; light and dark appearances.
