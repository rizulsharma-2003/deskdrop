# Architecture

DeskDrop is a single-target SwiftUI app with AppKit where SwiftUI falls short: the floating incoming panel, the app delegate and window reopening. It uses Swift 6 language mode with complete strict-concurrency checking and has no third-party dependencies.

## Layers

```
┌──────────────────────────────── Views (SwiftUI) ─────────────────────────────────┐
│ MainWindow: Header · DeskStage · DeviceCard · EmptyState · TransferTray · Banner │
│ Throw: FileDropDelegate · ThrowAnimationView · TransferFlightOverlay             │
│ Receiving: IncomingPanelController (NSPanel) · IncomingTransferView · Progress   │
│ Activity · Settings · MenuBar                                                    │
└──────────────────────────────────────┬───────────────────────────────────────────┘
                                       │ reads observable state, calls actions
┌──────────────────────── State (@MainActor, @Observable) ─────────────────────────┐
│ DeskDropViewModel — single instance; derives NetworkStatus, card activity, panel │
│ SettingsStore (UserDefaults) · HistoryStore (JSON in Application Support)        │
└───────────────┬───────────────────────────────────────────────┬──────────────────┘
                │                                               │
┌───────────────▼────────────── Networking ─────────────────────▼──────────────────┐
│ TransferService — protocol state machine for every transfer, both directions     │
│        │ talks only through ▼ PeerTransport (protocol)                           │
│ PeerConnectionService — Multipeer Connectivity: advertise, browse, sessions,     │
│                          handshake, reconnect, resource I/O                      │
│ ProtocolCodec · ProtocolLimits · ResourceName · NetworkPermissions               │
└───────────────┬──────────────────────────────────────────────────────────────────┘
                │
┌───────────────▼────────────── FileTransfer ──────────────────────────────────────┐
│ FileTransferManager (sender: expand folders, sanitize, hash)                     │
│ IncomingTransferAssembler (receiver: stage, verify, finalize, quarantine)        │
│ FileValidationService (NameSanitizer, PathValidator, OfferValidator)             │
│ FileConflictResolver · FileDestinationManager · FileDigest                       │
└──────────────────────────────────────────────────────────────────────────────────┘
```

**Boundaries that matter**

- Views never touch Multipeer Connectivity, files or timers. They read `DeskDropViewModel` and call its methods.
- `TransferService` knows nothing about Multipeer Connectivity. It depends on the `PeerTransport` protocol, so tests run the whole protocol over an in-process loopback.
- `PeerConnectionService` knows nothing about transfers. It delivers decoded messages and resource events to a `PeerTransportDelegate` (the transfer service) and peer lists to the view model.
- Animation state (`flights`, `arrivals` in `DeskStageView`) is purely visual. Nothing about delivery is ever inferred from it.

## Lifecycle

- `DeskDropApp` declares four scenes: the main `Window` (desk and Messages), a `Window` for Recent Activity, `Settings`, and a `MenuBarExtra` in menu style.
- `AppDelegate` owns one `AppLifecycleManager`, which owns the one `DeskDropViewModel` and therefore one connection service. Every scene receives that same model through the environment, so there is never a second discovery service.
- On launch, `AppLifecycleManager` makes sure the main window is visible (macOS may start a menu-bar-capable app with no window, for example on a fresh install), applies the appearance, clears stale staging files, starts the network-path monitor and, if *Start sharing when DeskDrop opens* is on, starts advertising and browsing.
- **Closing the main window does not quit.** `applicationShouldTerminateAfterLastWindowClosed` returns `false`, so DeskDrop keeps receiving and stays in the menu bar. Clicking the Dock icon reopens the window (`applicationShouldHandleReopen`).
- **Quitting keeps DeskDrop in the menu bar** while `SettingsStore.keepRunningInMenuBar` is on.
  - `AppLifecycleManager.shouldTerminate` closes the regular windows, sets the activation policy to `.accessory` (no Dock icon) and returns `.terminateCancel`.
  - `showMainWindow` sets the policy back to `.regular`.
  - The termination really proceeds in three cases: the menu bar's **Quit DeskDrop Completely** (`quitCompletely()`); a quit Apple event that carries a `kAEQuitReason` (logout, restart, shutdown); and UI or unit testing.
