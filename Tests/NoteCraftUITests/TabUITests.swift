import XCTest

final class TabUITests: XCTestCase {
  // An open document has a cross on its tab; closing the last one goes back to the library.
  @MainActor func testAnOpenDocumentCanBeClosedFromItsTab() throws {
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
    XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas"].firstMatch.waitForExistence(timeout: 10))
    let close = app.buttons["closeTab"]
    XCTAssertTrue(close.waitForExistence(timeout: 5), "The tab has a cross")
    close.tap()
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 10), "The library is back")
    XCTAssertFalse(app.buttons["closeTab"].exists)
    XCTAssertFalse(app.descendants(matching: .any)["drawingCanvas"].firstMatch.exists)
  }
}
