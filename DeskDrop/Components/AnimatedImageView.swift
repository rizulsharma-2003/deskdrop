import AppKit
import SwiftUI

/// Shows an image, playing it if it's an animated GIF. SwiftUI's `Image` only
/// shows the first frame, so this wraps `NSImageView`. Clicks pass through to
/// SwiftUI, so gestures and context menus on the surrounding view still work.
struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage
    var animates = true

    func makeNSView(context: Context) -> PassThroughImageView {
        let view = PassThroughImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isEditable = false
        view.imageFrameStyle = .none
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.animates = animates
        view.image = image
        return view
    }

    func updateNSView(_ view: PassThroughImageView, context: Context) {
        if view.image !== image { view.image = image }
        if view.animates != animates { view.animates = animates }
    }

    final class PassThroughImageView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    }
}
