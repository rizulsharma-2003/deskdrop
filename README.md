# DeskDrop

Send files to colleagues sitting near you by dropping them on their Mac.

DeskDrop finds other Macs running DeskDrop on the same network and shows them side by side. Drag a file from Finder onto a colleague's Mac and it arcs across to them. They get a request with your name, the file name and size, and choose **Accept** or **Decline**. Only after they accept is the file sent, directly between the two Macs over an encrypted connection. It is checked against a SHA-256 digest and saved to their Downloads folder.

No accounts, no cloud, no server, no analytics.

> DeskDrop uses its own protocol on top of Apple's Multipeer Connectivity framework. It is **not** AirDrop, does not speak the AirDrop protocol, and is not affiliated with Apple.

## What works

- **Discovery** of nearby DeskDrop Macs with Multipeer Connectivity, with accurate status for each one: Nearby, Connecting…, Available, Not responding, Update needed.
- **Drag and drop from Finder** onto a colleague's card. You can also click a card (or use VoiceOver's "Send Files…" action) to pick files.
- **Hold to share, from anywhere.** Start dragging any file in Finder, on the desktop or in another app, then hold still for a moment. Nearby colleagues pop up as glowing orbs around the cursor; drop on one to send. DeskDrop's window doesn't need to be open.
- **Screen edges for colleagues.** Assign a colleague to the left or right edge of your screen. Drag a file and push it against that edge: a portal opens showing them, and releasing sends the file.
- **Proximity effects.** Sending sets off a burst of liquid light that wells up at the screen edge, with filaments racing along it and sparks drifting off. A matching glow appears at the top corner of the receiving Mac when the request arrives. Reduce Motion swaps it for a gentle fade, and it can be turned off.
- **Chat, styled after Messages.** Message one colleague, or everyone nearby at once in **Everyone nearby**. Blue and grey bubbles with tails, timestamps between conversations, big emoji, and a searchable conversation list. History is saved on your Mac and is there every time you open DeskDrop. Messages to a colleague who's offline wait and are delivered when they reconnect. Colleagues who were away catch up on the group conversation, including reactions, when they connect. Unread counts appear in the header, the Dock and the menu bar.
- **Liquid Glass.** On macOS 26 and later the header, the Nearby | Messages switcher, colleague cards, the Messages sidebar, the floating conversation header and message bar, tapbacks, buttons and the incoming-file panel are made of Liquid Glass. Older macOS versions get the same layout with frosted materials.
- **Reactions.** Hover a message and click the smiley right beside it (or right-click › **React**) for the tapback bar (❤️ 👍 👎 😂 ‼️ ❓), or **+** for any emoji. Reactions sit on the bubble's corner for everyone in the conversation. Double-click a message to copy it.
- **Message notifications.** When DeskDrop isn't in front, or its window is closed or minimized, new messages show a banner with your message sound. Click it to open the conversation, or reply right from the banner. Unread conversations show a blue count badge in the list.
- **Emoji keyboard.** The smiley beside the message box opens a searchable emoji picker with categories and your recent emoji. The full macOS Character Viewer is one click away.
- **Markdown.** Write `**bold**`, `*italic*`, `~~strikethrough~~`, `` `code` ``, links, code blocks, quotes, lists and headings; they show formatted on Macs with DeskDrop 1.7 and as typed on older ones. Web and email addresses become links.
- **GIFs and stickers.** The **GIF** button in the message field searches GIPHY for GIFs and animated stickers. **My Stickers** turns your own pictures into stickers, cutting out the subject like Photos does.
- **Automatic updates.** DeskDrop updates itself from this repository's [GitHub releases](https://github.com/rizulsharma-2003/deskdrop/releases) (and from colleagues' Macs nearby), installing quietly while it isn't in use. Only updates signed with the publisher's key are accepted. See [Publishing updates](#publishing-updates).
- **Link previews.** Links you send arrive with a card showing the page's title, picture and site. Your Mac makes it; colleagues' Macs never contact the site.
- **Profile photos.** Pick a photo in Settings and colleagues see it on your Mac on their desk, in their conversation list and beside your group messages.
- **Read receipts.** One-on-one messages show *Sent*, *Delivered* and then *Read 3:41 PM* once your colleague opens the conversation. Turn off sending your own receipts in Settings.
- **Files in the conversation.** Everything you send to or receive from a colleague appears in your chat with them, in order with the messages, like attachments in Messages. Each file shows a preview for images, the name and size, and live progress. Accept or decline a request right there, then **Open** or **Show in Finder** once it's saved. Click a file to preview it with Quick Look, double-click to open it, or drag it out to Finder. Past transfers from Recent Activity show up too.
- **Typing indicator.** A "•••" bubble (and *typing…* in the conversation list) while your colleague writes to you. Turn off showing yours in Settings.
- **Your own notification sounds.** Pick separate sounds for incoming files and for messages: DeskDrop's sound, any macOS alert sound, or an audio file of your own (MP3, M4A, WAV, AIFF…).
- **Files, multiple files and folders.** Folders are sent as relative paths, with traversal protection. Empty files are included.
- **The throw.** The file lifts off your Mac, arcs with a short light trail, and lands on the recipient's card. It respects Reduce Motion, and the animation never implies delivery.
- **Explicit acceptance.** A floating request panel appears on the recipient's screen even when DeskDrop's window is closed. Multiple requests queue behind each other.
- **Real progress** on both sides: percentage, bytes, measured speed and time remaining, plus cancel.
- **Verified delivery.** Every file is checked against the sender's SHA-256 before it is saved. The sender shows *Delivered* only after the recipient confirms.
- **Safe saving.** Files never overwrite anything: duplicates are numbered ("report 2.pdf"), or you can opt to move the old file to the Trash. Received files are quarantined so Gatekeeper checks them before anything can run.
- **Settings:** profile photo, display name, availability, open at login, receiving folder, notifications, sounds, read receipts, duplicate handling, gestures, appearance, Markdown, GIPHY key and rating, GIF autoplay, stickers.
- **Always reachable.** Quitting with ⌘Q (or from the Dock) keeps DeskDrop running in the menu bar, out of the Dock, so colleagues can still send you files and messages and you still get notifications. **Quit DeskDrop Completely** in the menu bar menu really stops it. Turn this off in **Settings › General**.
- **Menu bar menu** that works with the main window closed: status, availability toggle, open, Messages, Recent Activity, Settings, Quit DeskDrop Completely.
- **Recent Activity:** a local history of names, sizes, people and outcomes. File contents are never stored.

## Requirements

- macOS 14 Sonoma or later, on Apple silicon or Intel (Release builds are universal).
- To build: Xcode 16 or later. This project was built and tested with Xcode 27.0 and Swift 6.4 on macOS 27.0.
- Macs on the same Wi‑Fi or wired network. Multipeer Connectivity can also use peer-to-peer Wi‑Fi between nearby Macs.

## Run it on your Mac

**From Xcode:** open `DeskDrop.xcodeproj`, choose the **DeskDrop** scheme and **My Mac**, then press ⌘R.

**From the command line:**

```sh
xcodebuild -project DeskDrop.xcodeproj -scheme DeskDrop -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/DeskDrop.app
```

The project signs builds **ad hoc** ("Sign to Run Locally"), so no Apple developer account is needed to build and run on your own Mac.

### First launch: local network permission

The first time DeskDrop looks for colleagues, macOS asks:

> "DeskDrop" would like to find devices on your local network.

Click **Allow**. Without it DeskDrop can't see anyone, and the header shows *Network permission required* with a button that opens the right place in System Settings. You can change it later under **System Settings › Privacy & Security › Local Network**.

If the Mac's firewall is set to *Block all incoming connections*, colleagues can't connect to you. The normal firewall setting is fine.

## Using DeskDrop

- **Send:** drag files or folders from Finder onto a colleague's Mac and release. The card lights up and says *Release to send* while you hover. You can also click their card to choose files.
- **Hold to share:** while dragging any file, pause for about ¾ of a second. Colleagues appear around the cursor. Move onto one (it grows and says *Release to send*) and let go. Keep moving instead and the ring disappears, so spring-loaded folders still work. The delay is adjustable in **Settings › Gestures**.
- **Screen edges:** right-click a colleague in the main window and choose **Assign to Left Edge** or **Assign to Right Edge** (or use **Settings › Gestures**). While dragging a file, a thin glowing line marks each assigned edge. Push the file against it: the portal opens with that colleague, and releasing sends. With several displays, the edges are the *outer* sides of your whole arrangement (the far left of the leftmost display and the far right of the rightmost), so moving between displays never triggers a portal.
- **Chat:** click **Messages** in the switcher at the top of the window (or press ⌘2, use the menu bar menu, or right-click a colleague › **Message…**). Chat opens right in the main window; **Nearby** (⌘1) takes you back to the desk. Choose **Everyone nearby** or a colleague and type. Return sends; Shift-Return (or Option-Return) adds a new line. Under your last one-on-one message you'll see *Waiting for … to connect*, *Sent*, *Delivered* or *Read* with the time (until they reply). To react, hover a message and click the smiley right beside it, or right-click › **React**; pick the same reaction again to remove it. Double-click a message to copy its text. The smiley button left of the message box opens the emoji picker, and ⌃⌘Space opens the macOS Character Viewer. Drop files onto a colleague's conversation to send them, and transfers with that colleague (including requests to accept) appear just above the message box.
- **Formatting:** type Markdown as you would in Slack or GitHub: `**bold**`, `*italic*` or `_italic_`, `~~strikethrough~~`, `` `code` ``, `[text](https://…)`. On their own lines: ```` ``` ```` to start and end a code block, `> ` for a quote, `- ` or `1. ` for lists, `# ` to `### ` for headings, `---` for a rule. Return sends and Shift-Return (or Option-Return) starts a new line, which stays a new line. Lists work as in Notes: type `- ` or `* ` at the start of a line and it becomes a `•` bullet; Shift-Return then starts the next item (numbered lists count up), and Shift-Return on an empty item ends the list. ⌘Z undoes a bullet you didn't want. Double-click a message to copy exactly what was typed. **Settings › Messages** turns formatting off.
- **GIFs and stickers:** click **GIF** inside the message field. **GIFs** and **Stickers** show what's trending on GIPHY; type to search, click one to send. The first time, paste a free GIPHY API key (create an app at [developers.giphy.com](https://developers.giphy.com/dashboard/) and choose *API*). **My Stickers** holds stickers made from your own pictures: click **+** or drop pictures there. *Remove backgrounds* keeps just the subject. Right-click one of yours to remove it, or a colleague's sticker › **Add to My Stickers** to keep it. In **Settings › Messages** you can set the GIPHY content rating (G by default) and whether GIFs play on their own.
- **Link previews:** paste or type a link and send. The message shows *Sending…* while your Mac loads the page (a few seconds at most), then goes out with a card: picture, title and site. Click the card to open the link, hover it to see the full address, or right-click › **Copy Link**. Only the first link in a message gets a card, and a message that's just a link shows only the card. Pages that block previews, or don't answer in time, send without one. Turn previews off in **Settings › Messages**.
- **Profile photo:** **Settings › General › Choose Photo…**, drop a picture on the circle there, or right-click your Mac on the desk. It's cropped to a square. Colleagues on DeskDrop 1.7 get it right away, and when they next connect if they're away.
- **Sounds:** in **Settings › Receiving › Sounds**, choose a sound for incoming files and another for messages, and press ▶ to preview. **Add Sound File…** takes any audio file macOS can read. DeskDrop converts it and trims it to 30 seconds, because macOS notifications won't play longer sounds. Added sounds (and copies of chosen macOS sounds) are kept as `DeskDrop…` files in `~/Library/Sounds`, where notifications can find them, and can be removed from the same menu. One switch turns all sounds off.
- **Notifications:** DeskDrop asks for permission the first time it opens. **Settings › Receiving › Messages** shows whether notifications are allowed, with **Open Notification Settings…** if they were turned off and **Send Test Notification** to check the banner and sound. If you clicked *Don't Allow* earlier, turn DeskDrop on in **System Settings › Notifications**.
- **Read receipts:** **Settings › Receiving › Messages › Send read receipts** (on by default). With it off, colleagues see *Delivered* but never *Read*; you still see their receipts if they send them.
- **Typing indicator:** **Settings › Receiving › Messages › Show colleagues when I'm typing** (on by default). It only goes to colleagues on DeskDrop 1.6 or later.
- **Files in chat:** drop files on a conversation or click **+** to send. Each transfer appears in the conversation with its progress. Requests from that colleague can be accepted there, and the floating panel still appears as well. Items you sent can be previewed and dragged out only until DeskDrop quits, because macOS's sandbox ends access to them then. Received items stay openable as long as they're where DeskDrop saved them.
- **Receive:** a request appears in the top-right corner of your screen. Nothing is written to disk until you click **Accept**. When it finishes you can **Open** the file or **Show in Finder**. Unanswered requests expire after 2 minutes.
- **Closing the window** keeps DeskDrop running in the menu bar so colleagues can still send to you. **⌘Q** does the same and also removes DeskDrop from the Dock (the first time, it explains this). To stop DeskDrop, choose **Quit DeskDrop Completely** from the menu bar icon. Logging out, restarting and shutting down always quit normally. Opening DeskDrop again (Dock, Finder, Spotlight or the menu bar) brings the window back. To have DeskDrop running after a restart, turn on **Open DeskDrop at login**.
- **Reading a conversation:** new messages scroll into view while you're at the bottom. If you've scrolled up, DeskDrop leaves you there and shows **↓ N New Messages**; otherwise a round ↓ button jumps to the newest message. **+** to the left of the message field sends files to that colleague; the smiley inside the field opens emoji.
- **Turning sharing off** (menu bar, the Sharing menu, ⇧⌘E, or Settings) hides you from others and cancels transfers in progress.

## Installing on colleagues' Macs

Colleagues don't need Xcode or any developer tools. Build a shareable copy:

```sh
scripts/build-release.sh
```

This produces `dist/DeskDrop-1.7.0.dmg` (the one to share), plus `dist/DeskDrop-1.7.0.zip` and `dist/DeskDrop.app`. Add `GIPHY_API_KEY=your-key` in front of the command to build in a GIPHY key, so nobody has to paste one. It's a universal build, signed **ad hoc** by default. The DMG contains the app, an Applications shortcut, and an *Install DeskDrop.txt* with the steps below. How smoothly it opens on another Mac depends on how it's signed:

| Build | How it's made | On a colleague's Mac |
|---|---|---|
| **Local build** | Xcode ⌘R / `xcodebuild` | Runs only on the Mac that built it. |
| **Ad-hoc signed ZIP** (default) | `scripts/build-release.sh` | Gatekeeper blocks the first launch. See the steps below. |
| **Developer ID signed** | `DESKDROP_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" scripts/build-release.sh` | Identifies the developer, but still warns until it's notarized. |
| **Developer ID + notarized** | Also set `DESKDROP_NOTARY_PROFILE` (see below) | Opens normally, like any downloaded app. |

**Opening the ad-hoc build on another Mac**

1. Send them `DeskDrop-1.7.0.dmg` (about 3 MB) by Slack, email or a shared drive.
2. They open the DMG and drag **DeskDrop** onto the **Applications** shortcut.
3. They open it. macOS says it can't verify the developer. They click **Done** (not *Move to Trash*).
4. They open **System Settings › Privacy & Security**, scroll to the message about DeskDrop, click **Open Anyway**, and confirm.
5. They click **Allow** when DeskDrop asks for local network access.

On macOS 14 they can instead Control-click DeskDrop in Applications, choose **Open**, then **Open** again. If an IT administrator prefers the command line, `xattr -dr com.apple.quarantine /Applications/DeskDrop.app` does the same. Either way it's needed only once per Mac and per build.

**Notarized distribution** (recommended for a team) needs an Apple Developer Program membership:

```sh
# One-time: store notarization credentials in the keychain.
xcrun notarytool store-credentials deskdrop-notary --apple-id you@example.com --team-id TEAMID
# Then:
DESKDROP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
DESKDROP_NOTARY_PROFILE=deskdrop-notary \
scripts/build-release.sh
```

The current builds are **not notarized**. Notarization can't be done without the team's credentials.

## Publishing updates

DeskDrop updates itself from the latest release of [rizulsharma-2003/deskdrop](https://github.com/rizulsharma-2003/deskdrop/releases) (set in `Config/DeskDrop.xcconfig`), and colleagues' Macs also pass updates to each other.

**Once (already done for this repository):**

```sh
scripts/update-key.sh create   # makes the signing key, stores it in your login keychain,
                               # writes the public half to Config/UpdateKey.xcconfig
scripts/update-key.sh export   # prints the private key: save it in your password manager
```

Colleagues install DeskDrop once from a release's DMG; from then on it updates itself.

**For each new version:**

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in the project and add the version to CHANGELOG.md. Its section becomes the "What's new" text.
2. Commit and push.
3. Run `scripts/publish-release.sh`. It builds (signing the update with your key from the keychain), tags the commit `v<version>` and creates the GitHub release with the DMG and `DeskDrop-<version>.deskdropupdate`.

Every copy of DeskDrop checks GitHub at launch and every 6 hours. A newer release is downloaded and checked in the background. With **Install updates automatically** on (the default in release builds, in Settings › About; Debug builds from Xcode never install on their own), it's installed while DeskDrop isn't in front and nothing is transferring, and DeskDrop reopens as it was with a "DeskDrop updated" notification. With it off, people see **Update to <version>** in the header, the menu bar and a notification, and choose when.

To reach colleagues nearby straight away (or Macs without internet), also open the `.deskdropupdate` in **Settings › About › Publish Update…**: Macs nearby are offered it and download it from yours, then pass it on.

**How it's kept safe:** GitHub is only a place to download from; nothing is trusted because it came from there. Only packages signed with your private key are accepted, checked by every Mac against the public key built into its copy and again by the installer helper. A package must be for DeskDrop, newer than what's installed, intact (SHA-256), and contain a validly code-signed app. If your build is signed with a Developer ID, updates must be signed by the same team. Keep the private key safe: anyone with it can publish DeskDrop updates to your colleagues. If it's lost, publish a new key in a build that colleagues install by hand.

The installer helper (`DeskDropUpdater.xpc`, inside the app) runs outside the App Sandbox, because a sandboxed app can't replace itself and every file it writes is quarantined. It can only install a signed, newer DeskDrop over the copy it's in. Installing needs permission to write where DeskDrop is (normally /Applications, which administrator accounts have).

## Tests

```sh
# Unit + integration tests (no network needed)
xcodebuild test -project DeskDrop.xcodeproj -scheme DeskDrop -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -only-testing:DeskDropTests

# UI tests (briefly drives the mouse and keyboard)
xcodebuild test -project DeskDrop.xcodeproj -scheme DeskDrop -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -only-testing:DeskDropUITests

# Typing tests for Messages (types into the frontmost app; use an idle Mac)
TEST_RUNNER_DESKDROP_INTERACTIVE_UI_TESTS=1 xcodebuild test -project DeskDrop.xcodeproj -scheme DeskDrop \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -only-testing:DeskDropUITests/ChatUITests

# Real Finder drags for the gestures, card and edge drops (drives the mouse; use an idle Mac)
TEST_RUNNER_DESKDROP_FINDER_DRAG_TESTS=1 xcodebuild test -project DeskDrop.xcodeproj -scheme DeskDrop \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:DeskDropUITests/DragGestureUITests/testDraggingAFileToTheLeftEdgeSendsIt

# Real Multipeer Connectivity between two peers on this Mac (needs local network permission)
TEST_RUNNER_DESKDROP_NETWORK_TESTS=1 xcodebuild test -project DeskDrop.xcodeproj -scheme DeskDrop \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:DeskDropTests/MultipeerOnThisMacTests
```

See [docs/TESTING.md](docs/TESTING.md) for what each suite covers, the latest results, and the **two-Mac acceptance checklist**.

## Known limitations

- **Identity isn't verified.** A display name is just a name. Anyone running DeskDrop on your network can call themselves "Alex's Mac". Each request also shows a short device ID to help tell Macs apart, but that isn't cryptographic either. See [docs/SECURITY.md](docs/SECURITY.md).
- **Gestures start from a drag.** macOS doesn't tell apps when you long-press a file, and a sandboxed app can't read Finder's selection. So "hold to share" begins once you start dragging, then pause. Only regular files are detected: items that use file promises (some Mail attachments, Photos) need the main window.
- **Chat has no server.** A one-on-one message is delivered when both Macs are running DeskDrop at the same time. Group history spreads Mac to Mac when colleagues connect, so someone who's never online at the same time as anyone else won't receive it. Chat names aren't verified identities, same as for files.
- **Updates need one manual install first.** Copies from before 1.7.0 (or built without the update key) don't update themselves: install a release's DMG once. GitHub checks need internet; nearby Macs pass updates on without it. GitHub allows about 60 checks an hour from one network address, plenty for an office checking every 6 hours. A Mac that isn't an administrator account may not be allowed to replace DeskDrop in /Applications.
- **Link previews come from your Mac.** Sending a link makes your Mac load that page (as Messages does), so the site sees your Mac's IP address.
- **GIFs need GIPHY.** Searching needs a GIPHY API key and an internet connection, and every Mac that shows a GIF downloads it from GIPHY's servers, so GIPHY sees those Macs' IP addresses (DeskDrop sends GIPHY nothing else). Profile photos and stickers made from your pictures go only between your Macs. Colleagues on DeskDrop 1.6 or earlier see a GIF as a link and a sticker as *[Sticker]*.
- **Transfers don't resume.** If the connection drops, the transfer fails with a clear message and you can **Try Again** from the start.
- **Folders:** regular files and the folder structure are sent. Empty subfolders, symbolic links inside folders, file permissions (including the executable bit) and extended attributes are not. Limit: 1,000 files per transfer. Compress larger folders into a .zip first.
- **Two Macs required for real-world testing.** Discovery, connection and transfer have been verified between two processes on one Mac. Range, peer-to-peer Wi‑Fi, sleep and roaming still need two physical Macs ([checklist](docs/TESTING.md#two-mac-acceptance-test)).

## Project layout

```
DeskDrop.xcodeproj
DeskDrop/
  App/            App entry point, app delegate, lifecycle (networking start/stop, incoming panel)
  Models/         Peers, transfers, phases, protocol messages, settings enums
  Networking/     Multipeer Connectivity service, transfer and chat engines, codec, permissions
  FileTransfer/   Sender preparation, hashing, validation, staging, conflict resolution
  Gestures/       System-wide drag detection, hold-to-share ring, screen-edge portals
  State/          View model, settings, history and chat stores
  Views/          Main window, throw animation, receiving panel, gesture overlays and effects, Messages, activity, settings, menu bar
  Components/     Design tokens and reusable controls
  Utilities/      Logging, formatting, timers, small helpers
  Resources/      Info.plist
DeskDropUpdater/  The installer helper (XPC service, outside the sandbox) for in-app updates
Shared/           Update package format, shared by the app, the helper and the signing tool
Config/           DeskDrop.xcconfig; UpdateKey.xcconfig (your public update key, once created)
DeskDropTests/    Swift Testing unit + integration tests
DeskDropUITests/  XCTest UI tests
docs/             Architecture, networking, security, testing
scripts/          build-release.sh, update-key.sh, update-tool.swift, generate-icons.swift
```

More: [Architecture](docs/ARCHITECTURE.md) · [Networking & protocol](docs/NETWORKING.md) · [Security & privacy](docs/SECURITY.md) · [Testing](docs/TESTING.md) · [Changelog](CHANGELOG.md)
