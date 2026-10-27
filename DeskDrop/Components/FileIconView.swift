import AppKit
@preconcurrency import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A file's Finder icon, upgraded to a Quick Look thumbnail when one is available.
struct FileIconView: View {
    enum Source: Equatable {
        case file(URL)
        case type(String?, isFolder: Bool)
    }

    let source: Source
    var size: CGFloat = 40
    var showsThumbnail = true

    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? Self.icon(for: source))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: source) { await loadThumbnail() }
            .accessibilityHidden(true)
    }

    static func icon(for source: Source) -> NSImage {
        switch source {
        case .file(let url):
            return NSWorkspace.shared.icon(forFile: url.path)
        case .type(let identifier, let isFolder):
            if isFolder { return NSWorkspace.shared.icon(for: .folder) }
            if let identifier, let type = UTType(identifier) { return NSWorkspace.shared.icon(for: type) }
            return NSWorkspace.shared.icon(for: .data)
        }
    }

    private func loadThumbnail() async {
        thumbnail = nil
        guard showsThumbnail, case .file(let url) = source else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return }
        thumbnail = representation.nsImage
    }
}

extension Transfer {
    /// The best icon source for this transfer: the real file when there is one.
    var iconSource: FileIconView.Source {
        if direction == .outgoing, sourceURLs.count == 1, let url = sourceURLs.first { return .file(url) }
        if direction == .incoming, phase == .completed, savedURLs.count == 1, let url = savedURLs.first { return .file(url) }
        return .type(primaryTypeIdentifier, isFolder: isSingleFolder)
    }
}
