import SwiftUI
import UniformTypeIdentifiers

/// GIFs and stickers from GIPHY, and stickers you make from your own pictures.
struct MediaPickerView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case gifs
        case stickers
        case mine

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gifs: String(localized: "GIFs")
            case .stickers: String(localized: "Stickers")
            case .mine: String(localized: "My Stickers")
            }
        }

        var catalog: GiphyClient.Catalog { self == .stickers ? .stickers : .gifs }
    }

    enum Pick {
        /// A GIF or sticker from GIPHY.
        case giphy(ChatMedia)
        /// One of your stickers, by hash.
        case mine(String)
    }

    let onPick: (Pick) -> Void

    @Environment(DeskDropViewModel.self) private var model
    @State private var query = ""
    @State private var items: [GiphyClient.Item] = []
    @State private var nextOffset: Int?
    @State private var loading = false
    @State private var failure: GiphyClient.Failure?
    @State private var keyDraft = ""
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    private var apiKey: String { model.settings.effectiveGiphyKey }

    private var tab: Tab { Tab(rawValue: model.settings.mediaPickerTab) ?? .gifs }

    /// Everything that changes which results are shown.
    private struct Search: Equatable {
        let tab: Tab
        let query: String
        let key: String
        let rating: GiphyClient.Rating
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Show", selection: Binding(get: { tab }, set: { model.settings.mediaPickerTab = $0.rawValue })) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("mediaPickerTabs")

            if tab == .mine {
                myStickers
            } else if apiKey.isEmpty || failure == .invalidKey {
                keySetup
            } else {
                searchField
                giphyGrid
                footer
            }
        }
        .padding(10)
        .frame(width: 392, height: 448)
        .task(id: Search(tab: tab, query: query, key: apiKey, rating: model.settings.giphyRating)) {
            await reload()
        }
        .accessibilityIdentifier("mediaPicker")
    }

    // MARK: - GIPHY

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(tab == .stickers ? "Search GIPHY Stickers" : "Search GIPHY", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onAppear { searchFocused = true }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
        .accessibilityIdentifier("giphySearch")
    }

    private var giphyGrid: some View {
        let isStickers = tab == .stickers
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: isStickers ? 4 : 3)
        return ScrollView {
            if items.isEmpty {
                emptyOrError
                    .frame(maxWidth: .infinity)
                    .padding(.top, 90)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(items) { item in
                        GiphyCell(item: item, isSticker: isStickers) {
                            onPick(.giphy(GiphyClient.media(for: item, catalog: tab.catalog)))
                        }
                        .onAppear {
                            if item.id == items.last?.id { Task { await loadMore() } }
                        }
                    }
                }
                if loading {
                    ProgressView().controlSize(.small).padding(8)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyOrError: some View {
        if loading {
            ProgressView().controlSize(.small)
        } else if let failure {
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(failure == .rateLimited ? "GIPHY is busy. Try again in a minute."
                                             : "Can’t reach GIPHY. Check your internet connection.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await reload() } }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            .padding(.horizontal, 30)
        } else {
            Text(query.isEmpty ? "Nothing trending right now" : "No results for “\(query)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    /// GIPHY asks apps to show where results come from.
    private var footer: some View {
        HStack {
            Text("Powered by GIPHY")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(query.isEmpty ? String(localized: "Trending") : String(localized: "Search Results"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var keySetup: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 30))
                .foregroundStyle(Theme.messageBlue)
            Text(failure == .invalidKey ? "GIPHY didn’t accept the API key" : "GIFs and stickers come from GIPHY")
                .font(.system(size: 14, weight: .semibold))
            Text("Paste a free GIPHY API key to search them. Create an app at developers.giphy.com, choose API, and copy its key. Only your searches go to GIPHY.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
            HStack(spacing: 6) {
                TextField("GIPHY API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(saveKey)
                    .accessibilityIdentifier("giphyKeyField")
                Button("Save", action: saveKey)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24)
            Link("Get a Key at developers.giphy.com", destination: URL(string: "https://developers.giphy.com/dashboard/")!)
                .font(.system(size: 11.5))
            Spacer()
        }
        .onAppear { keyDraft = model.settings.giphyAPIKey }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        failure = nil
        model.settings.giphyAPIKey = key
    }

    private func reload() async {
        guard tab != .mine, !apiKey.isEmpty else { return }
        // Wait for a pause in typing before searching.
        if !query.isEmpty {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
        }
        loading = true
        defer { loading = false }
        do {
            let page = try await GiphyClient(apiKey: apiKey)
                .page(tab.catalog, query: query, rating: model.settings.giphyRating)
            items = page.items
            nextOffset = page.nextOffset
            failure = nil
        } catch is CancellationError {
            return
        } catch {
            items = []
            nextOffset = nil
            failure = error as? GiphyClient.Failure ?? .unavailable
        }
    }

    private func loadMore() async {
        guard !loading, let offset = nextOffset, items.count < 240 else { return }
        loading = true
        defer { loading = false }
        let search = (tab, query)
        guard let page = try? await GiphyClient(apiKey: apiKey)
            .page(tab.catalog, query: query, offset: offset, rating: model.settings.giphyRating),
            search == (tab, query) else { return }
        let known = Set(items.map(\.id))
        items += page.items.filter { !known.contains($0.id) }
        nextOffset = page.nextOffset
    }

    // MARK: - My stickers

    private var myStickers: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
        return VStack(spacing: 8) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    addTile
                    if model.makingStickers > 0 {
                        ProgressView()
                            .controlSize(.small)
                            .frame(height: 84)
                    }
                    ForEach(model.library.myStickers, id: \.self) { hash in
                        MyStickerCell(hash: hash) { onPick(.mine(hash)) }
                    }
                }
                .padding(2)
                if model.library.myStickers.isEmpty, model.makingStickers == 0 {
                    Text("Make stickers from your own pictures: DeskDrop cuts out the subject, like lifting it from a photo. Drop pictures here or click +.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 30)
                        .padding(.top, 30)
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.messageBlue, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], delegate: FileDropDelegate(isTargeted: $dropTargeted) { urls in
                model.addStickers(from: urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true })
            })

            @Bindable var settings = model.settings
            HStack {
                Toggle("Remove backgrounds", isOn: $settings.stickerRemovesBackground)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .help(String(localized: "Keep just the subject of each picture, without what’s behind it"))
                Spacer()
                Text("Right-click a sticker to remove it")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var addTile: some View {
        Button { model.chooseStickerImages() } label: {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .overlay(Image(systemName: "plus").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary))
                .frame(height: 84)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Make stickers from pictures…"))
        .accessibilityLabel(Text("Add Stickers"))
        .accessibilityIdentifier("addStickerButton")
    }
}

/// One GIPHY result. The preview plays as soon as it loads.
private struct GiphyCell: View {
    let item: GiphyClient.Item
    let isSticker: Bool
    let action: () -> Void

    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if !isSticker {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.incomingBubble.opacity(0.6))
                }
                if let image {
                    AnimatedImageView(image: image, animates: !reduceMotion)
                        .aspectRatio(isSticker ? CGFloat(item.preview.width) / CGFloat(item.preview.height) : nil,
                                     contentMode: .fit)
                        .padding(isSticker ? 4 : 0)
                }
            }
            .frame(height: isSticker ? 84 : 96)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.messageBlue, lineWidth: hovering ? 2 : 0))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering && isSticker ? Theme.surfaceHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.title)
        .accessibilityLabel(Text(item.title.isEmpty ? String(localized: "GIF") : item.title))
        .task(id: item.preview.url) {
            image = model.remoteImages.cachedImage(for: item.preview.url)
            if image == nil { image = try? await model.remoteImages.image(for: item.preview.url) }
        }
    }
}

/// One of your stickers.
private struct MyStickerCell: View {
    let hash: String
    let action: () -> Void

    @Environment(DeskDropViewModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image = model.library.image(for: hash) {
                    AnimatedImageView(image: image, animates: !reduceMotion)
                        .padding(5)
                } else {
                    Color.clear
                }
            }
            .frame(height: 84)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.surfaceHover : .clear))
            .scaleEffect(hovering ? 1.06 : 1)
            .animation(Theme.Motion.snappy, value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Remove from My Stickers", role: .destructive) { model.library.removeSticker(hash) }
        }
        .accessibilityLabel(Text("Sticker"))
        .accessibilityIdentifier("mySticker")
    }
}
