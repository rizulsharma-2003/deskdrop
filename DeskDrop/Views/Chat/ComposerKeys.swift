import AppKit
import SwiftUI

/// Lists in the message field, as in Notes: typing "- " or "* " at the start of a
/// line makes a "• " bullet, and Shift-Return starts a new line that continues a
/// bulleted or numbered list (or ends it, on an empty item). Return alone still
/// sends. Active only while the message field is focused.
struct ComposerKeys: ViewModifier {
    let isActive: Bool
    @State private var monitor = ComposerKeyMonitor()

    func body(content: Content) -> some View {
        content
            .onAppear { monitor.isActive = isActive }
            .onChange(of: isActive) { _, active in monitor.isActive = active }
            .onDisappear { monitor.isActive = false }
    }
}

/// Watches key presses while the message field is focused, and edits its text
/// before the field handles the key itself (where Shift-Return would send).
@MainActor
final class ComposerKeyMonitor {
    private var monitor: Any?

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive {
                // Local monitors run on the main thread, as each event is dispatched.
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    Self.handle(event, in: event.window) ? nil : event
                }
            } else if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }

    /// Applies list formatting for Space or Shift-Return in the text being
    /// edited in `window`. Returns whether the key was used.
    static func handle(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView,
              // Leave keys to an input method that's composing (e.g. Japanese).
              !editor.hasMarkedText() else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }
        let selection = editor.selectedRange()
        let edit: ComposerFormatting.Edit?
        if event.keyCode == 36 || event.keyCode == 76 {
            // Return alone sends; Shift-Return (or Shift-Enter) is a new line.
            guard modifiers.contains(.shift) else { return false }
            edit = ComposerFormatting.newline(in: editor.string, selection: selection)
        } else if event.keyCode == 49 {
            edit = ComposerFormatting.space(in: editor.string, selection: selection)
        } else {
            edit = nil
        }
        guard let edit, editor.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return false }
        editor.breakUndoCoalescing()
        editor.replaceCharacters(in: edit.range, with: edit.replacement)
        editor.didChangeText()
        editor.setSelectedRange(NSRange(location: edit.range.location + (edit.replacement as NSString).length, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        return true
    }
}

/// The text edits behind `ComposerKeyMonitor`, on plain strings so they can be tested.
enum ComposerFormatting {
    struct Edit: Equatable {
        /// UTF-16 range of the text to replace, as `NSTextView` counts.
        let range: NSRange
        let replacement: String
    }

    static let bullet = "•"

    /// Space right after "-" or "*" at the start of a line (indent allowed) turns
    /// the marker into a bullet. Nil means type the space as usual.
    static func space(in text: String, selection: NSRange) -> Edit? {
        let string = text as NSString
        guard selection.length == 0, selection.location > 0, selection.location <= string.length else { return nil }
        let lineStart = string.lineRange(for: NSRange(location: selection.location, length: 0)).location
        let before = string.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        let marker = before.drop { $0 == " " || $0 == "\t" }
        guard marker == "-" || marker == "*" else { return nil }
        return Edit(range: NSRange(location: selection.location - 1, length: 1), replacement: "\(bullet) ")
    }

    /// Shift-Return: a new line. In a list item it starts the next item (with the
    /// same bullet, or the next number); on an empty item it ends the list instead.
    static func newline(in text: String, selection: NSRange) -> Edit {
        let string = text as NSString
        let plain = Edit(range: selection, replacement: "\n")
        guard selection.location <= string.length else { return plain }
        var line = string.lineRange(for: NSRange(location: selection.location, length: 0))
        if string.substring(with: line).hasSuffix("\n") { line.length -= 1 }
        // Only when the cursor (or selection) is within this one line.
        guard NSMaxRange(selection) <= NSMaxRange(line) else { return plain }
        let text = string.substring(with: line)
        guard let item = listItem(text) else { return plain }
        let markerEnd = line.location + (item.prefix as NSString).length
        if item.isEmpty, selection.location >= markerEnd {
            // An empty item: remove its marker, as Return does on an empty bullet in Notes.
            return Edit(range: NSRange(location: line.location, length: line.length), replacement: "")
        }
        guard selection.location >= markerEnd else { return plain }
        return Edit(range: selection, replacement: "\n" + item.next)
    }

    /// A list item's marker ("  • ", "3. "), the marker for the item after it,
    /// and whether the item has no text yet.
    private static func listItem(_ line: String) -> (prefix: String, next: String, isEmpty: Bool)? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(indent.count)
        if let first = body.first, "•-*+".contains(first) {
            let rest = body.dropFirst()
            guard rest.isEmpty || rest.first == " " else { return nil }
            let prefix = indent + String(first) + (rest.isEmpty ? "" : " ")
            return (prefix, "\(indent)\(first) ", rest.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        let digits = body.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count), let number = Int(digits) else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let delimiter = rest.first, delimiter == "." || delimiter == ")" else { return nil }
        let content = rest.dropFirst()
        guard content.isEmpty || content.first == " " else { return nil }
        let prefix = indent + digits + String(delimiter) + (content.isEmpty ? "" : " ")
        return (prefix, "\(indent)\(number + 1)\(delimiter) ", content.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}
