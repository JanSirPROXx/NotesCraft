import XCTest

final class TapeUITests: XCTestCase {
  @MainActor private func openNotebook(_ app: XCUIApplication) -> XCUIElement {
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    let canvas = app.descendants(matching: .any)["drawingCanvas"].firstMatch
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    // The finger draws in these tests.
    changeSetting(app, "Apple Pencil only")
    return canvas
  }

  @MainActor private func drag(
    _ canvas: XCUIElement, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double
  ) {
    canvas.coordinate(withNormalizedOffset: CGVector(dx: x0, dy: y0)).press(
      forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: x1, dy: y1)))
  }

  @MainActor private func expect(_ canvas: XCUIElement, says value: String, _ message: String) {
    let predicate = NSPredicate(format: "value == %@", value)
    expectation(for: predicate, evaluatedWith: canvas)
    waitForExpectations(timeout: 5) { _ in }
    XCTAssertEqual(canvas.value as? String, value, message)
  }

  // A line is written, covered with a strip, looked at and covered again; the eraser then takes
  // the strip and leaves the line it hid.
  @MainActor func testAStripCoversIsPeeledBackAndErasedWithoutTheInkUnderIt() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input"]
    app.launch()
    let canvas = openNotebook(app)
    drag(canvas, 0.25, 0.2, 0.45, 0.2)
    expect(canvas, says: "1 strokes", "a line to hide")

    XCTAssertTrue(app.buttons["Tape"].waitForExistence(timeout: 5), "The tool is on the bar")
    app.buttons["Tape"].tap()
    drag(canvas, 0.2, 0.2, 0.5, 0.2)
    expect(canvas, says: "1 strokes, 1 tapes, 1 covered", "a drag lays a strip")
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "Tape over a line"
    shot.lifetime = .keepAlways
    add(shot)

    let onTheStrip = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.2))
    onTheStrip.tap()
    expect(canvas, says: "1 strokes, 1 tapes, 0 covered", "a tap peels it back")
    // Once the fade is over: the line shows through the strip.
    Thread.sleep(forTimeInterval: 0.6)
    let peeled = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    peeled.name = "Tape peeled back"
    peeled.lifetime = .keepAlways
    add(peeled)
    onTheStrip.tap()
    expect(canvas, says: "1 strokes, 1 tapes, 1 covered", "and another covers it again")

    // The eye in the bar does the same for every strip on the page.
    app.buttons["toggleAllTape"].tap()
    expect(canvas, says: "1 strokes, 1 tapes, 0 covered", "reveal all")
    app.buttons["toggleAllTape"].tap()
    expect(canvas, says: "1 strokes, 1 tapes, 1 covered", "cover all")

    // With Apple Pencil only on, as it is by default, a finger lays no tape but still peels it.
    changeSetting(app, "Apple Pencil only")
    onTheStrip.tap()
    expect(canvas, says: "1 strokes, 1 tapes, 0 covered", "a finger tap peels with Pencil only on")
    onTheStrip.tap()
    expect(canvas, says: "1 strokes, 1 tapes, 1 covered", "and covers again, once per tap")
    drag(canvas, 0.2, 0.5, 0.5, 0.5)
    expect(canvas, says: "1 strokes, 1 tapes, 1 covered", "a finger drag scrolls, it lays no strip")
    changeSetting(app, "Apple Pencil only")

    // Reading is when tape is used: it peels in read-only mode too.
    app.buttons["Read only"].tap()
    onTheStrip.tap()
    expect(canvas, says: "1 strokes, 1 tapes, 0 covered", "a tap while reading peels it")
    onTheStrip.tap()
    expect(canvas, says: "1 strokes, 1 tapes, 1 covered", "and covers it")

    // One swipe of the eraser across the strip: the strip goes, the line that could not be seen
    // stays. A second swipe erases the line.
    app.buttons["Eraser"].tap()
    drag(canvas, 0.35, 0.12, 0.35, 0.28)
    expect(canvas, says: "1 strokes", "the eraser takes the strip only")
    app.buttons["Undo"].tap()
    expect(canvas, says: "1 strokes, 1 tapes, 1 covered", "undo brings the strip back")
    app.buttons["Redo"].tap()
    drag(canvas, 0.35, 0.12, 0.35, 0.28)
    expect(canvas, says: "0 strokes", "now the line can be seen and erased")
  }

  @MainActor func testTheTapeSettingsChangeThePatternAndRemoveAllTape() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input"]
    app.launch()
    let canvas = openNotebook(app)
    app.buttons["Tape"].tap()
    app.buttons["tapePatternButton"].tap()
    XCTAssertTrue(app.buttons["tapePattern-dots"].waitForExistence(timeout: 5))
    app.buttons["tapePattern-dots"].tap()
    XCTAssertTrue(app.buttons["tapePattern-dots"].waitForNonExistence(timeout: 5), "picking closes the palette")
    XCTAssertEqual(app.buttons["tapePatternButton"].label, "Tape pattern: Dots")
    drag(canvas, 0.2, 0.2, 0.5, 0.2)
    drag(canvas, 0.2, 0.3, 0.5, 0.36)
    expect(canvas, says: "0 strokes, 2 tapes, 2 covered", "two strips")
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "Dotted tape"
    shot.lifetime = .keepAlways
    add(shot)

    // The tool tapped again opens its settings.
    app.buttons["Tape"].tap()
    let remove = app.buttons["Remove all tape on this page"]
    XCTAssertTrue(remove.waitForExistence(timeout: 5))
    remove.tap()
    expect(canvas, says: "0 strokes", "all tape is gone")
    app.buttons["Undo"].tap()
    expect(canvas, says: "0 strokes, 2 tapes, 2 covered", "in one step that can be undone")
  }
}
