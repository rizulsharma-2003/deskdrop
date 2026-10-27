import AppKit
import XCTest

/// Messages in the main window, without networking. `-DeskDropUITestPeer` lists one
/// colleague (not actually connected, so one-on-one messages queue), and
/// `-DeskDropUITestChatHistory` seeds a little history into a throwaway chat file.
///
/// Tests that type are opt-in: keystrokes go to whichever app is in front, so run
/// them only on an idle Mac with TEST_RUNNER_DESKDROP_INTERACTIVE_UI_TESTS=1.
final class ChatUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private var interactiveTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["DESKDROP_INTERACTIVE_UI_TESTS"] == "1"
    }

    @MainActor
    private func launchIntoMessages() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-DeskDropUITesting", "-DeskDropUITestPeer",
                               "-DeskDropUITestChatHistory"]
        app.launch()
        let messagesButton = app.descendants(matching: .any)["messagesButton"]
        XCTAssertTrue(messagesButton.waitForExistence(timeout: 10))
        messagesButton.click()
        XCTAssertTrue(app.descendants(matching: .any)["conversationList"].waitForExistence(timeout: 5),
                      "Messages opens inside the main window")
        XCTAssertFalse(app.windows["Messages"].exists, "No separate Messages window")
        return app
    }

    /// A chat bubble whose spoken label contains `text`. (Label only: the window's
    /// scroll bars have numeric values, which a text CONTAINS can't be applied to.)
    @MainActor
    private func message(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chatMessage")
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    @MainActor
    func testHistoryAndUnreadCountsAreShown() throws {
        let app = launchIntoMessages()
        XCTAssertTrue(message(app, containing: "Standup moved to 10:30 today").waitForExistence(timeout: 5),
                      "Saved community history is shown")
        XCTAssertTrue(message(app, containing: "You: Thanks for the heads up").exists, "Your own messages are labelled")

        let colleague = app.descendants(matching: .any)["conversation.direct"].firstMatch
        XCTAssertTrue(colleague.waitForExistence(timeout: 5))
        XCTAssertTrue(colleague.value.map { "\($0)".contains("2") } ?? false || colleague.label.contains("2"),
                      "Two unread one-on-one messages")
        colleague.click()
        XCTAssertTrue(message(app, containing: "do you have the latest build").waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["chatComposer"].exists)
    }

    @MainActor
    func testSwitchingBackToNearbyShowsTheDesk() throws {
        let app = launchIntoMessages()
        app.descendants(matching: .any)["nearbyButton"].click()
        XCTAssertTrue(app.descendants(matching: .any)["deviceCard.you"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["conversationList"].exists)
    }

    @MainActor
    func testSendingToEveryoneAndToAnOfflineColleague() throws {
        try XCTSkipUnless(interactiveTestsEnabled, "Types into the app; run on an idle Mac")
        let app = launchIntoMessages()

        let composer = app.descendants(matching: .any)["chatComposer"]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.click()
        type("Hello from the UI test", into: app)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(message(app, containing: "Hello from the UI test").waitForExistence(timeout: 5),
                      "Return sends the message")

        app.descendants(matching: .any)["conversation.direct"].firstMatch.click()
        composer.click()
        type("Sending it after lunch", into: app)
        app.descendants(matching: .any)["chatSendButton"].click()
        XCTAssertTrue(message(app, containing: "Waiting for Test Colleague to connect").waitForExistence(timeout: 5),
                      "Messages to someone not connected wait in the outbox")
    }

    @MainActor
    private func launchIntoBusyConversation(scrolledUp: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-DeskDropUITesting", "-DeskDropUITestPeer",
                               "-DeskDropUITestOpenMessages", "-DeskDropUITestOpenDirect", "-DeskDropUITestLiveMessages"]
            + (scrolledUp ? ["-DeskDropUITestScrolledUp"] : [])
        app.launch()
        return app
    }

    /// Six messages arrive one a second while you're at the bottom: each scrolls into view.
    @MainActor
    func testNewMessagesScrollIntoView() throws {
        try XCTSkipUnless(interactiveTestsEnabled, "Brings DeskDrop to the front; run on an idle Mac")
        let app = launchIntoBusyConversation(scrolledUp: false)
        let last = message(app, containing: "Live message 6")
        XCTAssertTrue(last.waitForExistence(timeout: 15))
        XCTAssertTrue(last.isHittable, "The newest message is on screen")
        XCTAssertFalse(app.descendants(matching: .any)["newMessagesButton"].exists)
    }

    /// Scrolled up: an arrow, then "N New Messages" when something arrives (without
    /// pulling you down); clicking it goes to the newest message.
    @MainActor
    func testJumpToNewestMessage() throws {
        try XCTSkipUnless(interactiveTestsEnabled, "Clicks in the app; run on an idle Mac")
        let app = launchIntoBusyConversation(scrolledUp: true)
        XCTAssertTrue(app.descendants(matching: .any)["jumpToLatestButton"].waitForExistence(timeout: 5))
        let pill = app.descendants(matching: .any)["newMessagesButton"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        XCTAssertTrue(message(app, containing: "Earlier message 1,").isHittable, "Still where you were reading")
        pill.click()
        let last = message(app, containing: "Live message")
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: pill)
        waitForExpectations(timeout: 5)
    }

    /// Files with a colleague appear in their conversation, including a request
    /// you can accept or decline right there, and the typing indicator.
    @MainActor
    func testFilesAndTypingShowInConversation() throws {
        try XCTSkipUnless(interactiveTestsEnabled, "Brings DeskDrop to the front; run on an idle Mac")
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-DeskDropUITesting", "-DeskDropUITestPeer",
                               "-DeskDropUITestChatHistory", "-DeskDropUITestOpenMessages", "-DeskDropUITestOpenDirect",
                               "-DeskDropUITestIncomingOffer", "-DeskDropUITestTyping"]
        app.launch()
        let files = app.descendants(matching: .any).matching(identifier: "chatFile")
        let offer = files.matching(NSPredicate(format: "label CONTAINS %@", "Quarterly Report.pdf")).firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 10), "The incoming request is in the conversation")
        XCTAssertTrue(app.descendants(matching: .any)["chatFileAccept"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["chatFileDecline"].exists)
        XCTAssertTrue(files.matching(NSPredicate(format: "label CONTAINS %@", "Build 1.6.zip")).firstMatch.exists,
                      "Files you sent are there too")
        XCTAssertTrue(app.descendants(matching: .any)["typingIndicator"].exists)
    }

    /// Types at the app level (XCUITest can't confirm focus on SwiftUI's multi-line
    /// field). Spaces go in as key presses: on some setups `typeText(" ")` stalls
    /// for many seconds, even in plain text fields.
    @MainActor
    private func type(_ text: String, into app: XCUIApplication) {
        for (index, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { app.typeKey(.space, modifierFlags: []) }
            if !word.isEmpty { app.typeText(String(word)) }
        }
    }
}
