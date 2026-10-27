import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drop handling for a device card. Highlights as soon as a file drag enters,
/// clears when it leaves, and only reports the files when they are released.
struct FileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    /// False for cards that cannot receive (e.g. your own Mac): the cursor shows
    /// "not allowed" while hovering.
    var acceptsDrop = true
    let onDrop: ([URL]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        Log.ui.debug("Drop entered; has file URLs: \(validateDrop(info: info))")
        guard validateDrop(info: info) else { return }
        isTargeted = true
        if acceptsDrop {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: acceptsDrop ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        Log.ui.debug("Perform drop; accepts: \(acceptsDrop)")
        isTargeted = false
        guard acceptsDrop else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.loadFileURL() { urls.append(url) }
            }
            Log.ui.debug("Loaded \(urls.count) of \(providers.count) dropped file URL(s)")
            if !urls.isEmpty { onDrop(urls) }
        }
        return true
    }
}

extension NSItemProvider {
    /// The file URL carried by a Finder drag, if any.
    @MainActor
    func loadFileURL() async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            // Called on a background queue; `@Sendable` keeps it nonisolated.
            _ = loadObject(ofClass: URL.self) { @Sendable url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }
}
