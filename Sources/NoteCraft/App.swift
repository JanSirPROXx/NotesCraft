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
  var body: some Scene {
    #if os(macOS)
      Window("Notebooks", id: "library") { Library().preferredColorScheme(.light) }
    #endif
    DocumentGroup(newDocument: NoteDocument()) { file in
      Workspace(document: file.$document, fileURL: file.fileURL).preferredColorScheme(.light)
    }
  }
}
