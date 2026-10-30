import XCTest

extension XCTestCase {
  // The control of a switch sits at the trailing end of its row; the middle of the row is its label.
  @MainActor func flip(_ toggle: XCUIElement, at x: Double = 0.93) {
    toggle.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
  }
  // Settings is a sheet: open it from the ⋯ menu of a notebook, use one control, close it.
  @MainActor func changeSetting(_ app: XCUIApplication, _ name: String) {
    app.buttons["More"].tap()
    app.buttons["Settings"].tap()
    let any = app.descendants(matching: .any)[name].firstMatch
    XCTAssertTrue(any.waitForExistence(timeout: 5), name)
    // A switch is turned by its own control, not by the row around it.
    if app.switches[name].exists {
      flip(app.switches[name])
    } else {
      any.tap()
    }
    app.buttons["Done"].tap()
  }
  @MainActor func chooseFreshStorageFolder(_ app: XCUIApplication, folderName: String? = nil) {
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
    let folderName = folderName ?? "NoteCraft Test " + UUID().uuidString.prefix(8)
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
  }
}
