import XCTest

final class LanguageUITests: XCTestCase {
  // The language is chosen in Settings, applies at once everywhere, and "System" goes back to the iPad's.
  @MainActor func testTheLanguageCanBeChosenInSettingsAndAppliesAtOnce() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--ui-test-reset-input"]
    app.launch()
    chooseFreshStorageFolder(app)
    XCTAssertTrue(app.buttons["New"].waitForExistence(timeout: 20))

    func openSettings(_ title: String) {
      app.buttons[title].tap()
      XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }
    func choose(_ identifier: String) {
      let row = app.buttons[identifier]
      var swipes = 0
      while !(row.exists && row.isHittable) && swipes < 8 {
        app.swipeUp()
        swipes += 1
      }
      row.tap()
    }

    openSettings("Settings")
    choose("language-de")
    // Settings itself, the library behind it and a menu are German at once.
    XCTAssertTrue(app.buttons["Fertig"].waitForExistence(timeout: 5), "The sheet is in German")
    app.buttons["Fertig"].tap()
    XCTAssertTrue(app.buttons["Neu"].waitForExistence(timeout: 5), "The library is in German")
    XCTAssertTrue(app.buttons["Papierkorb"].exists, "so is its sidebar")
    app.buttons["Neu"].tap()
    XCTAssertTrue(app.buttons["Notizbuch"].waitForExistence(timeout: 5), "and the New menu")
    app.buttons["Notizbuch"].tap()
    XCTAssertTrue(app.buttons["Erstellen"].waitForExistence(timeout: 5), "and the sheet to create one")
    app.buttons["Erstellen"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["drawingCanvas"].firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["Radierer"].exists, "The tools of the notebook are German")
    XCTAssertTrue(app.buttons["Dokumente"].exists)

    // Back to the language of the iPad, which is English here.
    app.buttons["Mehr"].tap()
    app.buttons["Einstellungen"].tap()
    choose("language-system")
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5), "System is English on this iPad")
    app.buttons["Done"].tap()
    XCTAssertTrue(app.buttons["Eraser"].waitForExistence(timeout: 5))
  }
}
