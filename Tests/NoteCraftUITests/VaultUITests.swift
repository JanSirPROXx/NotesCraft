import XCTest

final class VaultUITests: XCTestCase {
  @MainActor func testFolderLibraryManagementDrawingAndPDFNavigation() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input"]
    app.launch()
    XCTAssertTrue(app.buttons["chooseStorageFolder"].waitForExistence(timeout: 10))
    app.buttons["chooseStorageFolder"].tap()
    let localStorage = app.cells["DOC.sidebar.item.On My iPad"]
    if !localStorage.waitForExistence(timeout: 15) {
      let browse = app.buttons["Browse"].firstMatch
      if browse.exists { browse.tap() }
    }
    XCTAssertTrue(localStorage.waitForExistence(timeout: 30), app.debugDescription)
    localStorage.tap()
    app.buttons["New Folder"].tap()
    let field = app.textViews["DOC.inlineRenameField"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    let folderName = "NoteCraft Test " + UUID().uuidString.prefix(8)
    field.typeText(
      String(
        repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count)
        + folderName + "\n")
    let hideKeyboard = app.keyboards.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] 'hide' OR label CONTAINS[c] 'dismiss'")
    ).firstMatch
    if hideKeyboard.exists { hideKeyboard.tap() }
    let open = app.buttons["Open"]
    let tappable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: open)
    XCTAssertEqual(XCTWaiter.wait(for: [tappable], timeout: 20), .completed, app.debugDescription)
    open.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20), app.debugDescription)
    app.buttons["New"].tap()
    XCTAssertTrue(app.buttons["Notebook"].waitForExistence(timeout: 10))
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Create"].isEnabled)
    app.buttons["Create"].tap()
    XCUIDevice.shared.orientation = .landscapeLeft
    let canvas = app.descendants(matching: .any)["drawingCanvas"].firstMatch
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    XCTAssertEqual(canvas.value as? String, "0 strokes")
    canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).press(
      forDuration: 0.05,
      thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35)))
    XCTAssertEqual(canvas.value as? String, "0 strokes", "Finger input must navigate by default")
    app.buttons["More"].tap()
    let pencilOnly = app.descendants(matching: .any)["Apple Pencil only"].firstMatch
    XCTAssertTrue(pencilOnly.waitForExistence(timeout: 5))
    pencilOnly.tap()
    canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).press(
      forDuration: 0.05,
      thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35)))
    XCTAssertEqual(canvas.value as? String, "1 strokes")
    capture(app, name: "Notebook after finger drawing")
    app.buttons["Documents"].tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 10))
    app.buttons["Untitled Notebook"].firstMatch.tap()
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    XCTAssertEqual(canvas.value as? String, "1 strokes")
    app.buttons["Eraser"].tap()
    canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25)).press(
      forDuration: 0.05,
      thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.35)))
    XCTAssertEqual(canvas.value as? String, "0 strokes")
    app.buttons["Undo"].tap()
    XCTAssertEqual(canvas.value as? String, "1 strokes")
    app.buttons["Read only"].tap()
    let pageCount = app.staticTexts["pageCount"]
    XCTAssertEqual(pageCount.label, "1 page")
    let pageScroll = app.scrollViews["notebookScrollView"]
    XCTAssertTrue(pageScroll.exists)
    let bottom = pageScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.9))
    let top = pageScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.05))
    bottom.press(forDuration: 0.05, thenDragTo: top)
    bottom.press(forDuration: 0.05, thenDragTo: top, withVelocity: .slow, thenHoldForDuration: 0.8)
    let addedPage = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == '2 pages'"), object: pageCount)
    XCTAssertEqual(XCTWaiter.wait(for: [addedPage], timeout: 5), .completed, app.debugDescription)
    capture(app, name: "Continued page after pulling past the end")
    app.buttons["Pages"].tap()
    let thumbnail = app.buttons["pageThumbnail-0"]
    XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
    thumbnail.press(forDuration: 0.8)
    app.buttons["Duplicate page"].tap()
    XCTAssertEqual(pageCount.label, "3 pages")
    app.buttons["Pages"].tap()
    app.buttons["More"].tap()
    app.descendants(matching: .any)["Horizontal pages"].firstMatch.tap()
    let currentPage = app.buttons.matching(
      NSPredicate(format: "label MATCHES %@", "[0-9]+ / [0-9]+")
    ).firstMatch
    XCTAssertEqual(currentPage.label, "2 / 3")
    pageScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.4)).press(
      forDuration: 0.05,
      thenDragTo: pageScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4)),
      withVelocity: .slow, thenHoldForDuration: 0)
    let snappedPage = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == '3 / 3'"), object: currentPage)
    XCTAssertEqual(XCTWaiter.wait(for: [snappedPage], timeout: 5), .completed, app.debugDescription)
    capture(app, name: "Horizontal pages after snapping")
    app.buttons["Documents"].tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 10))
    capture(app, name: "Documents library")
    app.buttons["Actions for Untitled Notebook"].tap()
    app.buttons["Rename"].tap()
    let renameField = app.textFields["renameField"]
    XCTAssertTrue(renameField.waitForExistence(timeout: 5))
    renameField.tap()
    renameField.typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Untitled Notebook".count)
        + "Study Notes")
    app.buttons["Rename"].tap()
    XCTAssertTrue(app.buttons["Study Notes"].waitForExistence(timeout: 5))
    app.buttons["Actions for Study Notes"].tap()
    app.buttons["Duplicate"].tap()
    XCTAssertTrue(app.buttons["Study Notes copy"].waitForExistence(timeout: 5))
    app.buttons["Actions for Study Notes copy"].tap()
    app.buttons["Move to Trash"].tap()
    app.buttons["Library locations"].tap()
    app.buttons["showTrash"].tap()
    XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5))
    capture(app, name: "Recoverable library trash")
    app.buttons["Restore"].tap()
    XCTAssertTrue(app.staticTexts["Trash is empty"].waitForExistence(timeout: 5))
    app.buttons["Library locations"].tap()
    app.buttons["showDocuments"].tap()
    XCTAssertTrue(app.buttons["Study Notes copy"].waitForExistence(timeout: 5))
    capture(app, name: "Library after rename duplicate and restore")
    app.buttons["Study Notes"].firstMatch.tap()
    XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
    app.buttons["More"].tap()
    app.buttons["documentNavigatorMenu"].tap()
    let pageNumber = app.textFields["pageNumberField"]
    XCTAssertTrue(pageNumber.waitForExistence(timeout: 5))
    pageNumber.tap()
    pageNumber.typeText(XCUIKeyboardKey.delete.rawValue + "1")
    app.buttons["Go"].tap()
    XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
    app.buttons["Documents"].tap()
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
