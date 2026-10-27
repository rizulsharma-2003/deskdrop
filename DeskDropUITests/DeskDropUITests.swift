import XCTest

/// UI tests launch DeskDrop with `-DeskDropUITesting`, which keeps networking off so
/// no local-network permission prompt can block the run. `-DeskDropUITestIncomingOffer`
/// (Debug builds only) presents one sample offer without a network peer.
final class DeskDropUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(withIncomingOffer: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-DeskDropUITesting"]
        if withIncomingOffer { app.launchArguments.append("-DeskDropUITestIncomingOffer") }
        app.launch()
        return app
    }

    /// Any element whose identifier, label, title or value is `text`. On macOS a
    /// SwiftUI `Text` exposes its string as the value, and controls vary in type.
    @MainActor
    private func element(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label == %@ OR title == %@ OR value == %@", text, text, text, text))
            .firstMatch
    }

    @MainActor
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text))
            .firstMatch
    }

    @MainActor
    func testMainWindowRendersWithoutNetwork() {
        let app = launch()
        XCTAssertTrue(element(app, "deviceCard.you").waitForExistence(timeout: 10), "Your own Mac should always be on the stage")
        XCTAssertTrue(element(app, "networkStatus").exists)
        XCTAssertTrue(element(app, "emptyState").exists)
        XCTAssertTrue(element(app, "Sharing is turned off").exists)
        XCTAssertTrue(element(app, "Turn On Sharing").exists)
        XCTAssertTrue(element(app, "settingsButton").exists)
        XCTAssertTrue(element(app, "historyButton").exists)
    }

    @MainActor
    func testSettingsOpensWithAllSections() {
        let app = launch()
        XCTAssertTrue(element(app, "deviceCard.you").waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        // Settings reopens on the last tab used, so pick each one explicitly.
        let tabs = app.toolbars.buttons
        XCTAssertTrue(tabs["General"].waitForExistence(timeout: 5))
        for tab in ["General", "Receiving", "Appearance", "About"] {
            XCTAssertTrue(tabs[tab].exists, "Missing \(tab) tab")
        }
        tabs["General"].click()
        XCTAssertTrue(element(app, "displayNameField").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "availabilityToggle").exists)

        tabs["Receiving"].click()
        let askFirst = element(app, "askBeforeAcceptingToggle")
        XCTAssertTrue(askFirst.waitForExistence(timeout: 5))
        XCTAssertFalse(askFirst.isEnabled, "Acceptance must stay required")
        XCTAssertTrue(element(app, "changeFolderButton").exists)
    }

    @MainActor
    func testRecentActivityOpens() {
        let app = launch()
        let history = element(app, "historyButton")
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.click()

        let window = app.windows["Recent Activity"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "historyTable").exists || element(app, "historyEmpty").exists)
        XCTAssertTrue(element(app, "clearHistoryButton").exists)
    }

    @MainActor
    func testIncomingTransferIsPresentedAndCanBeDeclined() {
        let app = launch(withIncomingOffer: true)

        let accept = element(app, "acceptButton")
        let decline = element(app, "declineButton")
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "The incoming panel should appear without opening anything")
        XCTAssertTrue(decline.exists)
        XCTAssertTrue(element(app, "Quarterly Report.pdf").exists)
        XCTAssertTrue(element(app, containing: "Test Colleague").exists)

        decline.click()

        XCTAssertTrue(accept.waitForNonExistence(timeout: 5))
        XCTAssertTrue(element(app, "You declined.").waitForExistence(timeout: 5),
                      "The declined transfer should be listed in the main window")
    }
}
