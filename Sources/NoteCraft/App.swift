import SwiftUI
import UniformTypeIdentifiers
import NoteCraftCore

extension UTType {
    static let noteCraft = UTType(exportedAs: "app.notecraft.notebook", conformingTo: .package)
}
struct NoteDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.noteCraft]
    var package: NotebookPackage
    init(package: NotebookPackage = NotebookPackage()) { self.package = package }
    init(configuration: ReadConfiguration) throws { package = try NotebookPackage(fileWrapper: configuration.file) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { try package.fileWrapper() }
}
@main struct NoteCraftApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: NoteDocument()) { file in
            Workspace(document: file.$document, fileURL: file.fileURL)
        }
        .commands { CommandGroup(replacing: .appInfo) { Text("NoteCraft") } }
    }
}
