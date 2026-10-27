import AppKit
import LinkPresentation
import UniformTypeIdentifiers

/// Makes the preview for a link you send, with Apple's LinkPresentation (as
/// Messages does): the page's title, its preview image (og:image) and icon. The
/// images are shrunk and kept in the media library so colleagues' Macs can fetch
/// them from yours instead of from the website.
enum LinkPreviewer {
    /// How long LinkPresentation may take to load the page and its images.
    static let fetchTimeout: TimeInterval = 6

    @MainActor
    static func preview(for url: URL, library: MediaLibrary) async -> LinkPreview? {
        let provider = LPMetadataProvider()
        provider.timeout = fetchTimeout
        provider.shouldFetchSubresources = true
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return nil }
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageProvider = metadata.imageProvider.map(UncheckedSendable.init)
        let iconProvider = metadata.iconProvider.map(UncheckedSendable.init)

        // Shrinking the images happens off the main actor.
        let images = await Task.detached(priority: .userInitiated) { () -> (image: Data?, icon: Data?) in
            var image: Data?
            if let imageProvider, let data = await loadImageData(imageProvider.value) {
                image = try? ImageProcessing.linkImage(from: data)
            }
            var icon: Data?
            if let iconProvider, let data = await loadImageData(iconProvider.value) {
                icon = try? ImageProcessing.linkIcon(from: data)
            }
            return (image, icon)
        }.value

        var preview = LinkPreview(url: url, title: title?.isEmpty == false ? title : nil)
        if let data = images.image, let size = ImageProcessing.pixelSize(of: data), let hash = library.store(data) {
            preview.imageHash = hash
            preview.imageWidth = size.width
            preview.imageHeight = size.height
        }
        if let data = images.icon, let hash = library.store(data) {
            preview.iconHash = hash
        }
        return preview.title == nil && preview.imageHash == nil ? nil : preview
    }

    /// The image data an item provider offers, in whatever image format it has.
    nonisolated private static func loadImageData(_ provider: NSItemProvider) async -> Data? {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            // Called on a background queue; `@Sendable` keeps it nonisolated.
            _ = provider.loadDataRepresentation(for: type) { @Sendable data, _ in
                continuation.resume(returning: data.flatMap { $0.count <= 20_000_000 ? $0 : nil })
            }
        }
    }
}
