import XCTest

final class CalculatorUITests: XCTestCase {
  // The first pick of the pen shows its tutorial; tests that want to write dismiss it.
  @MainActor private func chooseCalculator(_ app: XCUIApplication) {
    app.buttons["Calculator"].tap()
    let done = app.buttons["calculatorIntroDone"]
    if done.waitForExistence(timeout: 4) {
      done.tap()
      expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: done)
      waitForExpectations(timeout: 5)
    }
  }

  @MainActor private func openNotebook(_ app: XCUIApplication) -> XCUIElement {
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    let canvas = app.descendants(matching: .any)["drawingCanvas"].firstMatch
    XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    changeSetting(app, "Apple Pencil only")
    return canvas
  }

  // Writes "1 + 2 =" with the finger (Apple Pencil only is switched off first): three marks and the
  // two bars of the "=". A drag of a few points is no stroke, so the glyphs are written large.
  @MainActor private func writeCalculation(_ canvas: XCUIElement, row y: Double) {
    func point(_ x: Double, _ y: Double) -> XCUICoordinate {
      canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
    func drag(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
      point(x0, y0).press(forDuration: 0.05, thenDragTo: point(x1, y1))
    }
    drag(0.15, y - 0.03, 0.17, y + 0.03)
    drag(0.22, y, 0.30, y)
    drag(0.26, y - 0.04, 0.26, y + 0.04)
    drag(0.34, y - 0.03, 0.38, y + 0.03)
    drag(0.44, y - 0.01, 0.54, y - 0.01)
    drag(0.44, y + 0.01, 0.54, y + 0.01)
  }

  @MainActor func testEqualsWritesTheAnswerAndUndoTakesItAway() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-test-reset-input", "--ui-test-calculator-reading=12*3+4",
    ]
    app.launch()
    let canvas = openNotebook(app)
    XCTAssertTrue(app.buttons["Calculator"].waitForExistence(timeout: 5), "The tool is on the bar")
    chooseCalculator(app)
    writeCalculation(canvas, row: 0.2)
    let answered = NSPredicate(format: "value CONTAINS '1 calculations'")
    expectation(for: answered, evaluatedWith: canvas)
    waitForExpectations(timeout: 10) { _ in }
    XCTAssertEqual(canvas.value as? String, "6 strokes, 1 calculations")
    // The answer is part of the undo step of the "=": one undo takes both away.
    app.buttons["Undo"].tap()
    XCTAssertEqual(canvas.value as? String, "5 strokes")
  }

  @MainActor func testOrdinaryPenNeverStartsACalculation() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-test-reset-input", "--ui-test-calculator-reading=2+2",
    ]
    app.launch()
    let canvas = openNotebook(app)
    // The pen is the tool a notebook opens with (tapping it again would open its settings).
    writeCalculation(canvas, row: 0.2)
    Thread.sleep(forTimeInterval: 1.5)
    XCTAssertEqual(canvas.value as? String, "6 strokes")
  }

  @MainActor func testAnUnreadableCalculationCanBeTypedIn() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    // No recognizer is bundled yet, so the answer is a question mark.
    app.launchArguments = ["--ui-test-reset-input"]
    app.launch()
    let canvas = openNotebook(app)
    chooseCalculator(app)
    writeCalculation(canvas, row: 0.2)
    expectation(for: NSPredicate(format: "value CONTAINS '1 calculations'"), evaluatedWith: canvas)
    waitForExpectations(timeout: 10)
    // With Apple Pencil only on again, as it is by default, a finger only taps: on the question
    // mark, right of the "=", that opens the sheet.
    changeSetting(app, "Apple Pencil only")
    canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.61, dy: 0.2)).tap()
    let field = app.textFields["calculationField"]
    XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
    field.tap()
    field.typeText("12×3+4")
    XCTAssertEqual(app.staticTexts["calculationPreview"].label, "40")
    app.buttons["calculationApply"].tap()
    XCTAssertFalse(field.waitForExistence(timeout: 2))
    XCTAssertEqual(canvas.value as? String, "6 strokes, 1 calculations")
  }

  @MainActor func testTheTutorialShowsTheFirstTimeAndFromTheSettings() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input"]
    app.launch()
    _ = openNotebook(app)
    let intro = app.staticTexts["calculatorIntroTitle"]
    app.buttons["Calculator"].tap()
    XCTAssertTrue(intro.waitForExistence(timeout: 5), "The first pick shows the tutorial")
    Thread.sleep(forTimeInterval: 1.2)
    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    shot.name = "Calculator tutorial"
    shot.lifetime = .keepAlways
    add(shot)
    app.buttons["calculatorIntroDone"].tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: intro)
    waitForExpectations(timeout: 5)

    // Picking it again, even after another tool, does not show it again.
    app.buttons["Pen"].tap()
    app.buttons["Calculator"].tap()
    XCTAssertFalse(intro.waitForExistence(timeout: 2), "Only the first time")

    // The settings of the pen reopen it.
    app.buttons["Calculator"].tap()
    XCTAssertTrue(app.buttons["calculatorHowItWorks"].waitForExistence(timeout: 5))
    app.buttons["calculatorHowItWorks"].tap()
    XCTAssertTrue(intro.waitForExistence(timeout: 5))
  }
}
