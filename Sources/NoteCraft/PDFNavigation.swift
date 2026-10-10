import NoteCraftCore
import PDFKit
import SwiftUI

struct PDFChapter: Identifiable {
  let id = UUID()
  let title: String
  let pageID: UUID?
  let depth: Int
}

@MainActor enum PDFNavigation {
  static func chapters(_ package: NotebookPackage) -> [PDFChapter] {
    var chapters: [PDFChapter] = []
    var seen: Set<String> = []
    for page in package.notebook.pages {
      guard let name = page.backgroundPDF, seen.insert(name).inserted,
        let data = package.assets[name], let pdf = PDFDocument(data: data),
        let root = pdf.outlineRoot
      else { continue }
      func visit(_ node: PDFOutline, depth: Int) {
        guard depth < 64 else { return }
        let number = node.destination?.page.map { pdf.index(for: $0) }
        let id = package.notebook.pages.first {
          $0.backgroundPDF == name && $0.backgroundPage == number
        }?.id
        chapters.append(
          PDFChapter(title: node.label ?? "Untitled section", pageID: id, depth: depth))
        for i in 0..<node.numberOfChildren {
          if let child = node.child(at: i) { visit(child, depth: depth + 1) }
        }
      }
      for i in 0..<root.numberOfChildren {
        if let node = root.child(at: i) { visit(node, depth: 0) }
      }
    }
    return chapters
  }
}

struct DocumentNavigator: View {
  let package: NotebookPackage
  let currentPage: Int
  let onSelect: (UUID) -> Void
  @State private var section = 0
  @State private var number = ""
  @State private var chapters: [PDFChapter] = []
  @Environment(\.dismiss) private var dismiss
  private func select(_ id: UUID) {
    onSelect(id)
    dismiss()
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 16) {
        HStack {
          TextField("Page number", text: $number).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("pageNumberField")
            .onSubmit {
              if let n = Int(number), package.notebook.pages.indices.contains(n - 1) {
                select(package.notebook.pages[n - 1].id)
              }
            }
          Text("of \(package.notebook.pages.count)").foregroundStyle(.secondary)
          Button("Go") { if let n = Int(number) { select(package.notebook.pages[n - 1].id) } }
            .disabled(Int(number).map { !package.notebook.pages.indices.contains($0 - 1) } ?? true)
        }.padding(.horizontal, 20)
        Picker("Show", selection: $section) {
          Text("Pages").tag(0)
          Text("Bookmarks").tag(1)
          Text("Contents").tag(2)
        }.pickerStyle(.segmented).padding(.horizontal, 20)
        List {
          if section == 2 {
            if chapters.isEmpty {
              Text("This PDF has no table of contents.").foregroundStyle(.secondary)
            }
            ForEach(chapters) { chapter in
              Button {
                if let id = chapter.pageID { select(id) }
              } label: {
                HStack {
                  Text(chapter.title)
                  Spacer()
                  if let id = chapter.pageID,
                    let i = package.notebook.pages.firstIndex(where: { $0.id == id })
                  {
                    Text("\(i + 1)").foregroundStyle(.secondary)
                  }
                }
                .padding(.leading, Double(min(8, chapter.depth)) * 16)
              }.disabled(chapter.pageID == nil)
            }
          } else {
            ForEach(Array(package.notebook.pages.enumerated()), id: \.element.id) { i, page in
              if section == 0 || page.bookmarked {
                Button {
                  select(page.id)
                } label: {
                  HStack {
                    Label("Page \(i + 1)", systemImage: page.bookmarked ? "bookmark.fill" : "doc")
                    Spacer()
                    if i == currentPage { Image(systemName: "checkmark") }
                  }
                }
              }
            }
            if section == 1 && !package.notebook.pages.contains(where: \.bookmarked) {
              Text("Bookmark a page using the bookmark button.").foregroundStyle(.secondary)
            }
          }
        }
      }.padding(.top, 16).navigationTitle("Navigate document")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }.frame(minWidth: 380, minHeight: 450).preferredColorScheme(.light)
      .onAppear {
        number = String(currentPage + 1)
        chapters = PDFNavigation.chapters(package)
      }
  }
}
