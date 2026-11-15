import XCTest

// A new page goes where the reader is, so a blank sheet can be put between two pages of a PDF; the
// sheet can still send it to the end.
final class PageInsertUITests: XCTestCase {
  @MainActor func testANewPageLandsAfterThePageBeingRead() throws {
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

    func addPage(_ position: String? = nil) {
      app.buttons["newPageButton"].tap()
      XCTAssertTrue(app.buttons["confirmAddPage"].waitForExistence(timeout: 5))
      if let position { app.buttons[position].tap() }
      app.buttons["confirmAddPage"].tap()
      XCTAssertFalse(app.buttons["confirmAddPage"].waitForExistence(timeout: 2))
    }
    func selectedThumbnail() -> Int? {
      app.buttons["Pages"].tap()
      defer { app.buttons["Pages"].tap() }
      XCTAssertTrue(app.buttons["pageThumbnail-0"].waitForExistence(timeout: 5))
      return (0..<8).first { app.buttons["pageThumbnail-\($0)"].exists && app.buttons["pageThumbnail-\($0)"].isSelected }
    }
    func pageCount() -> Int {
      app.buttons["Pages"].tap()
      defer { app.buttons["Pages"].tap() }
      XCTAssertTrue(app.buttons["pageThumbnail-0"].waitForExistence(timeout: 5))
      return (0..<8).filter { app.buttons["pageThumbnail-\($0)"].exists }.count
    }

    // Two pages, then back to the first: a page added now is the second of three, not the last.
    addPage()
    addPage()
    XCTAssertEqual(pageCount(), 3)
    app.buttons["Pages"].tap()
    app.buttons["pageThumbnail-0"].tap()
    app.buttons["Pages"].tap()
    addPage()
    XCTAssertEqual(pageCount(), 4)
    XCTAssertEqual(selectedThumbnail(), 1, "The new page sits after the first one, and is the one being read")

    // The sheet can send it to the end instead.
    app.buttons["Pages"].tap()
    app.buttons["pageThumbnail-0"].tap()
    app.buttons["Pages"].tap()
    addPage("At the end")
    XCTAssertEqual(pageCount(), 5)
    XCTAssertEqual(selectedThumbnail(), 4)
  }
}
