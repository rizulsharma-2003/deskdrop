# Changelog

## 1.8.0 — 2026-10-27

### Changed
- **Nearby has the new Liquid Glass look, like Messages.** It now has a floating glass sidebar beside a rounded stage, and keeps its place when you switch between Nearby and Messages.
  - **The stage:** a large *Nearby* title showing how many colleagues are around and how many are available, with a glass refresh button. Macs are laid out in centred rows that wrap when the window is narrow.
  - **The Activity sidebar:** transfers in progress at the top, with progress, Accept/Decline and Cancel, and your 40 most recent transfers below them, with who, when and how each one ended. Hover a file you received to show it in Finder, or a failed transfer to try it again. **See All** opens Recent Activity.
  - **The sending hint:** now floats over the bottom of the stage on glass.

## 1.7.0 — 2026-10-26

### Added
- **Markdown in messages.** `**bold**`, `*italic*`, `~~strikethrough~~`, `` `code` `` and `[links](https://…)` inline, and on their own lines ```` ``` ```` code blocks, `> quotes`, `- lists`, `1. lists`, `# headings` and `---` rules. Web addresses and email addresses become links. A single Return still starts a new line, as in chat. Messages are sent exactly as typed, so colleagues on older versions see the plain text. Links open only web pages and email; anything else (`file:`, `javascript:`, app links) shows as plain text. Turn it off in **Settings › Messages**.
- **Profile photos.** Choose a picture in **Settings › General** (or drop one on the circle, or right-click your Mac on the desk). DeskDrop crops it to a square and colleagues see it on your Mac's screen on their desk, around a held file, on edge portals, in their conversation list and beside your group messages. It updates on their Macs as soon as you change it, and stays while you're away.
- **GIFs from GIPHY.** The **GIF** button in the message field opens trending GIFs and search. Click one to send it. GIFs play in the conversation (they stay still with Reduce Motion, or play on hover if you turn off autoplay), double-click copies one, and right-click › **Open on GIPHY** shows the source.
- **Stickers.** The same picker has GIPHY's animated stickers and **My Stickers**: make stickers from your own pictures, and DeskDrop cuts out the subject (Vision's subject lifting) and trims it. Drop pictures on the picker or click **+**. Stickers appear without a bubble and take reactions like any message. Right-click a colleague's sticker › **Add to My Stickers** to keep it.
- **Link previews.** Send a link and the message carries a card with the page's title, picture (og:image) and site, like a rich link in Messages. Your Mac makes the preview with Apple's LinkPresentation when you send (the message shows *Sending…* for a moment, at most 8 seconds), and colleagues' Macs get the picture from yours, so they never contact the website. A message that's only a link shows just the card. Click the card to open the link; hover to see the full address; right-click to copy it.
- **Automatic updates from GitHub.** DeskDrop checks the latest release of [rizulsharma-2003/deskdrop](https://github.com/rizulsharma-2003/deskdrop/releases) at launch and every 6 hours (or **Settings › About › Check Now**), downloads a newer version in the background and installs it while DeskDrop isn't in front and nothing is transferring, then reopens as it was (a closed window stays closed) with a "DeskDrop updated" notification. Turn off **Install updates automatically** to be asked instead: **Update to 1.x** in the header, the menu bar and a notification, with what's new. `scripts/publish-release.sh` builds and publishes a release.
- **Updates from nearby Macs, too.** Publish a version from your Mac (**Settings › About › Publish Update…**) and colleagues nearby are offered it straight away; their Macs download it from yours, and pass it on once updated. Updates are signed with your private key (kept in your login keychain); each copy of DeskDrop checks the signature against the public key it was built with, and a small installer helper inside DeskDrop checks it again before replacing anything. The old copy goes to the Trash.
- `scripts/update-key.sh` creates and backs up the signing key; `scripts/build-release.sh` now also writes `dist/DeskDrop-<version>.deskdropupdate`, signed, with this version's changelog as the notes.
- **Settings › Messages:** Markdown on or off, link previews on or off, your GIPHY API key, the GIPHY content rating (G by default), GIF autoplay, and background removal for new stickers.
- Protocol: `avatar`, `mediaRequest`, `media`, `updateAvailable` and `updateRequest` messages, optional `media` and `link` fields on chat messages, and update packages as resources named `update/<version>`. They're sent only to Macs announcing the new `avatar` and `media` capabilities; older Macs get a text description of a GIF or sticker instead.

### Changed
- **Shift-Return starts a new line** in the message field, as in most chat apps (Option-Return still works too). Return alone sends.
- **Lists as you type**, as in Notes: `- ` or `* ` at the start of a line turns into a `•` bullet in the message field. Shift-Return continues a bulleted or numbered list (2., 3., …), and Shift-Return on an empty item ends it.
- The conversation list and notifications show messages without Markdown symbols, and *GIF* or *Sticker* for those.

### Notes
- In-app updates start with the first build made after `scripts/update-key.sh create`: colleagues install that build by hand once (as before), and every update after it arrives in DeskDrop.
- GIF and sticker search needs a free GIPHY API key. Paste it in the picker or in **Settings › Messages**, or build it in with `GIPHY_API_KEY=… scripts/build-release.sh`. Each Mac downloads the GIFs it shows from GIPHY's servers, so GIPHY sees those Macs' IP addresses. Profile photos and your own stickers travel only between your Macs.

## 1.6.0 — 2026-10-23

### Added
- **Files show in the conversation.** Every transfer with a colleague appears in your one-on-one chat, in time order with the messages, as a card styled like an attachment in Messages: blue for files you sent, grey for files you received. Each card shows:
  - an image preview or a Quick Look icon, with the name, size and file count;
  - live progress, with the amount transferred and the time remaining;
  - the outcome: *Waiting for … to accept*, *Delivered*, *Saved*, *… declined* or *Didn't go through*, along with the reason.
- **What you can do with a file card:**
  - **Accept** or **Decline** a request right in the conversation.
  - **Open** or **Show in Finder** once a file is saved.
  - **Cancel** a transfer in progress, or **Try Again** after a failure.
  - Click to preview with Quick Look, double-click to open, drag it out to Finder, or right-click for Quick Look, Open, Show in Finder and Copy.
- Past transfers from Recent Activity appear in the right conversation, and the conversation list previews the latest file (📎). Colleagues you've only exchanged files with get a conversation too.
- **Typing indicator:** an animated "•••" bubble, and *typing…* in the conversation list, while a colleague writes to you one-on-one. It stops when they send, clear the draft or go quiet for 6 seconds. **Settings › Receiving › Messages › Show colleagues when I'm typing** turns yours off.
- Protocol: `chatTyping` (one-on-one, typing or stopped), sent only to Macs that announce the new `typing` capability, so older versions never receive it. No protocol change was needed for files: each Mac shows its own record of the transfer.

### Changed
- Recent Activity now records the colleague's ID, when a transfer started, and the file type, so transfers land in the right conversation at the right place with the right icon. Entries from earlier versions are matched by name, and only when no other known Mac has that name.
- The transfer strip above the message bar is gone. The file cards replace it.
- The *Read* receipt under your last message also disappears when a file arrives after it.

## 1.5.0 — 2026-10-23

### Added
- **Keep running in the menu bar when you quit** (on by default, Settings › General). ⌘Q and the Dock's Quit close DeskDrop's windows and take it out of the Dock, but it keeps running in the menu bar, so files and messages still arrive and notify you. The first time, an alert explains this and offers **Quit Completely**. The menu bar's **Quit DeskDrop Completely** really quits. Logging out, restarting and shutting down always quit.
- **Jump to the newest message.** When you've scrolled up, a round ↓ button takes you to the bottom. If messages arrive meanwhile, it becomes **↓ N New Messages**, and the conversation no longer pulls you down while you're reading.
- **+ button** left of the message field to send files to the colleague (replaces the paper-plane button in the header). The emoji button moved inside the field, as in Messages.
- A **"Notifications are off"** notice at the top of Messages, with **Turn On in System Settings…**, while macOS blocks DeskDrop's banners.

### Fixed
- New messages didn't always scroll into view: scrolling ran before the new row was laid out. On macOS 15 and later, the bottom anchor also kept dragging you down while you read older messages.
- A minimized (or hidden) window still counted as reading the open conversation. New messages there made no sound, showed no banner, were marked read and sent a read receipt. Now only the main window, when it's the window you're using and it's on screen, counts.
- Choosing a macOS sound or adding your own sound for notifications failed silently. In the sandbox, `Library/Sounds` is a link to `~/Library/Sounds`, which DeskDrop wasn't allowed to write. A sandbox exception now covers that one folder.
- The conversation search field was hard to see on the glass sidebar.

## 1.4.0 — 2026-10-23

### Added
- **Liquid Glass** (macOS 26 and later): the header's status, switcher and toolbar group, colleague cards, banners, transfer rows, the Messages sidebar, the floating conversation header and message bar, tapbacks, glass buttons and the incoming-file panel (`NSGlassEffectView`). Messages scroll softly under the floating header and message bar. On macOS 14–15 the same layout uses frosted materials.
- **Unread badges** on conversations: a blue bubble with the count, which pops when a new message arrives. Unread conversations also get a bold name and a blue time.
- **Double-click a message to copy it**, with a "Copied" tag and a trackpad tap. *Copy* is also first in the right-click menu and a VoiceOver action.
- **Notification banners for messages whenever DeskDrop isn't in front or its window is closed or minimized.** Click a banner to open that conversation, or use **Reply** to answer from the banner (which also marks the conversation read). Opening a conversation clears its banners from Notification Center.
- **Settings › Receiving › Messages** shows whether macOS allows DeskDrop's notifications, with **Allow Notifications…**, **Open Notification Settings…** or **Send Test Notification** as appropriate.

### Changed
- The react button now sits right beside the message instead of at the far edge of the column, and it's glass. Double-click no longer opens reactions; use the smiley or right-click › **React**.
- Your own tapbacks are solid blue like your bubbles; other people's are glass.
- DeskDrop asks for notification permission when it opens, instead of when the first alert arrives (which could lose that alert).

### Fixed
- Message notifications could silently fail: a failed permission request was ignored, and "notification not shown" was logged at a level macOS doesn't keep. Both are now logged as errors, and the permission state is visible in Settings.

## 1.3.0 — 2026-10-23

### Added
- **Reactions (tapbacks).** Double-click a message, hover and click the smiley, or right-click › **React**: ❤️ 👍 👎 😂 ‼️ ❓, or **+** for any emoji. One reaction per person per message; pick it again to remove it. Reactions show on the bubble's corner (blue when one is yours, with a count when several people chose the same one), are saved with history, and travel with the group catch-up.
- **Emoji picker** beside the message box: search by name, categories, recent emoji, and a shortcut to the macOS Character Viewer.
- **Read receipts** for one-on-one messages: *Read* with the time appears under your latest message once your colleague has the conversation open. **Settings › Receiving › Messages › Send read receipts** turns off sending yours.
- **Custom notification sounds.** Separate choices for incoming files and messages: DeskDrop's sound, any built-in macOS alert sound, or your own audio file (converted to CAF and trimmed to 30 seconds so notifications can play it). Preview, add and remove them in **Settings › Receiving › Sounds**.
- Protocol: `chatReaction` and `chatRead` messages, and optional `reactions` on history entries. Older versions ignore them.

### Changed
- Messages looks like Apple's Messages: blue and grey bubbles with tails on the last bubble of a run, timestamps centred between conversations, sender names and avatars in the group conversation, large emoji for messages of up to three emoji, a centred conversation header, a searchable conversation list with unread dots and two-line previews, and a rounded message field with an inline send button.
- The delivery status under your last message disappears once your colleague replies, as in Messages. A message still waiting to be sent keeps its status.

## 1.2.2 — 2026-10-23

### Changed
- Incoming files and new messages use DeskDrop's own alert sound (`DeskDrop/Resources/Sounds/DeskDropAlert.caf`, from *tehelka-omlette*). When DeskDrop is in the background the system notification plays it; when DeskDrop is in front (or banners are turned off) the app plays it, except for a conversation you're already reading.
- **Settings › Receiving › Sound:** a switch to turn the sound off, and **Play** to preview it.

## 1.2.1 — 2026-10-23

### Changed
- Messages opens inside the main window instead of a separate window. A **Nearby | Messages** switcher in the header (with the unread count) moves between the desk and chat; ⌘1 and ⌘2 do the same, and the colleague **Message…** item and the menu bar open it there.
- At launch DeskDrop shows its main window without bringing itself to the front, so starting at login doesn't take focus.

### Added
- Drop files onto a colleague's conversation to send them. Transfers with that colleague, including requests waiting for you, appear above the message box.

## 1.2.0 — 2026-10-23

### Added
- **Messages:** one-on-one chat with any nearby colleague, plus an **Everyone nearby** group conversation.
  - History is saved locally (Application Support) and restored on every launch, including unread state.
  - One-on-one messages to an offline colleague wait in an outbox and are delivered when they reconnect, with *Sent* and *Delivered* receipts.
  - When two Macs connect they exchange group messages the other missed, so people catch up.
  - Unread badges in the header, Dock and menu bar; optional notifications; **Message…** on colleague cards; ⌘2.
  - Text is validated and length-limited, live messages must come from the Mac that wrote them, and floods are rate-limited.
- Protocol: `chat`, `chatAck`, `chatSync` and `chatHistory` messages, plus an optional `capabilities` list in `hello`. Older versions ignore the new messages and are shown as needing an update to chat.

### Changed
- The send and arrival effects are rebuilt around the light at the edge or corner: liquid blobs, a white-hot core, filaments along the edge and drifting sparks. The expanding rings and full-screen sheen are gone.
- The Settings effect preview plays both the send burst (at the outer right edge) and the arrival glow.
- DeskDrop always opens its main window at launch, even when macOS restores no windows (for example on a fresh install).

### Fixed
- VoiceOver didn't read the text of chat bubbles (selectable text dropped out of the combined label), and the unread badge was announced twice.

## 1.1.0 — 2026-10-23

### Added
- **Hold to share:** while dragging a file anywhere on the Mac, hold still and nearby colleagues appear as orbs around the cursor; drop on one to send. It works without DeskDrop's window open.
- **Screen edges:** assign colleagues to the left and right edges (right-click a colleague, or Settings › Gestures). Pushing a dragged file against an assigned edge opens a portal; releasing sends. With several displays, the edges are the outer sides of the whole arrangement.
- **Proximity effects:** a liquid light burst when sending, and a matching glow when a request arrives. Includes a Settings preview, follows Reduce Motion, and can be turned off.
- A **Gestures** tab in Settings: hold toggle and delay, edge toggle and assignments, effects.
- An edge badge on colleagues assigned to a screen edge.

### Changed
- UI tests use their own throwaway settings and history instead of the user's.

### Testing
- Real Finder drags (opt-in UI tests) cover hold-to-share, dropping on an orb, dropping on a card and dropping on a screen edge.
- Unit tests cover edge assignments, gesture settings, overlay coordinate conversion and animation curves.

## 1.0.0 — 2026-10-23

First release.

### Added
- Discovery of nearby DeskDrop Macs over Multipeer Connectivity, with one encrypted session per peer, deterministic invitation tie-breaking, a versioned `hello` handshake, connection timeouts and capped exponential reconnect backoff.
- Drag-and-drop from Finder onto a colleague's card, plus click-to-choose and a VoiceOver action.
- The throw animation, which respects Reduce Motion and is independent of delivery state.
- A versioned, strictly decoded JSON protocol: hello, offer, accept, decline, cancel, complete and failure.
- Explicit acceptance in a floating, non-activating request panel, with a queue for multiple requests and expiry after 2 minutes.
- File, multi-file and folder transfers, using SHA-256 verification, private staging, collision-safe saving, quarantine marking and cleanup.
- Measured progress, speed and time remaining on both sides; cancel; retry for failed outgoing transfers.
- Settings: display name, availability, start on launch, open at login, receiving folder (security-scoped bookmark), notifications, duplicate handling and appearance.
- A menu bar menu, Recent Activity history (metadata only), and optional notifications.
- `scripts/build-release.sh` for universal, ad-hoc or Developer ID signed DMGs and ZIPs, with optional notarization.
- Unit, integration, UI and opt-in real-network tests.
