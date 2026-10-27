import AppKit
import XCTest

/// Drives real drags out of Finder to check that DeskDrop notices a file drag
/// started in another app, shows colleagues around a held file, accepts a drop on
/// a colleague's card, and accepts a drop on an assigned screen edge.
///
/// DeskDrop runs with `-DeskDropUITestPeer` (Debug only): one colleague with no
/// network behind it, so a send creates a real transfer that then waits for a
/// connection. Settings and history use a throwaway defaults suite.
///
/// Opt-in, because they drive the real mouse: run them on an idle Mac with
///     TEST_RUNNER_DESKDROP_FINDER_DRAG_TESTS=1 xcodebuild test … -only-testing:DeskDropUITests/DragGestureUITests/<test>
final class DragGestureUITests: XCTestCase {
    private var folder: URL?
    private var fileName = ""

    @MainActor
    private var finder: XCUIApplication { XCUIApplication(bundleIdentifier: "com.apple.finder") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // These tests move the real mouse through Finder for a couple of minutes and
        // need an otherwise idle Mac, so they only run when asked for.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESKDROP_FINDER_DRAG_TESTS"] == "1",
                          "Set TEST_RUNNER_DESKDROP_FINDER_DRAG_TESTS=1 to drive real Finder drags")
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        // If a drop ever missed DeskDrop, Finder may have moved the file to the
        // Desktop. The name is unique to this run, so it is safe to clean up.
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/\(fileName)")
        if !fileName.isEmpty, FileManager.default.fileExists(atPath: desktop.path) {
            try? FileManager.default.removeItem(at: desktop)
        }
    }

    // MARK: - Tests

    @MainActor
    func testHoldingADraggedFileShowsNearbyColleagues() throws {
        let app = launchDeskDrop(assignLeftEdge: false)
        let item = try fileInFinder()
        defer { closeTestFinderWindows() }

        // Hold over the middle of the menu bar: nothing there accepts the file,
        // so releasing cancels the drag and Finder keeps the file where it was.
        let start = item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let screenWidth = NSScreen.screens.first?.frame.width ?? 1440
        let menuBar = start.withOffset(CGVector(dx: screenWidth / 2 - item.frame.midX, dy: 8 - item.frame.midY))
        start.click(forDuration: 0.4, thenDragTo: menuBar, withVelocity: .default, thenHoldForDuration: 1.8)
        let orb = app.descendants(matching: .any)["nearbyOrb"]
        XCTAssertTrue(orb.waitForExistence(timeout: 3), "Colleagues should appear around a held file")
        XCTAssertEqual(orb.label, "Send to Test Colleague")
        XCTAssertTrue(sourceFileStillExists, "Cancelling the drag must leave the file in place")
    }

    @MainActor
    func testDroppingOnAColleagueAroundAHeldFileSendsIt() throws {
        let app = launchDeskDrop(assignLeftEdge: false)
        let item = try fileInFinder()
        defer { closeTestFinderWindows() }

        // Near the top of a display the ring is pushed down to stay visible, which
        // puts the single colleague's orb right under the held cursor; releasing
        // there drops on the orb. Prefer a display without the Finder window.
        let finderFrame = folder.map { finder.windows[$0.lastPathComponent].frame } ?? .null
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let screen = NSScreen.screens.first { candidate in
            let visible = candidate.visibleFrame
            let xcuiRect = CGRect(x: visible.minX, y: mainHeight - visible.maxY, width: visible.width, height: visible.height)
            return !xcuiRect.intersects(finderFrame)
        } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        let holdPoint = CGPoint(x: visible.midX, y: visible.maxY - 70)
        let start = item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = start.withOffset(Self.offset(from: item.frame, toGlobal: holdPoint))
        start.click(forDuration: 0.4, thenDragTo: target, withVelocity: .default, thenHoldForDuration: 1.8)
        XCTAssertTrue(transferRow(in: app).waitForExistence(timeout: 5), "Dropping on a colleague's orb should start a transfer")
        XCTAssertTrue(sourceFileStillExists, "Sending copies; the original stays in Finder")
    }

    @MainActor
    func testDroppingAFileOnAColleagueCardSendsIt() throws {
        let app = launchDeskDrop(assignLeftEdge: false)
        let item = try fileInFinder()
        defer { closeTestFinderWindows() }
        try placeDeskDropBesideFinder(app)
        let card = app.descendants(matching: .any)["deviceCard.peer"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))

        let start = item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.click(forDuration: 0.4, thenDragTo: target, withVelocity: .default, thenHoldForDuration: 0.3)
        XCTAssertTrue(transferRow(in: app).waitForExistence(timeout: 5), "Dropping on a colleague's card should start a transfer")
        XCTAssertTrue(sourceFileStillExists, "Sending copies; the original stays in Finder")
    }

    @MainActor
    func testDraggingAFileToTheLeftEdgeSendsIt() throws {
        let app = launchDeskDrop(assignLeftEdge: true)
        let item = try fileInFinder()
        defer { closeTestFinderWindows() }

        // Push the file against the outer left edge of the whole display
        // arrangement (an external display may sit left of the main one) and let go.
        let start = item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let leftEdge = start.withOffset(Self.offset(from: item.frame, toGlobal: Self.outerLeftEdgePoint()))
        start.click(forDuration: 0.4, thenDragTo: leftEdge, withVelocity: .default, thenHoldForDuration: 1.0)
        XCTAssertTrue(transferRow(in: app).waitForExistence(timeout: 5), "Dropping on the left edge should start a transfer to its colleague")
        XCTAssertTrue(sourceFileStillExists, "Sending copies; the original stays in Finder")
    }

    /// Opt-in visual check: saves screenshots of the effects mid-animation.
    /// Run with TEST_RUNNER_DESKDROP_FINDER_DRAG_TESTS=1 TEST_RUNNER_DESKDROP_CAPTURE_EFFECTS=1;
    /// paths are printed as EFFECT-SHOT lines.
    @MainActor
    func testCaptureEffectScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DESKDROP_CAPTURE_EFFECTS"] == "1", "Opt-in visual capture")
        let app = launchDeskDrop(assignLeftEdge: true)

        // 1. Colleagues around a held file (stays 4 s after release in UI tests).
        let item = try fileInFinder()
        defer { closeTestFinderWindows() }
        let start = item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let main = NSScreen.screens.first
        let middle = CGPoint(x: (main?.frame.midX ?? 700) + 200, y: (main?.visibleFrame.midY ?? 450) + 60)
        start.click(forDuration: 0.4, thenDragTo: start.withOffset(Self.offset(from: item.frame, toGlobal: middle)),
                    withVelocity: .default, thenHoldForDuration: 1.6)
        Thread.sleep(forTimeInterval: 0.3)
        capture("ring")

        // 2. Sending through the left edge.
        let item2 = try fileInFinder()
        let start2 = item2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start2.click(forDuration: 0.4, thenDragTo: start2.withOffset(Self.offset(from: item2.frame, toGlobal: Self.outerLeftEdgePoint())),
                     withVelocity: .default, thenHoldForDuration: 1.0)
        Thread.sleep(forTimeInterval: 0.25)
        capture("edge-burst-a")
        Thread.sleep(forTimeInterval: 0.3)
        capture("edge-burst-b")
    }

    @MainActor
    private func capture(_ name: String) {
        for (index, screen) in XCUIScreen.screens.enumerated() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("effect-\(name)-screen\(index).png")
            try? screen.screenshot().pngRepresentation.write(to: url)
            print("EFFECT-SHOT \(url.path)")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func launchDeskDrop(assignLeftEdge: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-DeskDropUITesting", "-DeskDropUITestPeer"]
        if assignLeftEdge { app.launchArguments.append("-DeskDropUITestLeftEdge") }
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["deviceCard.peer"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func transferRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "To Test Colleague", "To Test Colleague"))
            .firstMatch
    }

    private var sourceFileStillExists: Bool {
        guard let folder else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName).path)
    }

    /// Creates a uniquely named file in its own folder and opens that folder in Finder.
    @MainActor
    private func fileInFinder() throws -> XCUIElement {
        closeTestFinderWindows()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeskDropDrag-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileName = "DeskDrop-UITest-\(UUID().uuidString.prefix(8)).txt"
        try Data("DeskDrop drag gesture test".utf8).write(to: folder.appendingPathComponent(fileName))
        self.folder = folder

        // Opening the folder leaves the file unselected; pressing on an already
        // selected name in Finder starts renaming instead of dragging.
        NSWorkspace.shared.open(folder)
        let item = finder.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@ OR title == %@", fileName, fileName, fileName))
            .firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Finder should show the test file")
        // Wait for the window to finish opening so the press lands on the file.
        var lastFrame = CGRect.null
        for _ in 0..<20 where item.frame != lastFrame {
            lastFrame = item.frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return item
    }

    /// Closes only Finder windows these tests opened (their titles are unique).
    @MainActor
    private func closeTestFinderWindows() {
        let ours = finder.windows.matching(NSPredicate(format: "title BEGINSWITH 'DeskDropDrag-' OR title == 'tmp'"))
        for _ in 0..<40 {
            let window = ours.firstMatch
            guard window.exists else { return }
            let close = window.buttons[XCUIIdentifierCloseWindow]
            guard close.exists, close.isHittable else { return }
            close.click()
        }
    }

    /// Screens in XCUI coordinates (top-left origin on the main display).
    private static var screenRects: [CGRect] {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { screen in
            let visible = screen.visibleFrame
            return CGRect(x: visible.minX, y: mainHeight - visible.maxY, width: visible.width, height: visible.height)
        }
    }

    /// Moves DeskDrop's main window, by its title area, onto a display area that
    /// doesn't overlap the Finder window, so both the file and the card are visible.
    @MainActor
    private func placeDeskDropBesideFinder(_ app: XCUIApplication) throws {
        let window = app.windows["DeskDrop"]
        guard let folder, window.exists else { return }
        let finderFrame = finder.windows[folder.lastPathComponent].frame
        guard window.frame.intersects(finderFrame) else { return }

        let size = window.frame.size
        var candidates: [CGPoint] = []
        for screen in Self.screenRects {
            candidates.append(CGPoint(x: screen.minX + 20, y: screen.minY + 20))
            candidates.append(CGPoint(x: screen.maxX - size.width - 20, y: screen.minY + 20))
            candidates.append(CGPoint(x: screen.minX + 20, y: screen.maxY - size.height - 20))
        }
        let fits = candidates.first { origin in
            let frame = CGRect(origin: origin, size: size)
            return !frame.intersects(finderFrame) && Self.screenRects.contains { $0.contains(frame) }
        }
        guard let origin = fits else {
            throw XCTSkip("Needs room for DeskDrop and Finder side by side (e.g. a second display)")
        }
        // The header's empty middle is draggable title-bar space.
        let grab = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: size.width * 0.45, dy: 12))
        let destination = grab.withOffset(CGVector(dx: origin.x - window.frame.minX, dy: origin.y - window.frame.minY))
        grab.click(forDuration: 0.2, thenDragTo: destination)
    }

    /// A point 1 pt inside the left edge of the leftmost display, vertically centred,
    /// in AppKit global coordinates (origin bottom-left of the main display).
    private static func outerLeftEdgePoint() -> CGPoint {
        let screen = NSScreen.screens.min { $0.frame.minX < $1.frame.minX }
        let frame = screen?.frame ?? .zero
        let visible = screen?.visibleFrame ?? .zero
        return CGPoint(x: frame.minX + 1, y: visible.midY)
    }

    /// XCUI coordinates are top-left based on the main display; AppKit's are bottom-left.
    private static func offset(from elementFrame: CGRect, toGlobal point: CGPoint) -> CGVector {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let target = CGPoint(x: point.x, y: mainHeight - point.y)
        return CGVector(dx: target.x - elementFrame.midX, dy: target.y - elementFrame.midY)
    }
}
