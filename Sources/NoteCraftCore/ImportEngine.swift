import CoreGraphics
import Foundation

public actor ImportEngine {
  public init() {}
  public func read(_ url: URL) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var result: Result<Data, Error>?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
      location in
      result = Result { try Data(contentsOf: location) }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw PackageError.invalidPackage }
    return try result.get()
  }
  public func pdf(_ url: URL) throws -> NotebookPackage {
    let data = try read(url)
    guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
      pdf.numberOfPages > 0
    else { throw PackageError.invalidPackage }
    let name = UUID().uuidString + ".pdf"
    let pages = try (1...pdf.numberOfPages).map { index -> Page in
      guard let source = pdf.page(at: index) else { throw PackageError.invalidPackage }
      let bounds = source.getBoxRect(.mediaBox)
      var page = Page(paper: Paper(pattern: .blank))
      page.backgroundPDF = name
      page.backgroundPage = index - 1
      let rotated = abs(source.rotationAngle) % 180 == 90
      page.backgroundSize =
        rotated ? Point(bounds.height, bounds.width) : Point(bounds.width, bounds.height)
      return page
    }
    return NotebookPackage(
      notebook: Notebook(title: url.deletingPathExtension().lastPathComponent, pages: pages),
      assets: [name: data])
  }
}
