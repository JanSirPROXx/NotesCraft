import Foundation

// What an export takes from a notebook, decided without any rendering so it is the same on every
// platform and can be tested by the page numbers alone.

public enum ExportScope: Equatable, Sendable {
  /// The page at this index of `Notebook.pages`.
  case page(Int)
  /// Every page, in the order the notebook has them.
  case notebook
}

public enum ExportError: Error, Equatable, LocalizedError {
  case nothingToExport
  case noSuchPage(Int)
  public var errorDescription: String? {
    switch self {
    case .nothingToExport: coreText("There are no pages to export.")
    case .noSuchPage: coreText("That page is no longer in the notebook.")
    }
  }
}

/// The pages an export writes and the order they take in the file.
public struct ExportPlan: Equatable, Sendable {
  public let scope: ExportScope
  /// Indexes into `Notebook.pages`, in file order.
  public let pageIndexes: [Int]
  public var count: Int { pageIndexes.count }

  public init(scope: ExportScope, pageCount: Int) throws {
    guard pageCount > 0 else { throw ExportError.nothingToExport }
    switch scope {
    case .notebook: pageIndexes = Array(0..<pageCount)
    case .page(let index):
      guard (0..<pageCount).contains(index) else { throw ExportError.noSuchPage(index) }
      pageIndexes = [index]
    }
    self.scope = scope
  }

  public init(scope: ExportScope, notebook: Notebook) throws {
    try self.init(scope: scope, pageCount: notebook.pages.count)
  }

  /// The notebook cut down to the planned pages. The assets stay as they are: the exporter takes
  /// only the ones a page names, and a dictionary of `Data` is shared, not copied.
  public func package(from source: NotebookPackage) throws -> NotebookPackage {
    guard pageIndexes.allSatisfy({ source.notebook.pages.indices.contains($0) }) else {
      throw ExportError.noSuchPage(pageIndexes.first { !source.notebook.pages.indices.contains($0) } ?? 0)
    }
    var cut = source
    if scope != .notebook { cut.notebook.pages = pageIndexes.map { source.notebook.pages[$0] } }
    return cut
  }

  /// The name the file is offered under: the notebook's own, and for one page also which one, so
  /// two exports from the same notebook do not look alike in Files.
  public func fileName(title: String) -> String {
    switch scope {
    case .notebook: title
    case .page(let index): "\(title) – \(coreText("Page \(index + 1)"))"
    }
  }
}

/// How far an export has got. `completed` counts pages that are done, so a bar made from it never
/// moves backwards; the file is written after the last page (`isRendered`), which is a wait of
/// unknown length and gets its own message.
public struct ExportProgress: Equatable, Sendable {
  public let completed: Int
  public let total: Int
  public init(completed: Int, total: Int) {
    self.total = max(0, total)
    self.completed = min(max(0, completed), self.total)
  }
  public var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
  public var isRendered: Bool { completed >= total }
  /// The page being worked on, counted from 1, for "page 3 of 120".
  public var current: Int { min(completed + 1, max(total, 1)) }
}
