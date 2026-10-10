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
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
  #endif
  init() {
    #if DEBUG
      if CommandLine.arguments.contains("--ui-test-reset-input") {
        UserDefaults.standard.removeObject(forKey: "pencilOnlyDrawing")
      }
    #endif
  }
  var body: some Scene {
    WindowGroup("NoteCraft") { VaultRoot() }
  }
}
