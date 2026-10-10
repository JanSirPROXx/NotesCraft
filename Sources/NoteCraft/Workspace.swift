import SwiftUI
import NoteCraftCore
struct Workspace: View {
    @Binding var document: NoteDocument
    let fileURL: URL?
    var body: some View { Text(document.package.notebook.title) }
}
