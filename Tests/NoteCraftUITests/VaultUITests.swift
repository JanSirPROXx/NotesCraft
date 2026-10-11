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
    XCTAssertTrue(app.buttons["Grid · 5 mm"].exists)
    app.buttons["Grid · 5 mm"].tap()
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
    app.buttons["More"].tap()
    app.buttons["Paper background"].tap()
    XCTAssertTrue(app.buttons["Grid · 2.5 mm"].waitForExistence(timeout: 5))
    capture(app, name: "Paper background selection")
    app.buttons["Grid · 2.5 mm"].tap()
    app.buttons["Apply"].tap()
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
    let zoomSurface = app.scrollViews["notebookZoomSurface"].firstMatch
    XCTAssertTrue(zoomSurface.exists)
    zoomSurface.pinch(withScale: 3, velocity: 0.5)
    let zoomed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value != 'Zoom 100 percent'"), object: zoomSurface)
    XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
    XCTAssertEqual(canvas.value as? String, "1 strokes")
    XCTAssertGreaterThan(Int((zoomSurface.value as? String ?? "").filter(\.isNumber)) ?? 0, 100)
    capture(app, name: "Notebook pinch zoom")
    canvas.pinch(withScale: 0.4, velocity: -1)
    app.buttons["Image"].tap()
    XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Photo library"].exists)
    app.buttons["Cancel"].tap()
    app.buttons["Read only"].tap()
    let pageScroll = app.scrollViews["notebookScrollView"]
    XCTAssertTrue(pageScroll.exists)
    let right = pageScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.65))
    let left = pageScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.65))
    right.press(forDuration: 0.05, thenDragTo: left, withVelocity: .slow, thenHoldForDuration: 0.8)
    app.buttons["Pages"].tap()
    XCTAssertTrue(app.buttons["pageThumbnail-1"].waitForExistence(timeout: 5), app.debugDescription)
    capture(app, name: "Horizontal pull creates matching page")
    let thumbnail = app.buttons["pageThumbnail-0"]
    thumbnail.press(forDuration: 0.8)
    app.buttons["Duplicate page"].tap()
    XCTAssertTrue(app.buttons["pageThumbnail-2"].waitForExistence(timeout: 5))
    app.buttons["Pages"].tap()
    app.buttons["More"].tap()
    app.descendants(matching: .any)["Horizontal pages"].firstMatch.tap()
    app.buttons["Pages"].tap()
    app.buttons["pageThumbnail-2"].tap()
    app.buttons["Pages"].tap()
    let bottom = pageScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.9))
    let top = pageScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.05))
    bottom.press(forDuration: 0.05, thenDragTo: top)
    for _ in 0..<3 {
      if app.staticTexts["pageIndicator"].exists, app.staticTexts["pageIndicator"].label == "4 / 4"
      {
        break
      }
      bottom.press(
        forDuration: 0.05, thenDragTo: top, withVelocity: .slow, thenHoldForDuration: 0.8)
    }
    app.buttons["Pages"].tap()
    XCTAssertTrue(app.buttons["pageThumbnail-3"].waitForExistence(timeout: 5), app.debugDescription)
    capture(app, name: "Vertical setting retains pull-to-add-page")
    app.buttons["Pages"].tap()
    let hiddenIndicator = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["pageIndicator"])
    XCTAssertEqual(XCTWaiter.wait(for: [hiddenIndicator], timeout: 5), .completed)
    XCTAssertFalse(app.staticTexts["pageCount"].exists)
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
    pageNumber.typeText(XCUIKeyboardKey.delete.rawValue + "3")
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
    app.buttons["Documents"].tap()
    app.terminate()
    app.launchArguments = []
    app.launch()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 15), app.debugDescription)
    XCTAssertFalse(
      app.buttons["chooseStorageFolder"].exists, "The last storage must open automatically")
    XCTAssertTrue(app.buttons["addStorageFolder"].exists)
    app.buttons["Study Notes"].firstMatch.tap()
    XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 5))
    app.buttons["More"].tap()
    app.buttons["documentNavigatorMenu"].tap()
    XCTAssertTrue(pageNumber.waitForExistence(timeout: 5))
    XCTAssertEqual(pageNumber.value as? String, "3", "Resume the notebook after app relaunch")
    capture(app, name: "Last storage and notebook page restored after relaunch")
    app.buttons["Done"].tap()
    app.buttons["More"].tap()
    app.descendants(matching: .any)["Horizontal pages"].firstMatch.tap()
    let currentZoom = try visibleZoomSurface(app)
    currentZoom.pinch(withScale: 3, velocity: 0.5)
    let inheritedZoom = currentZoom.value as? String
    XCTAssertNotEqual(inheritedZoom, "Zoom 100 percent")
    app.buttons["newPageButton"].tap()
    app.buttons["confirmAddPage"].tap()
    let newZoom = try visibleZoomSurface(app)
    XCTAssertEqual(newZoom.value as? String, inheritedZoom)
    capture(app, name: "New page retains zoom at top left")
    app.buttons["More"].tap()
    app.descendants(matching: .any)["Keep zoom on new pages"].firstMatch.tap()
    app.buttons["newPageButton"].tap()
    app.buttons["confirmAddPage"].tap()
    let resetZoom = try visibleZoomSurface(app)
    XCTAssertEqual(resetZoom.value as? String, "Zoom 100 percent")
    app.buttons["Read only"].tap()
    pageScroll.swipeRight()
    app.buttons["More"].tap()
    app.buttons["documentNavigatorMenu"].tap()
    XCTAssertTrue(pageNumber.waitForExistence(timeout: 5))
    XCTAssertEqual(pageNumber.value as? String, "5", "A flick must settle on one adjacent page")
    app.buttons["Done"].tap()
    capture(app, name: "Magnetic paging settles on the previous page")

  }
  @MainActor private func chooseFreshStorageFolder(_ app: XCUIApplication) {
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
  }
  @MainActor func testInfiniteScrollingAddsABlankPageAfterWriting() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input"]
    app.launch()
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    let canvas = app.descendants(matching: .any)["drawingCanvas"].firstMatch
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    app.buttons["More"].tap()
    let infinite = app.descendants(matching: .any)["Infinite scrolling"].firstMatch
    XCTAssertTrue(infinite.waitForExistence(timeout: 5))
    infinite.tap()
    app.buttons["More"].tap()
    let pencilOnly = app.descendants(matching: .any)["Apple Pencil only"].firstMatch
    XCTAssertTrue(pencilOnly.waitForExistence(timeout: 5))
    pencilOnly.tap()
    app.buttons["Pages"].tap()
    XCTAssertTrue(app.buttons["pageThumbnail-0"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["pageThumbnail-1"].exists, "A blank last page needs no successor")
    canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.2)).press(
      forDuration: 0.05,
      thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3)))
    XCTAssertTrue(
      app.buttons["pageThumbnail-1"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertFalse(app.buttons["pageThumbnail-2"].exists, "Only one blank page is kept ahead")
    app.buttons["Documents"].tap()
  }
  @MainActor func testShapesStickersTextAndSelectionWorkflow() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input"]
    app.launch()
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    let canvas = app.descendants(matching: .any)["drawingCanvas"].firstMatch
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    app.buttons["More"].tap()
    let pencilOnly = app.descendants(matching: .any)["Apple Pencil only"].firstMatch
    XCTAssertTrue(pencilOnly.waitForExistence(timeout: 5))
    pencilOnly.tap()

    // Insert a rectangle by dragging, then stretch it by its right edge.
    app.buttons["Shapes"].tap()
    app.buttons["Shape: Freehand"].tap()
    XCTAssertTrue(app.buttons["Rectangle"].waitForExistence(timeout: 5))
    app.buttons["Rectangle"].tap()
    func point(_ x: Double, _ y: Double) -> XCUICoordinate {
      canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
    point(0.2, 0.2).press(forDuration: 0.05, thenDragTo: point(0.5, 0.3))
    XCTAssertEqual(canvas.value as? String, "1 strokes")
    capture(app, name: "Rectangle inserted and selected")
    point(0.5, 0.25).press(forDuration: 0.05, thenDragTo: point(0.8, 0.25))
    XCTAssertEqual(canvas.value as? String, "1 strokes", "Stretching edits the shape in place")
    capture(app, name: "Rectangle stretched")

    // A heart sticker lands where the page is tapped, ready to move.
    app.buttons["Elements"].tap()
    XCTAssertTrue(app.buttons["Heart"].waitForExistence(timeout: 5))
    app.buttons["Heart"].tap()
    point(0.3, 0.6).tap()
    XCTAssertEqual(canvas.value as? String, "2 strokes")
    capture(app, name: "Sticker inserted")

    // Text is typed straight onto the page.
    app.buttons["Text"].tap()
    point(0.5, 0.55).tap()
    let field = app.descendants(matching: .any)["inlineTextField"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
    field.typeText("Hello")
    capture(app, name: "Inline text editor")
    app.buttons["Done editing text"].tap()

    // Tapping with the lasso selects the rectangle, whose menu opens from the ellipsis.
    app.buttons["Lasso"].tap()
    point(0.2, 0.25).tap()
    XCTAssertTrue(app.buttons["Selection actions"].waitForExistence(timeout: 5))
    app.buttons["Selection actions"].tap()
    XCTAssertTrue(app.buttons["Bring to front"].waitForExistence(timeout: 5))
    capture(app, name: "Selection menu")
  }
  @MainActor func testLargeNotebookKeepsOnlyVisibleCanvasesLoaded() throws {
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-large-notebook"]
    app.launch()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    let surfaces = app.scrollViews.matching(identifier: "notebookZoomSurface")
    XCTAssertTrue(surfaces.firstMatch.waitForExistence(timeout: 20))
    XCTAssertLessThan(surfaces.count, 12, "A large notebook must not allocate one canvas per page")
    let options = XCTMeasureOptions()
    options.iterationCount = 1
    measure(metrics: [XCTMemoryMetric(application: app)], options: options) {
      app.buttons["More"].tap()
      app.buttons["documentNavigatorMenu"].tap()
      let field = app.textFields["pageNumberField"]
      XCTAssertTrue(field.waitForExistence(timeout: 5))
      field.tap()
      field.typeText(
        String(
          repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count)
          + "300")
      app.buttons["Go"].tap()
      XCTAssertTrue(surfaces.firstMatch.waitForExistence(timeout: 5))
      XCTAssertLessThan(surfaces.count, 12)
    }
    app.buttons["More"].tap()
    app.buttons["documentNavigatorMenu"].tap()
    XCTAssertEqual(app.textFields["pageNumberField"].value as? String, "300")
    app.buttons["Done"].tap()
    capture(app, name: "300-page notebook with bounded live canvases")
    app.buttons["Documents"].tap()
  }

  @MainActor private func visibleZoomSurface(_ app: XCUIApplication) throws -> XCUIElement {
    let surfaces = app.scrollViews.matching(identifier: "notebookZoomSurface")
    XCTAssertTrue(surfaces.firstMatch.waitForExistence(timeout: 5))
    let viewport = app.scrollViews["notebookScrollView"].frame
    func area(_ element: XCUIElement) -> CGFloat {
      let visible = element.frame.intersection(viewport)
      return visible.isNull ? 0 : visible.width * visible.height
    }
    return try XCTUnwrap(surfaces.allElementsBoundByIndex.max { area($0) < area($1) })
  }
  @MainActor private func capture(_ app: XCUIApplication, name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}
