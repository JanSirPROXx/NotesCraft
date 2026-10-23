import NoteCraftCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  static let noteCraft = UTType(exportedAs: "app.notecraft.notebook", conformingTo: .package)
}
struct NoteDocument: FileDocument {
  static let readableContentTypes: [UTType] = [.noteCraft]
  var package: NotebookPackage
  init(package: NotebookPackage = NotebookPackage()) { self.package = package }
  init(configuration: ReadConfiguration) throws {
    package = try NotebookPackage(fileWrapper: configuration.file)
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    try package.fileWrapper()
  }
}
@main struct NoteCraftApp: App {
  init() {
    #if DEBUG
      if CommandLine.arguments.contains("--ui-test-reset-input") {
        UserDefaults.standard.removeObject(forKey: "keepZoomOnNewPage")
        // Everything a test can change in Settings starts from its default again.
        for key in [
          Preferences.pencilOnly, Preferences.holdToShape, Preferences.scratchToErase,
          Preferences.circleToLasso, Preferences.gpuInk, Preferences.scribbleHint,
          Preferences.horizontalPages, Preferences.infiniteScroll, Preferences.stabilization,
          Preferences.pullToAddPage, Preferences.showPageIndicator, Preferences.showZoomIndicator,
          Preferences.undoRedoPosition, Preferences.toolbarOrder, Preferences.toolbarHidden,
          "savedStorages", "activeStorageID", "vaultBookmark", "readingPositions",
        ] {
          UserDefaults.standard.removeObject(forKey: key)
        }
      }
      // Notebooks scroll vertically unless told otherwise; the paging tests ask for the row.
      if CommandLine.arguments.contains("--ui-test-horizontal-pages") {
        UserDefaults.standard.set(true, forKey: "horizontalNotebookPages")
      }
    #endif
  }
  var body: some Scene {
    WindowGroup("NotesCraft") { VaultRoot() }
      .commands { WorkspaceCommands() }
  }
}
