import AppKit
import Observation
import SwiftUI
import Testing
@testable import DeskDrop

@Suite("Lists while typing a message")
struct ComposerFormattingTests {
    private func space(_ text: String, at cursor: Int? = nil) -> String? {
        let location = cursor ?? (text as NSString).length
        guard let edit = ComposerFormatting.space(in: text, selection: NSRange(location: location, length: 0)) else { return nil }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private func newline(_ text: String, at cursor: Int? = nil) -> String {
        let location = cursor ?? (text as NSString).length
        let edit = ComposerFormatting.newline(in: text, selection: NSRange(location: location, length: 0))
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test("A space after - or * at the start of a line makes a bullet")
    func bullets() {
        #expect(space("-") == "• ")
        #expect(space("*") == "• ")
        #expect(space("Shopping:\n-") == "Shopping:\n• ")
        #expect(space("  -") == "  • ", "Indented items stay indented")
        #expect(space("- ") == nil, "Only right after the marker")
        #expect(space("a-") == nil)
        #expect(space("--") == nil)
        #expect(space("1.") == nil, "Numbered lists stay as typed")
        #expect(space("-x", at: 1) == "• x", "In front of existing text too")
        #expect(space("") == nil)
    }

    @Test("Shift-Return continues a list, numbers included, and ends it on an empty item")
    func continuing() {
        #expect(newline("• Milk") == "• Milk\n• ")
        #expect(newline("Shopping:\n• Milk") == "Shopping:\n• Milk\n• ")
        #expect(newline("  • nested") == "  • nested\n  • ")
        #expect(newline("- dash") == "- dash\n- ")
        #expect(newline("1. one") == "1. one\n2. ")
        #expect(newline("9) nine") == "9) nine\n10) ")
        #expect(newline("• Milk\n• ") == "• Milk\n", "An empty item ends the list")
        #expect(newline("• Milk\n•") == "• Milk\n")
        #expect(newline("2. ") == "")
        #expect(newline("• Milk and eggs", at: 6) == "• Milk\n•  and eggs", "Splits the item at the cursor")
    }

    @Test("Outside a list, Shift-Return is just a new line")
    func plain() {
        #expect(newline("Hello") == "Hello\n")
        #expect(newline("") == "\n")
        #expect(newline("•bold claim") == "•bold claim\n")
        #expect(newline("2024. A year") == "2024. A year\n")
        #expect(newline("• Milk", at: 0) == "\n• Milk", "Before the marker")
    }
}

/// The draft behind a test message field.
@Observable
final class ComposerTestDraft {
    var text = ""
}

@Suite("Message field keys")
@MainActor
struct ComposerKeyTests {
    /// A window (never shown) with a text field being edited.
    private func editingField(_ text: String) throws -> (NSWindow, NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = NSTextField(string: text)
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return (window, editor)
    }

    private func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "\r",
                     in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    @Test("Shift-Return (and Shift-Enter) adds a line break at the cursor")
    func shiftReturn() throws {
        let (window, editor) = try editingField("Hello")
        defer { window.close() }
        #expect(ComposerKeyMonitor.handle(key(36, .shift, in: window), in: window))
        #expect(editor.string == "Hello\n")
        editor.insertText("there", replacementRange: editor.selectedRange())
        #expect(ComposerKeyMonitor.handle(key(76, .shift, in: window), in: window))
        #expect(editor.string == "Hello\nthere\n")
    }

    @Test("Typing - then Space makes a bullet, and the cursor follows it")
    func bullet() throws {
        let (window, editor) = try editingField("-")
        defer { window.close() }
        #expect(ComposerKeyMonitor.handle(key(49, [], " ", in: window), in: window))
        #expect(editor.string == "• ")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
        editor.insertText("Milk", replacementRange: editor.selectedRange())
        #expect(ComposerKeyMonitor.handle(key(36, .shift, in: window), in: window))
        #expect(editor.string == "• Milk\n• ")
        #expect(!ComposerKeyMonitor.handle(key(49, [], " ", in: window), in: window), "An ordinary space")
    }

    @Test("While active, the monitor catches keys as AppKit dispatches them")
    func monitor() throws {
        let (window, editor) = try editingField("Line one")
        defer { window.close() }
        let monitor = ComposerKeyMonitor()
        monitor.isActive = true
        NSApp.sendEvent(key(36, .shift, in: window))
        monitor.isActive = false
        #expect(editor.string == "Line one\n")
        NSApp.sendEvent(key(36, .shift, in: window))
        #expect(editor.string == "Line one\n", "Inactive: nothing is inserted")
    }

    @Test("Return, other modifiers and other keys are left alone")
    func otherKeys() throws {
        let (window, editor) = try editingField("• Hi")
        defer { window.close() }
        #expect(!ComposerKeyMonitor.handle(key(36, in: window), in: window), "Return still sends")
        #expect(!ComposerKeyMonitor.handle(key(76, in: window), in: window), "Enter still sends")
        #expect(!ComposerKeyMonitor.handle(key(36, [.shift, .command], in: window), in: window))
        #expect(!ComposerKeyMonitor.handle(key(36, [.shift, .option], in: window), in: window))
        #expect(!ComposerKeyMonitor.handle(key(0, .shift, "A", in: window), in: window), "Shift-A types A")
        #expect(editor.string == "• Hi")
    }

    @Test("Nothing happens while an input method is composing, or outside a text field")
    func notEditing() throws {
        let (window, editor) = try editingField("")
        defer { window.close() }
        editor.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!ComposerKeyMonitor.handle(key(36, .shift, in: window), in: window))
        editor.unmarkText()

        window.makeFirstResponder(nil)
        #expect(!ComposerKeyMonitor.handle(key(36, .shift, in: window), in: window))
        #expect(!ComposerKeyMonitor.handle(key(36, .shift, in: window), in: nil))
    }

    private struct Field: View {
        @Bindable var draft: ComposerTestDraft

        var body: some View {
            TextField("Message", text: $draft.text, axis: .vertical)
                .frame(width: 280)
        }
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap(textField(in:)).first
    }

    @Test("In a SwiftUI message field like DeskDrop's, the draft follows the edits")
    func swiftUIField() async throws {
        let draft = ComposerTestDraft()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: Field(draft: draft))
        hosting.frame = window.contentView?.bounds ?? .zero
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let field = try #require(textField(in: hosting), "SwiftUI's field is an NSTextField")
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)

        editor.insertText("-", replacementRange: editor.selectedRange())
        #expect(ComposerKeyMonitor.handle(key(49, [], " ", in: window), in: window))
        editor.insertText("Milk", replacementRange: editor.selectedRange())
        #expect(ComposerKeyMonitor.handle(key(36, .shift, in: window), in: window))
        editor.insertText("Eggs", replacementRange: editor.selectedRange())
        await waitUntil("the draft updates") { draft.text == "• Milk\n• Eggs" }
        #expect(MessageMarkdown.blocks(for: draft.text) == [
            .listItem(marker: "•", indent: 0, AttributedString("Milk")),
            .listItem(marker: "•", indent: 0, AttributedString("Eggs")),
        ], "Sent, it shows as a list")
    }
}
