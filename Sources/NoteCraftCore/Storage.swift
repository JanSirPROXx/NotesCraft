import Foundation

public enum PackageError: LocalizedError {
  case invalidPackage
  case unsupportedVersion(Int)
  case invalidAsset(String)
  case conflict
  case lockedPDF
  public var errorDescription: String? {
    switch self {
    case .lockedPDF: "This PDF is locked. Unlock it in a PDF editor before annotating it."
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
    let manifest = try manifestData()
    var files: [String: FileWrapper] = [:]
    for (name, data) in assets { files[name] = FileWrapper(regularFileWithContents: data) }
    return FileWrapper(directoryWithFileWrappers: [
      "manifest.json": FileWrapper(regularFileWithContents: manifest),
      "assets": FileWrapper(directoryWithFileWrappers: files),
    ])
  }
  // Checks the package is writable at all, then encodes `manifest.json`. Throws before anything
  // has been touched on disk.
  func manifestData() throws -> Data {
    guard !notebook.pages.isEmpty else { throw PackageError.invalidPackage }
    for name in assets.keys {
      guard Self.validName(name) else { throw PackageError.invalidAsset(name) }
    }
    try validateAssets()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(Manifest(version: 1, notebook: notebook))
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
  // A reference to media that no longer exists can never be rendered or saved. Dropping it keeps
  // one dangling image from blocking every later save of the surrounding handwriting.
  @discardableResult
  public mutating func pruneMissingAssets() -> [String] {
    var dropped: [String] = []
    for index in notebook.pages.indices {
      notebook.pages[index].images.removeAll { image in
        let missing = assets[image.filename] == nil
        if missing { dropped.append(image.filename) }
        return missing
      }
      if let name = notebook.pages[index].backgroundPDF, assets[name] == nil {
        dropped.append(name)
        notebook.pages[index].backgroundPDF = nil
        notebook.pages[index].backgroundPage = nil
      }
    }
    return dropped
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
          (text.boxWidth ?? 280).isFinite, (text.boxWidth ?? 280) > 0,
          (text.rotation ?? 0).isFinite
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
  // The assets last read from or written to each package. A save only writes what differs, so an
  // autosave after a pen stroke touches `manifest.json` and not the 50 MB PDF beside it (which
  // would also have iCloud upload that PDF again). Bounded: a few packages are open at a time.
  private var known: [String: [String: Data]] = [:]
  private var knownOrder: [String] = []

  private func remember(_ assets: [String: Data], at url: URL) {
    let key = url.standardizedFileURL.path
    known[key] = assets
    knownOrder.removeAll { $0 == key }
    knownOrder.append(key)
    while knownOrder.count > 4 { known[knownOrder.removeFirst()] = nil }
  }
  private func forget(_ url: URL) {
    let key = url.standardizedFileURL.path
    known[key] = nil
    knownOrder.removeAll { $0 == key }
  }

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
    let package = try result.get()
    remember(package.assets, at: url)
    return package
  }

  // The revision stored in a package, read without loading its pages or media.
  private static func diskRevision(of url: URL) throws -> UInt64 {
    struct Probe: Decodable {
      struct Inner: Decodable { var revision: UInt64? }
      var notebook: Inner
    }
    let data = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
    return try JSONDecoder().decode(Probe.self, from: data).notebook.revision ?? 0
  }

  private static func sameBuffer(_ a: Data, _ b: Data) -> Bool {
    a.count == b.count
      && a.withUnsafeBytes { x in b.withUnsafeBytes { y in x.baseAddress == y.baseAddress } }
  }

  public func save(
    _ package: NotebookPackage, to url: URL, expectedRevision: UInt64? = nil,
    createOnly: Bool = false
  ) throws {
    let manifest = try package.manifestData()
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let exists = FileManager.default.fileExists(atPath: url.path)
    var coordinationError: NSError?
    var result: Result<Void, Error>?
    var written: [String: Data]?
    let previous = known[url.standardizedFileURL.path] ?? [:]
    NSFileCoordinator().coordinate(
      writingItemAt: url, options: exists && !createOnly ? .forMerging : .forReplacing,
      error: &coordinationError
    ) { coordinatedURL in
      result = Result {
        let present = FileManager.default.fileExists(atPath: coordinatedURL.path)
        if createOnly && present { throw PackageError.conflict }
        if let expectedRevision {
          guard present, (try? Self.diskRevision(of: coordinatedURL)) == expectedRevision else {
            throw PackageError.conflict
          }
        }
        let manifestFile = coordinatedURL.appendingPathComponent("manifest.json")
        if present, FileManager.default.fileExists(atPath: manifestFile.path) {
          written = try Self.update(
            coordinatedURL, manifest: manifest, assets: package.assets, previous: previous)
        } else {
          try package.fileWrapper().write(
            to: coordinatedURL, options: .atomic, originalContentsURL: nil)
          written = package.assets
        }
      }
    }
    if let coordinationError {
      forget(url)
      throw coordinationError
    }
    guard let result else { throw PackageError.invalidPackage }
    do {
      try result.get()
      if let written { remember(written, at: url) }
    } catch {
      // What is on disk is no longer what was remembered.
      forget(url)
      throw error
    }
  }

  // Writes into an existing package: new or changed assets first, then the manifest (an atomic
  // replace, so a crash leaves the old, consistent notebook), then removes what is no longer
  // used. Returns what the package's assets are afterwards.
  private static func update(
    _ package: URL, manifest: Data, assets: [String: Data], previous: [String: Data]
  ) throws -> [String: Data] {
    let files = FileManager.default
    let folder = package.appendingPathComponent("assets", isDirectory: true)
    try files.createDirectory(at: folder, withIntermediateDirectories: true)
    var current: [String: Data] = [:]
    for (name, data) in assets {
      let file = folder.appendingPathComponent(name)
      if let old = previous[name], sameBuffer(old, data) {
        current[name] = data
        continue
      }
      let size = (try? files.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
      if previous[name] == nil, size == data.count,
        let existing = try? Data(contentsOf: file, options: .mappedIfSafe), existing == data
      {
        current[name] = data
        continue
      }
      try data.write(to: file, options: .atomic)
      current[name] = data
    }
    try manifest.write(to: package.appendingPathComponent("manifest.json"), options: .atomic)
    for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
    where assets[name] == nil {
      try? files.removeItem(at: folder.appendingPathComponent(name))
    }
    return current
  }
}
