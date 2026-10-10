import NoteCraftCore
import Observation
import PDFKit

struct DocumentSearchResult: Identifiable, Sendable {
  var id: UUID { pageID }
  let pageID: UUID
  let pageNumber: Int
  let snippet: String
  let highlights: [Rect]
}

@MainActor @Observable final class DocumentSearch {
  private(set) var results: [DocumentSearchResult] = []
  private(set) var isSearching = false
  @ObservationIgnored private var worker: Task<[DocumentSearchResult], Never>?
  private var generation = 0

  func update(_ package: NotebookPackage, query: String) {
    worker?.cancel()
    generation += 1
    let generation = generation
    results = []
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      isSearching = false
      return
    }
    isSearching = true
    let worker = Task.detached(priority: .userInitiated) { Self.find(package, query: query) }
    self.worker = worker
    Task { [weak self] in
      let results = await worker.value
      guard let self, generation == self.generation else { return }
      self.results = results
      self.isSearching = false
    }
  }

  nonisolated static func find(_ package: NotebookPackage, query: String) -> [DocumentSearchResult]
  {
    guard !query.isEmpty else { return [] }
    var documents: [String: PDFDocument] = [:]
    var result: [DocumentSearchResult] = []
    for (index, page) in package.notebook.pages.enumerated() {
      if Task.isCancelled { break }
      let texts = page.texts.filter { $0.text.localizedStandardContains(query) }
      var highlights = texts.map(\.bounds)
      var snippet = texts.first?.text
      if let name = page.backgroundPDF, let data = package.assets[name] {
        if documents[name] == nil { documents[name] = PDFDocument(data: data) }
        if let source = documents[name]?.page(at: page.backgroundPage ?? 0),
          let string = source.string, let reference = source.pageRef
        {
          let text = string as NSString
          let transform = reference.getDrawingTransform(
            .mediaBox,
            rect: CGRect(x: 0, y: 0, width: page.dimensions.x, height: page.dimensions.y),
            rotate: 0, preserveAspectRatio: true)
          var location = 0
          while location < text.length {
            if Task.isCancelled { return result }
            let range = text.range(
              of: query, options: [.caseInsensitive, .diacriticInsensitive],
              range: NSRange(location: location, length: text.length - location))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if snippet == nil {
              let start = max(0, range.location - 35)
              snippet = text.substring(
                with: NSRange(location: start, length: min(110, text.length - start)))
            }
            if let selection = source.selection(for: range) {
              for line in selection.selectionsByLine() {
                let r = line.bounds(for: source).applying(transform)
                highlights.append(
                  Rect(
                    x: r.minX, y: page.dimensions.y - r.maxY,
                    width: r.width, height: r.height))
              }
            }
            location = range.location + range.length
          }
        }
      }
      if let snippet {
        result.append(
          DocumentSearchResult(
            pageID: page.id, pageNumber: index + 1,
            snippet: String(snippet.replacingOccurrences(of: "\n", with: " ").prefix(120)),
            highlights: highlights))
      }
    }
    return result
  }
}
