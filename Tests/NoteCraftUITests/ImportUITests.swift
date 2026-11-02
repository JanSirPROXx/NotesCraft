import XCTest

final class ImportUITests: XCTestCase {
  // "Import PDF" in the ⋯ menu of a notebook used to do nothing: the picker was dropped.
  @MainActor func testImportPDFFromTheMenuOpensTheFilePicker() throws {
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
    app.buttons["More"].tap()
    XCTAssertTrue(app.buttons["Import PDF"].waitForExistence(timeout: 5))
    app.buttons["Import PDF"].tap()
    let picker = app.cells["DOC.sidebar.item.On My iPad"]
    XCTAssertTrue(
      picker.waitForExistence(timeout: 30) || app.buttons["Browse"].firstMatch.exists,
      "The system file picker opens")
    app.buttons["Cancel"].firstMatch.tap()
    XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas"].firstMatch.waitForExistence(timeout: 10))
  }
}
