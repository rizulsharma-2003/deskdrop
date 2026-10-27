import AppKit
import XCTest

/// Opt-in visual check of the send and arrival effects, played from
/// Settings › Gestures › Preview. Saves screenshots of every display mid-animation
/// and prints their paths as EFFECT-SHOT lines.
///
///     TEST_RUNNER_DESKDROP_CAPTURE_EFFECTS=1 xcodebuild test … -only-testing:DeskDropUITests/EffectCaptureUITests
final class EffectCaptureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESKDROP_CAPTURE_EFFECTS"] == "1", "Opt-in visual capture")
    }

    @MainActor
    func testCapturePreviewEffects() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-DeskDropUITesting"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["deviceCard.you"].waitForExistence(timeout: 10))

        app.typeKey(",", modifierFlags: .command)
        let gestures = app.toolbars.buttons["Gestures"]
        XCTAssertTrue(gestures.waitForExistence(timeout: 5))
        gestures.click()
        let preview = app.descendants(matching: .any)["previewEffectButton"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.click()

        let started = Date()
        // Send burst at the right edge, then the arrival glow from ~1.4 s.
        for moment in [0.12, 0.3, 0.55, 0.9, 1.25, 1.6, 1.85, 2.2] {
            let wait = moment - Date().timeIntervalSince(started)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            for (index, screen) in XCUIScreen.screens.enumerated() {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(String(format: "preview-%.2f-screen%d.png", moment, index))
                try? screen.screenshot().pngRepresentation.write(to: url)
                print("EFFECT-SHOT \(url.path)")
            }
        }
    }
}
