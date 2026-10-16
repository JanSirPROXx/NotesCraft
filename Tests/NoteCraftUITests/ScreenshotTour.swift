import XCTest

// Produces the App Store screenshots. It is only meant to be run by `scripts/screenshots.sh`,
// which boots a 13-inch iPad simulator, runs this test and exports the attachments. The debug app
// fills each new document with a sample page (`--screenshot-scenes`).
final class ScreenshotTour: XCTestCase {
  @MainActor func testTour() throws {
    // Slow, and it only produces files; scripts/screenshots.sh turns it on.
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["SCREENSHOT_TOUR"] != nil,
      "Run scripts/screenshots.sh to produce the App Store screenshots")
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-test-reset-input", "--screenshot-scenes=notes,circuit,graph,whiteboard",
    ]
    app.launch()
    chooseFreshStorageFolder(app, folderName: "Study")
    let documents: [(kind: String, untitled: String, name: String, shot: String)] = [
      ("Notebook", "Untitled Notebook", "Physics Notes", "1-notes"),
      ("Notebook", "Untitled Notebook", "Circuit Lab", "2-circuit"),
      ("Notebook", "Untitled Notebook", "Calculus", "3-graph"),
      ("Whiteboard", "Untitled Whiteboard", "Project Ideas", "4-whiteboard"),
    ]
    for document in documents {
      XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20), app.debugDescription)
      app.buttons["New"].tap()
      XCTAssertTrue(app.buttons[document.kind].waitForExistence(timeout: 10))
      app.buttons[document.kind].tap()
      XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 10))
      app.buttons["Create"].tap()
      let canvas = app.descendants(matching: .any)["drawingCanvas"].firstMatch
      XCTAssertTrue(canvas.waitForExistence(timeout: 15))
      app.buttons["Documents"].tap()
      XCTAssertTrue(app.buttons["Actions for \(document.untitled)"].waitForExistence(timeout: 10))
      app.buttons["Actions for \(document.untitled)"].tap()
      app.buttons["Rename"].tap()
      let field = app.textFields["renameField"]
      XCTAssertTrue(field.waitForExistence(timeout: 5))
      field.tap()
      field.typeText(
        String(repeating: XCUIKeyboardKey.delete.rawValue, count: document.untitled.count)
          + document.name)
      app.buttons["Rename"].tap()
      XCTAssertTrue(app.buttons[document.name].waitForExistence(timeout: 10))
      // Reopen under its real name so the tab shows it, then let the page render and the page
      // indicator fade before the screenshot.
      app.buttons[document.name].firstMatch.tap()
      XCTAssertTrue(canvas.waitForExistence(timeout: 15))
      Thread.sleep(forTimeInterval: 3)
      capture(document.shot)
      app.buttons["Documents"].tap()
    }
    Thread.sleep(forTimeInterval: 1.5)
    capture("5-library")
  }

  @MainActor private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
