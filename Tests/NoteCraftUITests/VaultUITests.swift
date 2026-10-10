import XCTest

final class VaultUITests: XCTestCase {
  @MainActor func testFolderPickerAndDrawing() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["chooseStorageFolder"].waitForExistence(timeout: 10))
    app.buttons["chooseStorageFolder"].tap()
    XCTAssertTrue(app.buttons["Open"].waitForExistence(timeout: 15))
    app.cells["DOC.sidebar.item.On My iPad"].tap()
    app.buttons["New Folder"].tap()
    let field = app.textViews["DOC.inlineRenameField"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    let folderName = "NoteCraft Test " + UUID().uuidString.prefix(8)
    field.typeText(
      String(
        repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count)
        + folderName + "\n")
    app.buttons["Open"].tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 10))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Create"].isEnabled)
    app.buttons["Create"].tap()
    let canvas = app.descendants(matching: .any)["drawingCanvas"].firstMatch
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    XCTAssertEqual(canvas.value as? String, "0 strokes")
    canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).press(
      forDuration: 0.05,
      thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35)))
    XCTAssertTrue(NSPredicate(format: "value == %@", "1 strokes").evaluate(with: canvas))
    capture(app, name: "Notebook after finger drawing")
    app.buttons["Documents"].tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 10))
    app.buttons["Untitled Notebook"].firstMatch.tap()
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    XCTAssertEqual(canvas.value as? String, "1 strokes")
    app.buttons["Documents"].tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 10))
    capture(app, name: "Documents library")
    app.buttons["New"].tap()
    XCTAssertTrue(app.buttons["Whiteboard"].waitForExistence(timeout: 10))
    capture(app, name: "New document menu")
    app.buttons["Whiteboard"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Create"].isEnabled)
    app.buttons["Create"].tap()
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    XCTAssertEqual(canvas.value as? String, "0 strokes")
    canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).press(
      forDuration: 0.05,
      thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)))
    XCTAssertEqual(canvas.value as? String, "1 strokes")
    canvas.pinch(withScale: 1.4, velocity: 1)
    XCTAssertEqual(canvas.value as? String, "1 strokes")
    capture(app, name: "Whiteboard after drawing and pinch zoom")

  }
  @MainActor private func capture(_ app: XCUIApplication, name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
