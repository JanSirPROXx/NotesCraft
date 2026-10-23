import XCTest

final class VaultUITests: XCTestCase {
  @MainActor func testFolderLibraryManagementDrawingAndPDFNavigation() throws {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    defer { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input", "--ui-test-horizontal-pages"]
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
    // The return key already ends editing; tapping the keyboard's hide button raced with it
    // closing. Waiting for Open to become hittable below covers a keyboard that stays up.
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
    let zoomSurface = app.scrollViews["notebookScrollView"]
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
    // One query for identifier and label: the indicator fades out after 1.5 s, so checking
    // `exists` and then reading `label` separately can lose it in between.
    let onLastPage = app.staticTexts.matching(
      NSPredicate(format: "identifier == 'pageIndicator' AND label == '4 / 4'")
    ).firstMatch
    for _ in 0..<3 {
      if onLastPage.exists { break }
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
    // The whole document zooms, so a new page is at the zoom the paper already has.
    let afterNewPage = try visibleZoomSurface(app)
    XCTAssertEqual(afterNewPage.value as? String, inheritedZoom)
    capture(app, name: "New page at the zoom of the document")
    app.buttons["newPageButton"].tap()
    app.buttons["confirmAddPage"].tap()
    // Zooming out to fit makes the pages step one at a time again.
    let surface = try visibleZoomSurface(app)
    zoomToFit(surface)
    XCTAssertTrue(waitForZoom(surface, "Zoom 100 percent"), surface.value as? String ?? "no zoom")
    app.buttons["Read only"].tap()
    // XCUITest's synthetic fast swipe is not picked up by the paging scroll view at this point
    // of the flow (a slow drag is, as earlier in this test), so drag the page over by hand.
    Thread.sleep(forTimeInterval: 1.5)
    pageScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65)).press(
      forDuration: 0.05,
      thenDragTo: pageScroll.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.65)),
      withVelocity: .slow, thenHoldForDuration: 0.5)
    Thread.sleep(forTimeInterval: 1.0)
    app.buttons["More"].tap()
    app.buttons["documentNavigatorMenu"].tap()
    XCTAssertTrue(pageNumber.waitForExistence(timeout: 5))
    XCTAssertEqual(pageNumber.value as? String, "5", "A drag must settle on one adjacent page")
    app.buttons["Done"].tap()
    capture(app, name: "Magnetic paging settles on the previous page")

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
  @MainActor func testPageCreatedBySwipingCanBeZoomedImmediately() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input", "--ui-test-horizontal-pages"]
    app.launch()
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas"].firstMatch.waitForExistence(timeout: 10))
    let pageScroll = app.scrollViews["notebookScrollView"]
    XCTAssertTrue(pageScroll.exists)
    pageScroll.swipeLeft()
    app.buttons["Pages"].tap()
    XCTAssertTrue(app.buttons["pageThumbnail-1"].waitForExistence(timeout: 5), "Swiping adds a page")
    app.buttons["Pages"].tap()
    // Wait for the swipe to settle on the new page, then pinch it.
    Thread.sleep(forTimeInterval: 1)
    let surface = try visibleZoomSurface(app)
    surface.pinch(withScale: 3, velocity: 0.5)
    XCTAssertGreaterThan(
      Int((surface.value as? String ?? "").filter(\.isNumber)) ?? 0, 100,
      "The page created by swiping must zoom like any other")
    capture(app, name: "Swipe-created page zoomed")
    // A second swipe back must still work after zooming (the paging pan is restored).
    surface.pinch(withScale: 0.3, velocity: -1)
    pageScroll.swipeRight()
    app.buttons["More"].tap()
    app.buttons["documentNavigatorMenu"].tap()
    let pageNumber = app.descendants(matching: .any)["pageNumberField"].firstMatch
    _ = pageNumber.waitForExistence(timeout: 3)
    app.buttons["Done"].tap()
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
  @MainActor func testHoldingThePenOnARingSelectsWhatItEnclosesAndGoesBackToThePen() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input", "--ui-test-ring-notebook"]
    app.launch()
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    let canvas = app.descendants(matching: .any)["drawingCanvas"].firstMatch
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    XCTAssertEqual(canvas.value as? String, "3 strokes")
    // The simulator only has fingers: let one ink, like a Pencil would.
    app.buttons["More"].tap()
    let pencilOnly = app.descendants(matching: .any)["Apple Pencil only"].firstMatch
    XCTAssertTrue(pencilOnly.waitForExistence(timeout: 5))
    pencilOnly.tap()
    func point(_ x: Double, _ y: Double) -> XCUICoordinate {
      canvas.coordinate(withNormalizedOffset: CGVector(dx: x / 595, dy: y / 842))
    }
    // Held still on the top of the ring (page point 300, 220): the ring becomes a selection.
    point(300, 220).press(forDuration: 1.2)
    XCTAssertTrue(app.buttons["Selection actions"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(canvas.value as? String, "2 strokes", "The ring leaves the page, the word stays")

    // Tapping beside the selection dismisses it, and the pen is back: a drag draws ink again.
    point(120, 600).tap()
    XCTAssertTrue(app.buttons["Selection actions"].waitForNonExistence(timeout: 5))
    point(100, 650).press(forDuration: 0.05, thenDragTo: point(300, 700))
    XCTAssertEqual(canvas.value as? String, "3 strokes")
  }
  // A page that is zoomed in is drawn again at the density it is seen at, tile by tile, so a thin
  // line stays a thin line instead of a magnified blur. The screenshots are for looking at.
  @MainActor func testZoomedInPageIsDrawnSharpInTiles() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input", "--ui-test-ring-notebook"]
    app.launch()
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    let surface = try visibleZoomSurface(app)
    XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas"].firstMatch.waitForExistence(timeout: 10))
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    capture(app, name: "Tiles at fit zoom")
    for _ in 0..<3 where Int((surface.value as? String ?? "").filter(\.isNumber)) ?? 0 < 500 {
      surface.pinch(withScale: 3, velocity: 2)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    capture(app, name: "Tiles zoomed in")
    surface.swipeDown(velocity: .slow)
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    capture(app, name: "Tiles after panning")
    // Ink written at this zoom is drawn by the GPU at the density the page is seen at, and
    // joins the tiles when the pen lifts.
    XCTAssertEqual(visiblePageStrokes(app), "3 strokes")
    // The simulator only has fingers: let one ink, like a Pencil would.
    app.buttons["More"].tap()
    let pencilOnly = app.descendants(matching: .any)["Apple Pencil only"].firstMatch
    XCTAssertTrue(pencilOnly.waitForExistence(timeout: 5))
    pencilOnly.tap()
    let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.25))
    // A slow drag, with a screenshot taken while the stroke is still being written.
    let live = LiveShot()
    DispatchQueue.global().asyncAfter(deadline: .now() + 2.2) {
      live.image = XCUIScreen.main.screenshot()
    }
    start.press(
      forDuration: 0.05,
      thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.35)),
      withVelocity: .slow, thenHoldForDuration: 0.1)
    if let image = live.image {
      let attachment = XCTAttachment(screenshot: image)
      attachment.name = "Tiles with a stroke being written while zoomed in"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    XCTAssertTrue(waitForVisiblePage(app, "4 strokes"), "The stroke is part of the page")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    capture(app, name: "Tiles with a stroke written while zoomed in")
    // Erasing and undoing change the tiles in place.
    app.buttons["Eraser"].tap()
    surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18)).press(
      forDuration: 0.05,
      thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    capture(app, name: "Tiles after erasing across the stroke")
    app.buttons["Undo"].tap()
    XCTAssertTrue(waitForVisiblePage(app, "4 strokes"), "Undo brings the stroke back")
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    capture(app, name: "Tiles after undoing the erase")
    // The precision eraser cuts a piece out of the ring: only the tiles it reaches are patched.
    app.buttons["Precision"].tap()
    surface.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.82)).press(
      forDuration: 0.05,
      thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.84)))
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    capture(app, name: "Tiles after cutting the ring with the precision eraser")
    surface.pinch(withScale: 0.3, velocity: -2)
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    capture(app, name: "Tiles zoomed out again")
  }
  @MainActor func testPencilStyleInksThroughTheLivePath() throws {
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
    // The pen's quick bar lists the pen styles; the pencil is one of them.
    XCTAssertTrue(app.buttons["Pencil"].waitForExistence(timeout: 5), app.debugDescription)
    app.buttons["Pencil"].tap()
    func point(_ x: Double, _ y: Double) -> XCUICoordinate {
      canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
    point(0.2, 0.3).press(forDuration: 0.05, thenDragTo: point(0.7, 0.35))
    XCTAssertEqual(canvas.value as? String, "1 strokes")
    capture(app, name: "Pencil stroke")
    point(0.2, 0.4).press(forDuration: 0.05, thenDragTo: point(0.7, 0.45))
    XCTAssertEqual(canvas.value as? String, "2 strokes")
  }
  @MainActor func testATextBoxCanBeMovedAfterItIsInserted() throws {
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
    // Page points, so the positions do not depend on how the page is scaled on screen.
    func point(_ x: Double, _ y: Double) -> XCUICoordinate {
      canvas.coordinate(withNormalizedOffset: CGVector(dx: x / 595, dy: y / 842))
    }
    // Type a box at (120, 200) and finish: it stays selected.
    app.buttons["Text"].tap()
    point(120, 200).tap()
    let field = app.descendants(matching: .any)["inlineTextField"].firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
    field.typeText("Hello")
    app.buttons["Done editing text"].tap()
    XCTAssertTrue(app.buttons["Selection actions"].waitForExistence(timeout: 5), "the box stays selected")

    // Drag the selected box 100 pt right and 200 pt down. Tapping where it now is edits it; had it
    // not moved, that spot would be empty paper.
    func editsBoxAt(_ x: Double, _ y: Double, _ label: String) {
      point(x, y).tap()
      XCTAssertTrue(field.waitForExistence(timeout: 5), "\(label): no text box at \(x), \(y)")
      XCTAssertEqual(field.value as? String, "Hello", label)
      app.buttons["Done editing text"].tap()
      XCTAssertTrue(app.buttons["Selection actions"].waitForExistence(timeout: 5))
    }
    point(200, 214).press(forDuration: 0.05, thenDragTo: point(300, 414))
    editsBoxAt(300, 414, "moved while selected")

    // Let go of it with a tap on empty paper, then take hold of it again without selecting first.
    point(500, 700).tap()
    XCTAssertTrue(app.buttons["Selection actions"].waitForNonExistence(timeout: 5))
    point(300, 414).press(forDuration: 0.05, thenDragTo: point(200, 314))
    editsBoxAt(200, 314, "moved without selecting first")
  }
  // Measures what a notebook of handwriting costs to scroll, zoom and pan while zoomed: CPU time and
  // peak memory for the same gestures. It asserts nothing; the numbers are for comparing a change
  // with the one before (the simulator records no hitch metric).
  @MainActor func testScrollingAndZoomingHitchMeasurement() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input", "--ui-test-dense-notebook"]
    app.launch()
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    let scroll = app.scrollViews["notebookScrollView"]
    XCTAssertTrue(scroll.waitForExistence(timeout: 20))
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    func gestures() {
      for _ in 0..<4 { scroll.swipeUp(velocity: .fast) }
      for _ in 0..<4 { scroll.swipeDown(velocity: .fast) }
      scroll.pinch(withScale: 3, velocity: 1.5)
      for _ in 0..<3 { scroll.swipeLeft(velocity: .fast) }
      for _ in 0..<3 { scroll.swipeRight(velocity: .fast) }
      for _ in 0..<3 { scroll.swipeUp(velocity: .fast) }
      scroll.pinch(withScale: 0.3, velocity: -2)
    }
    let options = XCTMeasureOptions()
    options.iterationCount = 3
    measure(
      metrics: [XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
      options: options, block: gestures)
  }
  // The page that fills most of the notebook view, told apart by how many strokes it holds.
  @MainActor private func visiblePageStrokes(_ app: XCUIApplication) -> String? {
    let viewport = app.scrollViews["notebookScrollView"].frame
    let canvases = app.descendants(matching: .any).matching(identifier: "drawingCanvas")
      .allElementsBoundByIndex
    func area(_ element: XCUIElement) -> CGFloat {
      let visible = element.frame.intersection(viewport)
      return visible.isNull ? 0 : visible.width * visible.height
    }
    return canvases.max { area($0) < area($1) }?.value as? String
  }
  @MainActor private func waitForVisiblePage(
    _ app: XCUIApplication, _ expected: String, timeout: TimeInterval = 6
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if visiblePageStrokes(app) == expected { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return false
  }
  @MainActor func testClosingThePageSidebarKeepsThePageThatWasChosen() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-test-reset-input", "--ui-test-numbered-notebook", "--ui-test-horizontal-pages",
    ]
    app.launch()
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    XCTAssertTrue(app.scrollViews["notebookScrollView"].waitForExistence(timeout: 10))
    XCTAssertTrue(waitForVisiblePage(app, "1 strokes"), visiblePageStrokes(app) ?? "no page")

    // Choose a page from the sidebar, close the sidebar, open it again: the chosen page has to stay
    // the current one all along, not just stay on screen.
    func choose(_ index: Int, _ label: String) {
      app.buttons["Pages"].tap()
      let thumbnail = app.buttons["pageThumbnail-\(index)"]
      XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
      var swipes = 0
      while !thumbnail.isHittable && swipes < 8 {
        app.scrollViews["pageSidebar"].swipeUp()
        swipes += 1
      }
      thumbnail.tap()
      XCTAssertTrue(waitForVisiblePage(app, "\(index + 1) strokes"), "\(label): \(visiblePageStrokes(app) ?? "no page")")
      XCTAssertTrue(app.buttons["pageThumbnail-\(index)"].isSelected, "\(label): chosen")
      app.buttons["Pages"].tap()
      RunLoop.current.run(until: Date().addingTimeInterval(2))
      XCTAssertEqual(visiblePageStrokes(app), "\(index + 1) strokes", "\(label): after closing")
      app.buttons["Pages"].tap()
      XCTAssertTrue(app.buttons["pageThumbnail-\(index)"].waitForExistence(timeout: 5))
      RunLoop.current.run(until: Date().addingTimeInterval(1))
      XCTAssertTrue(
        app.buttons["pageThumbnail-\(index)"].isSelected, "\(label): the sidebar jumped to another page")
      XCTAssertEqual(visiblePageStrokes(app), "\(index + 1) strokes", "\(label): after reopening")
      app.buttons["Pages"].tap()
      RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
    choose(2, "horizontal, page 3")
    choose(7, "horizontal, page 8")

    // The same in the vertical layout.
    app.buttons["More"].tap()
    let horizontal = app.descendants(matching: .any)["Horizontal pages"].firstMatch
    XCTAssertTrue(horizontal.waitForExistence(timeout: 5))
    horizontal.tap()
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))
    choose(4, "vertical, page 5")
    choose(9, "vertical, page 10")
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
    let surfaces = app.descendants(matching: .any).matching(identifier: "drawingCanvas")
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

  // The one scroll view that holds all the pages and zooms them together.
  @MainActor private func visibleZoomSurface(_ app: XCUIApplication) throws -> XCUIElement {
    let surface = app.scrollViews["notebookScrollView"]
    XCTAssertTrue(surface.waitForExistence(timeout: 5))
    return surface
  }
  // A synthetic pinch does not always reach the scale it was given, so it is repeated.
  @MainActor private func zoomToFit(_ surface: XCUIElement) {
    for _ in 0..<4 {
      if waitForZoom(surface, "Zoom 100 percent", timeout: 1) { return }
      surface.pinch(withScale: 0.3, velocity: -2)
    }
  }
  @MainActor private func waitForZoom(
    _ surface: XCUIElement, _ expected: String, timeout: TimeInterval = 6
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if surface.value as? String == expected { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return false
  }
  @MainActor private func capture(_ app: XCUIApplication, name: String) {
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}

// A screenshot taken from another thread while a gesture is running.
private final class LiveShot: @unchecked Sendable {
  var image: XCUIScreenshot?
}
