import XCTest

// Writing on the trainer's pad must write, not scroll: the screen under the pen stays where it is.
final class TrainerUITests: XCTestCase {
  @MainActor private func openTrainer(_ app: XCUIApplication) {
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))
    app.buttons["New"].tap()
    app.buttons["Notebook"].tap()
    XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 5))
    app.buttons["Create"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas"].firstMatch.waitForExistence(timeout: 10))
    app.buttons["More"].tap()
    app.buttons["Settings"].tap()
    let link = app.descendants(matching: .any)["teachHandwriting"].firstMatch
    var swipes = 0
    while !link.exists && swipes < 5 {
      app.swipeUp()
      swipes += 1
    }
    XCTAssertTrue(link.waitForExistence(timeout: 5), "Settings has the trainer")
    link.tap()
    XCTAssertTrue(app.descendants(matching: .any)["trainerPrompt"].firstMatch.waitForExistence(timeout: 5))
  }

  @MainActor func testWritingOnThePadDoesNotMoveIt() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input"]
    app.launch()
    openTrainer(app)

    let pad = app.descendants(matching: .any)["trainerPad"].firstMatch
    XCTAssertTrue(pad.waitForExistence(timeout: 5))
    let before = pad.frame
    let prompt = app.descendants(matching: .any)["trainerPrompt"].firstMatch.frame

    func point(_ x: Double, _ y: Double) -> XCUICoordinate {
      pad.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
    // A tall stroke, a slow wavy one and a hooked one: what a "1", a "5" and a "7" ask of the pad.
    point(0.5, 0.15).press(forDuration: 0.05, thenDragTo: point(0.5, 0.9))
    point(0.3, 0.2).press(forDuration: 0.05, thenDragTo: point(0.7, 0.25))
    point(0.7, 0.25).press(forDuration: 0.05, thenDragTo: point(0.35, 0.85))
    XCTAssertEqual(
      app.descendants(matching: .any)["trainerPrompt"].firstMatch.frame.minY, prompt.minY, accuracy: 0.5,
      "The prompt scrolled under the pen")
    XCTAssertEqual(pad.frame.minY, before.minY, accuracy: 0.5, "The pad scrolled under the pen")
    XCTAssertEqual(pad.frame.minX, before.minX, accuracy: 0.5, "The pad moved sideways under the pen")
    XCTAssertTrue(app.buttons["trainerSave"].isEnabled, "The strokes were written")
  }

  // The pen reads with the pretrained model unless the reader chooses their own handwriting, and
  // the trainer says so.
  @MainActor func testTheTrainerSaysWhichRecognizerReads() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input"]
    app.launch()
    openTrainer(app)
    let use = app.buttons["trainerUsePersonal"]
    XCTAssertTrue(use.waitForExistence(timeout: 5), "The pretrained model reads by default")
    use.tap()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: use)
    waitForExpectations(timeout: 5)
  }
}