- **Real quits** ask for confirmation while a transfer is moving. On quit, active transfers are cancelled (peers are told) and sessions are closed.
- Hosted unit tests (`XCTestConfigurationFilePath` set) never start networking. UI tests pass `-DeskDropUITesting`, which keeps networking off. In Debug builds only, `-DeskDropUITestIncomingOffer` adds one sample offer so the incoming panel can be tested.

## Incoming presentation

`IncomingPanelController` hosts `IncomingPanelView` in a non-activating, floating `NSPanel` in the top-right corner of the main screen. It's visible on all Spaces and doesn't steal focus. `AppLifecycleManager` uses `withObservationTracking` to show the panel whenever `currentPanelTransfer` is non-nil and hide it otherwise. The panel shows the oldest active incoming transfer, with "+N more waiting" for the rest of the queue. When DeskDrop isn't frontmost it also bounces the Dock icon once and, if allowed, posts a notification. The notification only points to the app; accepting always happens in DeskDrop. On macOS 26 and later the panel's content view is an `NSGlassEffectView`.

## Notifications

`AlertPolicy` decides, as a pure function, between a banner, the sound alone, or nothing. "Reading the conversation" requires DeskDrop to be active, the main window to be the key window and on screen, and the conversation to be `ChatService.activeConversation`. `AppLifecycleManager` clears `activeConversation` when the main window is minimized, closed, fully covered or hidden, and restores it when the window becomes key again, so a minimized conversation never marks messages read or sends receipts. `notificationsBlocked` on the view model (refreshed whenever DeskDrop becomes active) drives the "Notifications are off" notice in Messages. A message shows a banner when DeskDrop isn't active or its main window isn't on screen (closed, minimized or fully covered), plays only the sound when DeskDrop is in front, and stays quiet for the conversation you're reading. An incoming file shows a banner only while another app is active, because the request panel is always visible. `NotificationService` is the `UNUserNotificationCenter` delegate. It asks for permission at launch, presents banners even if DeskDrop came to the front in the meantime, opens the conversation when a message banner is clicked, and handles the **Reply** text action (`ChatService.reply`, which marks the conversation read and sends a receipt). Message banners use the conversation as their thread, so opening a conversation removes its delivered banners.

## Drag gestures (hold to share, screen edges)

`Gestures/` adds system-wide gestures without any extra permission:

- **`GlobalDragMonitor`** installs a global monitor for `leftMouseDown`/`leftMouseDragged`. Mouse events can be observed without Accessibility permission, even in the sandbox. While the button is held it polls at 60 Hz: the button state comes from `CGEventSource.buttonState(.combinedSessionState, …)`, the cursor from `NSEvent.mouseLocation`, and the drag pasteboard's `changeCount` and *types*. A file drag is recognised when the drag pasteboard changes and offers `public.file-url`. File contents are never read here; files reach DeskDrop only through a normal drop. During the gesture it holds a `userInitiated` activity so App Nap can't throttle the timer. "Held still" means moving less than 6 pt for the chosen delay.
- **`DragOverlayController`** reacts to those events by creating borderless, non-activating `NSPanel`s that exist only during a file drag:
  - one small panel per colleague orb, arranged on a circle around the held point (clamped to stay on screen). The point under the cursor is left uncovered, so spring-loaded folders keep working;
  - one panel per assigned edge, on the **outer** side of the leftmost or rightmost display. It starts as a 4 pt painted strip and widens into the portal when the drag enters it. Windows are hit-tested by their pixels, so the strip must be visibly painted to receive the drag; a near-transparent one is skipped;
  - one click-through effect layer per display (`ProximityEffectView`) at a lower level, drawing the edge glow, the ring halo and bursts with `Canvas`.
