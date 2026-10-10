import Foundation

public enum PackageError: LocalizedError {
  case invalidPackage
  case unsupportedVersion(Int)
  case invalidAsset(String)
  case conflict
  public var errorDescription: String? {
    switch self {
    case .invalidPackage: "The notebook package is missing or contains invalid data."
    case .unsupportedVersion(let v):
      "This notebook uses format version \(v), which this app cannot open."
    case .invalidAsset(let name): "Invalid or missing notebook asset: \(name)."
    case .conflict:
      "The notebook changed on disk. Reopen it before saving to avoid overwriting another edit."
    }
  }
}
public struct NotebookPackage: Sendable {
  public var notebook: Notebook
  public var assets: [String: Data]
  public init(notebook: Notebook = Notebook(), assets: [String: Data] = [:]) {
    self.notebook = notebook
    self.assets = assets
  }
  private struct Manifest: Codable {
    let version: Int
    let notebook: Notebook
  }
  private static func validName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
  }
  public func fileWrapper() throws -> FileWrapper {
    guard !notebook.pages.isEmpty else { throw PackageError.invalidPackage }
    var files: [String: FileWrapper] = [:]
    for (name, data) in assets {
      guard Self.validName(name) else { throw PackageError.invalidAsset(name) }
      files[name] = FileWrapper(regularFileWithContents: data)
    }
    try validateAssets()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return FileWrapper(directoryWithFileWrappers: [
      "manifest.json": FileWrapper(
        regularFileWithContents: try encoder.encode(Manifest(version: 1, notebook: notebook))),
      "assets": FileWrapper(directoryWithFileWrappers: files),
    ])
  }
  public init(fileWrapper: FileWrapper) throws {
    guard let files = fileWrapper.fileWrappers,
      let data = files["manifest.json"]?.regularFileContents
    else { throw PackageError.invalidPackage }
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    guard manifest.version == 1 else { throw PackageError.unsupportedVersion(manifest.version) }
    notebook = manifest.notebook
    guard !notebook.pages.isEmpty else { throw PackageError.invalidPackage }
    assets = [:]
    for (name, file) in files["assets"]?.fileWrappers ?? [:] {
      guard Self.validName(name), let data = file.regularFileContents else {
        throw PackageError.invalidAsset(name)
      }
      assets[name] = data
    }
    try validateAssets()
  }
  private func validateAssets() throws {
    if let viewport = notebook.viewport {
      guard viewport.scale.isFinite, (0.1...12).contains(viewport.scale),
        viewport.offset.x.isFinite, viewport.offset.y.isFinite
      else { throw PackageError.invalidPackage }
    }
    for page in notebook.pages {
      for name in page.images.map(\.filename) + [page.backgroundPDF].compactMap({ $0 }) {
        guard Self.validName(name), assets[name] != nil else {
          throw PackageError.invalidAsset(name)
        }
      }
      let dimensions = page.dimensions
      guard dimensions.x > 0, dimensions.y > 0, dimensions.x <= 100_000, dimensions.y <= 100_000
      else { throw PackageError.invalidPackage }
      func validPoint(_ point: Point) -> Bool {
        point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000
          && abs(point.y) <= 1_000_000
      }
      for text in page.texts {
        guard validPoint(text.origin), text.size.isFinite, text.size > 0, text.size <= 1000,
          (text.boxWidth ?? 280).isFinite, (text.boxWidth ?? 280) > 0
        else { throw PackageError.invalidPackage }
      }
      for image in page.images {
        let r = image.frame
        guard validPoint(Point(r.x, r.y)), r.width.isFinite, r.height.isFinite, r.width > 0,
          r.height > 0, r.width <= 1_000_000, r.height <= 1_000_000, image.rotation.isFinite
        else { throw PackageError.invalidPackage }
      }
      guard dimensions.x.isFinite, dimensions.y.isFinite,
        page.strokes.allSatisfy({
          $0.width.isFinite && $0.width > 0 && $0.width <= 10000
            && $0.samples.allSatisfy {
              validPoint($0.point) && $0.pressure.isFinite && (0...1).contains($0.pressure)
                && $0.altitude.isFinite
            }
        })
      else { throw PackageError.invalidPackage }
    }
  }
}

// Coordination and revision checks also protect explicit vault saves from competing writers.
public actor PackageStore {
  public init() {}
  public func read(from url: URL) throws -> NotebookPackage {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var result: Result<NotebookPackage, Error>?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
      coordinatedURL in
      result = Result {
        try NotebookPackage(fileWrapper: FileWrapper(url: coordinatedURL, options: .immediate))
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw PackageError.invalidPackage }
    return try result.get()
  }
  public func save(_ package: NotebookPackage, to url: URL, expectedRevision: UInt64? = nil) throws
  {
    let wrapper = try package.fileWrapper()
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    var result: Result<Void, Error>?
    NSFileCoordinator().coordinate(
      writingItemAt: url, options: .forReplacing, error: &coordinationError
    ) { coordinatedURL in
      result = Result {
        if let expectedRevision {
          guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
            throw PackageError.conflict
          }
          let existing = try NotebookPackage(
            fileWrapper: FileWrapper(url: coordinatedURL, options: .immediate))
          guard existing.notebook.revision == expectedRevision else { throw PackageError.conflict }
        }
        try wrapper.write(to: coordinatedURL, options: .atomic, originalContentsURL: nil)
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw PackageError.invalidPackage }
    try result.get()
  }
}
