import SwiftUI
import UserNotifications

/// DeskDrop › Settings…
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ReceivingSettingsView()
                .tabItem { Label("Receiving", systemImage: "tray.and.arrow.down") }
            MessagesSettingsView()
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
            GestureSettingsView()
                .tabItem { Label("Gestures", systemImage: "hand.draw") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettingsView: View {
    @Environment(DeskDropViewModel.self) private var model
    @State private var nameDraft = ""
    @State private var nameRejected = false
    @State private var launchAtLogin = false
    @State private var loginItemMessage: String?

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                ProfilePhotoRow()
                TextField("Display name", text: $nameDraft)
                    .onSubmit(applyName)
                    .accessibilityIdentifier("displayNameField")
                HStack {
                    Text(nameRejected
                         ? "Enter a name with at least one visible character."
                         : "Colleagues see this name on their DeskDrop. Up to \(ProtocolLimits.maxDisplayNameLength) characters.")
                        .font(.caption)
                        .foregroundStyle(nameRejected ? Theme.danger : .secondary)
                    Spacer()
                    Button("Apply", action: applyName)
                        .disabled(nameDraft == model.settings.displayName)
                        .accessibilityIdentifier("applyNameButton")
                }
            } header: {
                Text("Identity")
            }

            Section("Sharing") {
                Toggle("Available to nearby colleagues",
                       isOn: Binding(get: { model.isSharingEnabled }, set: { model.setSharingEnabled($0) }))
                    .accessibilityIdentifier("availabilityToggle")
                Toggle("Start sharing when DeskDrop opens", isOn: $settings.startSharingOnLaunch)
                Toggle("Open DeskDrop at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Toggle("Keep running in the menu bar when you quit", isOn: $settings.keepRunningInMenuBar)
                    .accessibilityIdentifier("keepRunningToggle")
                Text("⌘Q then closes DeskDrop’s windows and removes it from the Dock, but it stays in the menu bar so colleagues can still reach you and new messages still notify you. To stop it, choose Quit DeskDrop Completely from the menu bar icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let loginItemMessage {
                    HStack {
                        Text(loginItemMessage).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Login Items…") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                }
            }

            Section("Received files") {
                ReceivingFolderRow()
            }
        }
        .formStyle(.grouped)
        .onAppear {
            nameDraft = model.settings.displayName
            launchAtLogin = LaunchAtLogin.isEnabled
            if LaunchAtLogin.needsApproval {
                loginItemMessage = String(localized: "Approve DeskDrop in System Settings › General › Login Items.")
            }
        }
    }

    private func applyName() {
        nameRejected = !model.applyDisplayName(nameDraft)
        nameDraft = model.settings.displayName
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(enabled)
            loginItemMessage = LaunchAtLogin.needsApproval
                ? String(localized: "Approve DeskDrop in System Settings › General › Login Items.") : nil
        } catch {
            loginItemMessage = String(localized: "macOS didn’t allow this change: \(error.localizedDescription)")
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}

/// Your profile photo: choose a picture or drop one on the circle.
private struct ProfilePhotoRow: View {
    @Environment(DeskDropViewModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.accentGradient)
                if let photo = model.profilePhoto {
                    Image(nsImage: photo)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .clipShape(Circle())
                } else {
                    Text(PeerDevice.initials(for: model.settings.displayName))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 60, height: 60)
            .overlay(Circle().strokeBorder(dropTargeted ? Theme.accent : Theme.hairlineStrong, lineWidth: dropTargeted ? 3 : 1))
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(isTargeted: $dropTargeted) { urls in
                if let url = urls.first { model.setProfilePhoto(from: url) }
            })
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Profile photo")
                Text("Colleagues nearby see it on your Mac in their DeskDrop and beside your messages. Drop a picture on the circle, or choose one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(model.profilePhoto == nil ? "Choose Photo…" : "Change Photo…") { model.chooseProfilePhoto() }
                        .accessibilityIdentifier("chooseProfilePhotoButton")
                    if model.profilePhoto != nil {
                        Button("Remove", role: .destructive) { model.setProfilePhoto(data: nil) }
                            .accessibilityIdentifier("removeProfilePhotoButton")
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Markdown, GIFs and stickers.
private struct MessagesSettingsView: View {
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Formatting") {
                Toggle("Show Markdown formatting in messages", isOn: $settings.renderMarkdown)
                    .accessibilityIdentifier("markdownToggle")
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "**bold**   *italic*   ~~strikethrough~~   `code`   [link](https://…)")
                    Text(verbatim: "``` code block ```   > quote   - list   1. list   # heading")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                Text("Messages are sent exactly as you type them; this only changes how they look on this Mac. Links open only web pages and email.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Link previews") {
                Toggle("Show a preview of links I send", isOn: $settings.sendLinkPreviews)
                    .accessibilityIdentifier("linkPreviewsToggle")
                Text("When you send a link, your Mac loads the page and sends its title and picture along with the message, as Messages does. Colleagues’ Macs never contact the website. The message waits a few seconds at most for the preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("GIFs and stickers") {
                LabeledContent("GIPHY API key") {
                    HStack(spacing: 8) {
                        TextField("GIPHY API key", text: $settings.giphyAPIKey,
                                  prompt: Text(GiphyClient.bundledKey == nil ? "Paste your key" : "Using DeskDrop’s key"))
                            .font(.system(size: 12, design: .monospaced))
                            .labelsHidden()
                            .frame(maxWidth: 230)
                            .accessibilityIdentifier("giphyKeySetting")
                        Link("Get a Key", destination: URL(string: "https://developers.giphy.com/dashboard/")!)
                    }
                }
                Text("GIF and sticker search comes from GIPHY and needs a free API key. Only your searches go to GIPHY, never your messages. Colleagues’ Macs download the GIFs you send from GIPHY too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Content rating", selection: $settings.giphyRating) {
                    ForEach(GiphyClient.Rating.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Play GIFs and stickers automatically", isOn: $settings.autoplayGIFs)
                Text("When this is off, they play while the pointer is over them. Reduce Motion in Accessibility settings always keeps them still.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("My stickers") {
                LabeledContent(model.library.myStickers.count == 1 ? String(localized: "1 sticker")
                                                                    : String(localized: "\(model.library.myStickers.count) stickers")) {
                    Button("Make Stickers…") { model.chooseStickerImages() }
                }
                Toggle("Remove backgrounds from new stickers", isOn: $settings.stickerRemovesBackground)
                Text("DeskDrop keeps just the subject of each picture, like lifting it out of a photo in Photos. A colleague’s Mac gets your sticker straight from yours the first time you send it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ReceivingSettingsView: View {
    @Environment(DeskDropViewModel.self) private var model
    @State private var confirmingClearChat = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Requests") {
                Toggle("Ask before accepting files", isOn: .constant(true))
                    .disabled(true)
                    .accessibilityIdentifier("askBeforeAcceptingToggle")
                Text("DeskDrop always asks before saving anything. Automatic acceptance isn’t offered because nearby devices can’t be verified.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Show a notification for incoming files", isOn: $settings.showNotifications)
                    .accessibilityIdentifier("notificationsToggle")
            }

            Section("Destination") {
                ReceivingFolderRow()
            }

            Section("Sounds") {
                Toggle("Play sounds for incoming files and new messages", isOn: $settings.playAlertSound)
                    .accessibilityIdentifier("alertSoundToggle")
                SoundPickerRow(title: String(localized: "Incoming files"), selection: $settings.fileSound,
                               identifier: "fileSoundPicker")
                    .disabled(!settings.playAlertSound)
                SoundPickerRow(title: String(localized: "Messages"), selection: $settings.messageSound,
                               identifier: "messageSoundPicker")
                    .disabled(!settings.playAlertSound)
                Text("Add any MP3, M4A, WAV or AIFF file. DeskDrop converts it and keeps the first 30 seconds, the longest a notification can play.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Messages") {
                Toggle("Show a notification for new messages", isOn: $settings.messageNotifications)
                    .accessibilityIdentifier("messageNotificationsToggle")
                Text("Banners appear when DeskDrop isn’t in front or its window is closed. Click one to open the conversation, or reply right from the banner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NotificationPermissionRow { model.onTestNotification?() }
                Toggle("Send read receipts", isOn: $settings.sendReadReceipts)
                    .accessibilityIdentifier("readReceiptsToggle")
                Toggle("Show colleagues when I’m typing", isOn: $settings.sendTypingIndicator)
                    .accessibilityIdentifier("typingIndicatorToggle")
                Text("When this is on, colleagues see when you’ve read their one-on-one messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Chat history is kept on this Mac only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Message History…", role: .destructive) { confirmingClearChat = true }
                }
            }

            Section("When a file with the same name already exists") {
                Picker("Duplicate names", selection: $settings.duplicateHandling) {
                    ForEach(DuplicateHandling.allCases) { handling in
                        Text(handling.title).tag(handling)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete all chat history on this Mac?", isPresented: $confirmingClearChat) {
            Button("Clear Message History", role: .destructive) { model.chat.store.clearAll() }
        } message: {
            Text("Colleagues keep their own copies.")
        }
    }
}

/// Chooses a sound: DeskDrop's own, a built-in macOS sound, or a file you add.
private struct SoundPickerRow: View {
    let title: String
    @Binding var selection: String
    let identifier: String
    /// Bumped after adding or removing a sound so the menu re-reads the folder.
    @State private var revision = 0
    @State private var importError: String?
    @State private var importing = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(NotificationSounds.builtInOptions) { option in
                        choice(option)
                    }
                    let custom = NotificationSounds.customOptions
                    if !custom.isEmpty {
                        Divider()
                        ForEach(custom) { option in
                            choice(option)
                        }
                    }
                    Divider()
                    Button(String(localized: "Add Sound File…"), action: chooseFile)
                    if NotificationSounds.isCustom(selection) {
                        Button(String(localized: "Remove “\(NotificationSounds.title(for: selection))”"), role: .destructive) {
                            NotificationSounds.removeCustom(selection)
                            selection = NotificationSounds.deskDrop
                            revision += 1
                        }
                    }
                } label: {
                    Text(importing ? String(localized: "Converting…") : NotificationSounds.title(for: selection))
                }
                .fixedSize()
                .id(revision)
                .accessibilityIdentifier(identifier)

                Button {
                    NotificationSounds.play(selection)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Play"))
                .accessibilityLabel(Text("Play \(title) sound"))
            }
        }
        .alert(String(localized: "That sound couldn’t be added"), isPresented: Binding(get: { importError != nil },
                                                                                   set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private func choice(_ option: SoundOption) -> some View {
        Button {
            selection = option.id
            NotificationSounds.play(option.id)
        } label: {
            if option.id == selection {
                Label(option.title, systemImage: "checkmark")
            } else {
                Text(option.title)
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add Sound")
        panel.message = String(localized: "Choose a sound for \(title.lowercased())")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task {
            defer { importing = false }
            do {
                let id = try await NotificationSounds.importSound(from: url)
                selection = id
                revision += 1
                NotificationSounds.play(id)
            } catch SoundImportError.tooLarge {
                importError = String(localized: "The file is too large. Choose a short sound clip.")
            } catch {
                importError = String(localized: "DeskDrop couldn’t read that audio file. Try an MP3, M4A, WAV or AIFF.")
            }
        }
    }
}

private struct GestureSettingsView: View {
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Show nearby Macs when you hold a dragged file still", isOn: $settings.holdToShowNearby)
                    .accessibilityIdentifier("holdToShowToggle")
                Picker("Hold for", selection: $settings.holdDelay) {
                    ForEach(HoldDelay.allCases) { delay in
                        Text(delay.title).tag(delay)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.holdToShowNearby)
                Text("Start dragging any file — from Finder, the desktop or another app — then pause. Your colleagues appear around the cursor; drop on one to send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hold to share")
            }

            Section {
                Toggle("Send by pushing a dragged file against a screen edge", isOn: $settings.edgeSharingEnabled)
                    .accessibilityIdentifier("edgeSharingToggle")
                ForEach(ScreenEdge.allCases) { edge in
                    EdgeAssignmentPicker(edge: edge)
                        .disabled(!settings.edgeSharingEnabled)
                }
                Text("Drag a file to the far left or right of your screen. A portal opens for that colleague — release to send. You can also right-click a colleague in the main window to assign an edge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Screen edges")
            }

            Section {
                Toggle("Glow effects when sending and receiving", isOn: $settings.proximityEffects)
                HStack {
                    Text("Reduce Motion in Accessibility settings swaps the burst for a gentle glow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Preview") { model.onPreviewEffect?() }
                        .disabled(!settings.proximityEffects)
                        .accessibilityIdentifier("previewEffectButton")
                }
            } header: {
                Text("Effects")
            }
        }
        .formStyle(.grouped)
    }
}

/// Chooses which colleague an edge sends to.
private struct EdgeAssignmentPicker: View {
    let edge: ScreenEdge
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        let assignment = model.settings.assignment(for: edge)
        Picker(selection: Binding<String?>(
            get: { assignment?.installationID },
            set: { id in
                if let id {
                    model.assign(id, to: edge)
                } else {
                    model.clearEdge(edge)
                }
            }
        )) {
            Text("Nobody").tag(String?.none)
            if let assignment, model.peer(assignment.installationID) == nil {
                Text("\(assignment.displayName) (not nearby)").tag(Optional(assignment.installationID))
            }
            ForEach(model.nearbyForGesture) { peer in
                Text(peer.displayName).tag(Optional(peer.id))
            }
        } label: {
            Label(edge.title, systemImage: edge.symbolName)
        }
        .accessibilityIdentifier("edgePicker.\(edge.rawValue)")
    }
}

private struct AppearanceSettingsView: View {
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: settings.appearance) { _, mode in
                    NSApp.appearance = mode.nsAppearance
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 3) {
                Text("DeskDrop")
                    .font(.system(size: 20, weight: .semibold))
                Text("Version \(DeviceInfo.appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text("Send files to colleagues sitting nearby by dropping them on their Mac. Transfers go directly between Macs over an encrypted connection.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Privacy", systemImage: "hand.raised")
                        .font(.system(size: 12, weight: .semibold))
                    Text("No accounts, no cloud, no analytics. Files, messages, profile photos and your stickers never leave the Macs involved, and nothing is saved until the recipient accepts. Recent Activity is stored only on this Mac and holds names and sizes, never contents. GIFs come from GIPHY, which sees your searches and each Mac that shows a GIF. A link you send is loaded by your Mac to make its preview.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("DeskDrop uses its own protocol over Apple’s Multipeer Connectivity framework. It is not AirDrop and is not affiliated with Apple. Display names are not verified identities.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            UpdatesBox()

            Text("Documentation is in README.md and the docs folder of the DeskDrop project.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
    }
}

/// Updates (from GitHub and colleagues' Macs), and publishing one if you're the publisher.
private struct UpdatesBox: View {
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let updates = model.updates
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                if !updates.isEnabled {
                    Text("This copy of DeskDrop wasn’t built with an update key, so it can’t receive or share updates. See “Publishing updates” in README.md.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .top) {
                        Text(statusText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(updates.checkFailure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warning))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if updates.available != nil {
                            Button("Update…") { model.showingUpdate = true; NSApp.activate() }
                        } else if updates.hasFeed {
                            Button(updates.isChecking ? "Checking…" : "Check Now") {
                                Task { await updates.checkFeed() }
                            }
                            .disabled(updates.isChecking)
                            .accessibilityIdentifier("checkForUpdatesButton")
                        }
                    }
                    Toggle("Install updates automatically", isOn: $settings.installUpdatesAutomatically)
                        .font(.system(size: 11.5))
                        .disabled(DeskDropViewModel.isDevelopmentBuild)
                        .accessibilityIdentifier("autoUpdateToggle")
                    Text(DeskDropViewModel.isDevelopmentBuild
                         ? "This is a development build, so it only installs updates when you click Update."
                         : "DeskDrop downloads new versions in the background and installs them while it isn’t in front and nothing is being sent, then reopens as it was.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    HStack {
                        Text(updates.shared.map { String(localized: "This Mac shares DeskDrop \($0.version) with colleagues nearby.") }
                             ?? String(localized: "Publishing? Open a .deskdropupdate here to offer it to colleagues nearby right away."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Publish Update…") { model.choosePackageToPublish() }
                            .accessibilityIdentifier("publishUpdateButton")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var statusText: String {
        let updates = model.updates
        if let available = updates.available {
            return available.isDownloaded
                ? String(localized: "DeskDrop \(available.manifest.version) is downloaded and ready to install.")
                : String(localized: "DeskDrop \(available.manifest.version) is available.")
        }
        if let failure = updates.checkFailure { return failure }
        if updates.hasFeed, let checked = updates.lastChecked {
            return String(localized: "DeskDrop \(updates.currentVersion) is up to date. Checked \(checked.formatted(date: .omitted, time: .shortened)).")
        }
        return updates.hasFeed
            ? String(localized: "DeskDrop checks GitHub for updates every few hours, and hears about them from colleagues’ Macs.")
            : String(localized: "DeskDrop hears about updates from colleagues’ Macs when they connect.")
    }
}

/// Shows and changes the receiving folder.
struct ReceivingFolderRow: View {
    @Environment(DeskDropViewModel.self) private var model

    var body: some View {
        LabeledContent("Save received files to") {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: model.receivingFolderPath))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(URL(fileURLWithPath: model.receivingFolderPath).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.receivingFolderPath)
                Button("Change…") { model.chooseReceivingFolder() }
                    .accessibilityIdentifier("changeFolderButton")
                if !model.isUsingDefaultReceivingFolder {
                    Button("Use Downloads") { model.resetReceivingFolder() }
                }
            }
        }
    }
}

/// Whether macOS lets DeskDrop show notifications, with the fix one click away
/// and a test banner to check it.
private struct NotificationPermissionRow: View {
    let sendTest: () -> Void
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(text)
                .font(.callout)
            Spacer()
            switch status {
            case .notDetermined?:
                Button("Allow Notifications…") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                        await refresh()
                    }
                }
            case .denied?:
                Button("Open Notification Settings…") { NotificationService.openSystemSettings() }
            case nil:
                EmptyView()
            default:
                Button("Send Test Notification", action: sendTest)
                    .accessibilityIdentifier("testNotificationButton")
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notificationPermission")
    }

    private func refresh() async {
        status = await NotificationService.authorizationStatus()
    }

    private var text: String {
        switch status {
        case .notDetermined?: String(localized: "DeskDrop hasn’t been allowed to show notifications yet.")
        case .denied?: String(localized: "Notifications are turned off for DeskDrop in System Settings.")
        case nil: String(localized: "Checking notification permission…")
        default: String(localized: "Notifications are allowed.")
        }
    }

    private var symbol: String {
        switch status {
        case .denied?: "bell.slash.fill"
        case .notDetermined?, nil: "bell.badge"
        default: "bell.fill"
        }
    }

    private var color: Color {
        switch status {
        case .denied?: Theme.warning
        case .notDetermined?, nil: .secondary
        default: Theme.success
        }
    }
}