- Drops call the same `DeskDropViewModel.send` as the main window, so consent, verification and progress are unchanged.
- Overlays stay 0.7 s after the button is released so a drop delivered at that moment isn't lost, then they're removed.
- `AppLifecycleManager` enables the monitor only while sharing is on and at least one gesture is enabled, and plays the arrival effect when a request comes in.

The effects use only SwiftUI `Canvas` drawing (radial and conic gradients, additive blending). No Metal shaders, so building doesn't need the separate Metal toolchain.

## Chat

`ChatService` (Networking) runs chat on the same encrypted sessions as file transfers. `PeerConnectionService` routes messages by kind: chat messages to its `chatDelegate`, everything else to the transfer service. Both services get a "peer ready" callback after the handshake. `ChatService` talks to the network only through the small `ChatTransport` protocol, so tests run it over the in-process loopback.

- **Storage:** `ChatStore` (State) keeps messages per conversation in time order, plus last-read times and the last known name of each colleague, in `Application Support/DeskDrop/chat.json`. Writes are batched (0.4 s) and atomic, and flushed on quit. Each conversation keeps its newest 2,000 messages. A corrupt file is moved aside, never silently overwritten.
- **One-on-one:** stored as *pending* first. Sent immediately if the colleague is ready, otherwise the outbox is flushed when they become ready. Then *sent*, and *delivered* when their `chatAck` arrives.
- **Community:** sent to every ready colleague. On connecting, each side sends `chatSync` with its newest community timestamp minus an hour of overlap. The other replies with up to 400 newer messages in batches of 40. Duplicates are dropped by message ID.
- **Unread:** based on the local `receivedAt`, so clock differences between Macs don't matter. A conversation shown in a focused window (`activeConversation`) is marked read as messages arrive.
- **Files in conversations:** `DeskDropViewModel.conversationFiles(with:)` combines the colleague's live transfers (`TransferService.transfers`) with their `HistoryEntry` records.
  - Records are matched by `peerID`. Entries from before 1.6 are matched by name, only when that name is unique among known Macs.
  - Each becomes a `ConversationFile`, with its phase, progress, the live `Transfer` for actions, and a `fileURL` when there's something on disk to preview.
  - `ChatRow.rows(for:files:)` merges messages and files by time. A file breaks a run of bubbles, and a gap of 15 minutes or more gets a timestamp.
  - `FileBubbleView` draws the card and calls the same view-model actions as the transfer tray (accept, decline, cancel, retry, open, reveal). It previews with SwiftUI's `quickLookPreview`.
  - Conversation summaries also consider the latest file.
- **Typing:** `ChatService.draftChanged(in:isEmpty:)` is called as the draft changes. It sends `chatTyping(true)` at most every 3 s and `chatTyping(false)` once when the draft empties; sending a message resets it. Received typing state lives in `typingPeers` and expires after 6 s or when a message arrives. Only colleagues with `PeerDevice.supportsTyping` (the hello's `typing` capability) are sent anything.
- **Read receipts:** when a one-on-one conversation becomes active, or a message arrives while it is, `ChatService` sends `chatRead` for the newest incoming message (once per message, only if `SettingsStore.sendReadReceipts`). The sender's `ChatStore.markReadByRecipient` moves its outgoing messages up to that one to *read* with the time. Delivery only moves forward: pending → sent → delivered → read.
- **Reactions:** `ChatStore` keeps one reaction per person per message (`reactions[messageID][reactorID]`), saved in `chat.json` beside the messages and removed with them. `reactionGroups(for:me:)` groups them by emoji for display. `ChatService.toggleReaction` sends `chatReaction` to the colleague (one-on-one, queued while they're offline) or to everyone ready (group). Group reactions are also attached to `chatHistory` entries so they spread with the catch-up.
- **Sounds:** `NotificationSounds` (Utilities) lists DeskDrop's bundled sound, the macOS alert sounds and sounds the user added. A notification can only play a sound from the app bundle or the container's `Library/Sounds`, in AIFF/WAV/CAF and under 30 s, so added files are converted with `AVAudioFile` to 16-bit PCM CAF and trimmed, and a chosen system sound is copied there as AIFF. `AppLifecycleManager` passes the chosen sound to the notification when DeskDrop is in the background, and plays it directly when DeskDrop is in front.
- **Markdown:** `MessageMarkdown` (Utilities) splits a message into blocks line by line (paragraphs keep single line breaks; fenced code, quotes, lists, headings, rules) and parses inline styles with Foundation's `AttributedString(markdown:)` in inline-only mode, removing links that aren't `http`, `https` or `mailto`. Results are cached by text. `MarkdownTextView` draws the blocks for a blue or grey bubble. `ChatMessage.previewText` gives the plain version for the conversation list and notifications.
- **Profile photos and stickers:** `MediaLibrary` (State) stores images by SHA-256 in `Application Support/DeskDrop/Media`, with `index.json` mapping colleagues to their photo's hash and listing your photo and stickers. `MediaExchange` (Networking) announces your photo when a colleague becomes ready and when it changes, requests missing images by hash, answers requests and checks what arrives. `ChatService` forwards `avatar`, `mediaRequest` and `media` to it, and asks it for a sticker's image when a sticker message arrives. `ImageProcessing` (Utilities) makes square JPEG photos and trimmed PNG stickers (Vision's `VNGenerateForegroundInstanceMaskRequest` for background removal) off the main actor, and validates incoming images.
- **Link previews:** `ChatService.post` holds a message with a web link in `preparingPreviews` while the injected previewer runs (at most 8 s), then dispatches it with `ChatMessage.link`. In the app the previewer is `LinkPreviewer` (Utilities): `LPMetadataProvider` for the title and image and icon providers, with the images shrunk by `ImageProcessing.linkImage`/`linkIcon` and stored in `MediaLibrary`. `LinkPreview.validated(for:)` ties a received preview to the first link in its text. `LinkPreviewCard` draws it under the bubble.
- **GIFs:** `GiphyClient` (Networking) fetches trending and search pages and keeps only renditions on GIPHY's media hosts; `RemoteImageCache` (Utilities) downloads, deduplicates and caches the images. `ChatMedia` on a message says what to show, and `MediaMessageView` shows it with `AnimatedImageView` (an `NSImageView` that plays GIFs and passes clicks through to SwiftUI). `MediaPickerView` is the GIFs / Stickers / My Stickers popover.
- **UI:** Messages is a section of the main window, chosen with the header's `SectionSwitcher` (`DeskDropViewModel.mainSection`). `MessagesView` puts the searchable conversation list beside `ConversationView`. `ChatRow.rows(for:)` turns messages into timestamp headers and runs (a new run when the sender changes or a minute passes), and `MessageBubbleView` draws each one with `BubbleShape` (tail on the last bubble of a run), `ReactionBadges` and the `ReactionBar`/`EmojiPickerView` popovers. `EmojiCatalog` supplies the picker's categories and name search. `ConversationView` tracks whether the newest message is in view. On macOS 15+ it uses `onScrollGeometryChange`; on macOS 14 it watches a marker row appearing and disappearing. New messages scroll in only while you're at the bottom (or when you sent them), a beat after the row is laid out. Otherwise they're counted for the **N New Messages** button. Only the initial scroll position is anchored to the bottom, so arriving messages don't pull you down. A one-on-one conversation is also a file drop target and lists transfers with that colleague. Unread totals feed the switcher badge, the Dock badge (`AppLifecycleManager`) and the menu bar.

## State model

`TransferPhase` is an explicit state machine (see [NETWORKING.md](NETWORKING.md#transfer-lifecycle)). `TransferService.advance(_:to:)` is the only way a phase changes. It refuses illegal transitions, so repeated button presses and late or duplicate network messages are no-ops. Terminal phases trigger teardown (timers, progress objects, staging, security-scoped access), a history entry, and a user-facing explanation.

`NetworkStatus` (header and menu bar) is derived from real inputs only: whether sharing is enabled, the local-network permission probe, `NWPathMonitor`, the discovery state, and peer presence. It shows "No colleagues found" only after a 12-second search grace period.

## Concurrency

- Everything UI-facing is `@MainActor`.
- Multipeer Connectivity calls its delegates on private queues. Each delegate method is `nonisolated` and forwards to the main actor with `DispatchQueue.main.async`, which keeps callbacks in arrival order. The one exception is received resources: Multipeer Connectivity deletes the temporary file when the callback returns, so it is moved into DeskDrop's inbox synchronously first.
- Closures handed to frameworks that call back on their own queues (`sendResource` completion, `NSItemProvider.loadObject`) are explicitly `@Sendable` so Swift doesn't infer main-actor isolation and trap at runtime. A test covers this for drops, and the real-network test covers it for `sendResource`.
- Heavy work (hashing, folder expansion, moving files across volumes) runs in detached tasks. Hashing checks for cancellation between 1 MB chunks.
- Timers live in `ScheduledTasks`, a keyed set of cancellable main-actor tasks. Scheduling a key replaces the previous timer, and teardown cancels them all. No fire-and-forget timers.

## Persistence

| What | Where | Notes |
|---|---|---|
| Settings, installation ID, archived `MCPeerID` | `UserDefaults` (sandbox container) | Nothing sensitive |
| Custom receiving folder | Security-scoped bookmark in `UserDefaults` | Falls back to Downloads if the bookmark can't be resolved |
| Recent Activity | `~/Library/Containers/com.deskdrop.app/Data/Library/Application Support/DeskDrop/history.json` | Atomic writes, 500 entries max; a corrupt file is moved aside |
| In-flight incoming files | `…/Data/tmp/DeskDrop/{Inbox,Incoming}` | Removed on launch and when each transfer ends |
| Chat history | `…/Application Support/DeskDrop/chat.json` | Atomic, batched writes; 2,000 messages per conversation |
| Profile photos and stickers | `…/Application Support/DeskDrop/Media/<sha256>` and `index.json` | Unused old photos are deleted |
| GIPHY downloads | `…/Data/Library/Caches/DeskDrop/GIPHY` | Trimmed to 250 MB, oldest first, at launch |

## Design system

`Components/Theme.swift` holds the tokens: accent blue, violet, cyan, status colors, light and dark surfaces, radii, and three spring/ease timings.

Surfaces use Liquid Glass through one helper in `Components/GlassPanel.swift`. `liquidGlass(_:tint:interactive:in:)` calls `glassEffect` on macOS 26 and later, and draws `ultraThinMaterial` with a hairline and shadow on macOS 14–15, so layouts match everywhere. `GlassGroup` wraps `GlassEffectContainer` so neighbouring glass (the composer, header buttons, a tapback and its dots) renders together and melts together. `glassBackground` and `GlassPanel` build on the same helper.

Button styles follow Apple's rules for glass:
- `SecondaryButtonStyle` and `GlassIconButtonStyle` are glass.
- `IconButtonStyle` stays plain, because it sits on glass panels and glass shouldn't stack.
- `PrimaryButtonStyle` is a solid accent capsule with a `GlassRim`. macOS greys tinted glass in inactive windows, and **Accept** on the never-active request panel must stay blue. Your own tapbacks are solid blue for the same reason. The Mac drawings in `MacIllustration` are SwiftUI shapes, so they scale crisply and light up in the accent gradient. The app icon is generated by `scripts/generate-icons.swift` with Core Graphics.
