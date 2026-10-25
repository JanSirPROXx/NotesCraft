import Foundation

public enum PackError: Error, Equatable, LocalizedError {
  case wrongSize(expected: Int, actual: Int)
  case wrongHash
  case noManifest
  case manifestDoesNotMatch(String)
  case unexpectedFile(String)
  case wrongKind(expected: PackKind, actual: PackKind)
  case invalidContent(String)

  public var errorDescription: String? {
    switch self {
    case .wrongSize: "The download is not the size the catalog promised."
    case .wrongHash: "The download is not what the catalog promised, so it was thrown away."
    case .noManifest: "The pack has no pack.json."
    case .manifestDoesNotMatch(let what): "The pack says another \(what) than the catalog."
    case .unexpectedFile(let path): "The pack holds “\(path)”, which does not belong in it."
    case .wrongKind: "The pack is not of the kind it should be."
    case .invalidContent(let why): "The pack is not valid: \(why)."
    }
  }
}

public struct PackManifest: Codable, Equatable, Sendable {
  public static let format = 1
  public var format = PackManifest.format
  public var id: String
  public var kind: PackKind
  public var name: String
  public var version: String
  public init(id: String, kind: PackKind, name: String, version: String) {
    self.id = id
    self.kind = kind
    self.name = name
    self.version = version
  }
}

// A pack is a zip file with a `pack.json` and, in `content/`, what the kind of pack is made of:
//   theme            a theme folder (theme.json, fonts/, icons/)
//   sticker          elements.json, a list of elements (what "Save as element" keeps)
//   template planner a notebook package (manifest.json and assets/)
public struct Pack: Sendable {
  public static let maxStickers = 200
  public static let maxTemplatePages = 50
  public static let maxPlannerPages = 400

  public let manifest: PackManifest
  // The files of `content/`, by path inside it.
  public let files: [String: Data]

  // Checks a downloaded pack against what the catalog said about it, and opens it.
  public static func open(
    _ data: Data, expecting entry: CatalogEntry? = nil, limits: ZipLimits = .pack
  ) throws -> Pack {
    if let entry {
      guard data.count == entry.size else {
        throw PackError.wrongSize(expected: entry.size, actual: data.count)
      }
      guard sha256Hex(data) == entry.sha256 else { throw PackError.wrongHash }
    }
    let archive = try ZipArchive.read(data, limits: limits)
    guard let manifestData = archive["pack.json"],
      let manifest = try? JSONDecoder().decode(PackManifest.self, from: manifestData)
    else { throw PackError.noManifest }
    guard manifest.format == PackManifest.format else {
      throw PackError.invalidContent("format \(manifest.format) is not supported")
    }
    if let entry {
      guard manifest.id == entry.id else { throw PackError.manifestDoesNotMatch("id") }
      guard manifest.kind == entry.kind else { throw PackError.manifestDoesNotMatch("kind") }
      guard manifest.version == entry.version else { throw PackError.manifestDoesNotMatch("version") }
    }
    var content: [String: Data] = [:]
    for (path, bytes) in archive where path != "pack.json" {
      guard path.hasPrefix("content/"), path.count > 8 else { throw PackError.unexpectedFile(path) }
      content[String(path.dropFirst(8))] = bytes
    }
    return Pack(manifest: manifest, files: content)
  }

  // The bytes of a pack with this manifest and content, always the same for the same input.
  public static func build(manifest: PackManifest, content: [String: Data]) throws -> Data {
    var all: [String: Data] = ["pack.json": try encode(manifest)]
    for (path, data) in content { all["content/" + path] = data }
    return try ZipArchive.write(all)
  }

  private static func encode(_ manifest: PackManifest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(manifest)
  }

  // MARK: what a kind of pack holds

  // A theme: the content is written to `directory` and read back as a theme package, which checks it.
  public func theme(writingTo directory: URL) throws -> Theme {
    try expect(.theme)
    let fm = FileManager.default
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    for (path, data) in files {
      let url = try ThemePackage.resolve(path, in: directory.resolvingSymlinksInPath())
      try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }
    let theme = try ThemePackage.load(from: directory)
    guard theme.id == manifest.id else { throw PackError.manifestDoesNotMatch("theme id") }
    return theme
  }

  public func stickers() throws -> [ElementClip] {
    try expect(.sticker)
    guard files.keys.sorted() == ["elements.json"], let data = files["elements.json"] else {
      throw PackError.invalidContent("stickers need exactly an elements.json")
    }
    guard let clips = try? JSONDecoder().decode([ElementClip].self, from: data) else {
      throw PackError.invalidContent("elements.json cannot be read")
    }
    guard (1...Self.maxStickers).contains(clips.count) else {
      throw PackError.invalidContent("a sticker pack holds 1 to \(Self.maxStickers) stickers")
    }
    for clip in clips {
      guard (1...60).contains(clip.title.trimmingCharacters(in: .whitespaces).count) else {
        throw PackError.invalidContent("a sticker has no name")
      }
      guard clip.content.strokes.count <= 20_000 else {
        throw PackError.invalidContent("“\(clip.title)” is too detailed")
      }
    }
    return clips
  }

  // A template or a planner: a notebook.
  public func notebook() throws -> NotebookPackage {
    guard manifest.kind == .template || manifest.kind == .planner else {
      throw PackError.wrongKind(expected: .template, actual: manifest.kind)
    }
    var root: [String: FileWrapper] = [:]
    var assets: [String: FileWrapper] = [:]
    for (path, data) in files {
      if path == "manifest.json" {
        root[path] = FileWrapper(regularFileWithContents: data)
      } else if path.hasPrefix("assets/") {
        let name = String(path.dropFirst(7))
        guard !name.isEmpty, !name.contains("/") else { throw PackError.unexpectedFile(path) }
        assets[name] = FileWrapper(regularFileWithContents: data)
      } else {
        throw PackError.unexpectedFile(path)
      }
    }
    root["assets"] = FileWrapper(directoryWithFileWrappers: assets)
    let package: NotebookPackage
    do {
      package = try NotebookPackage(fileWrapper: FileWrapper(directoryWithFileWrappers: root))
    } catch { throw PackError.invalidContent("the notebook cannot be read") }
    let limit = manifest.kind == .template ? Self.maxTemplatePages : Self.maxPlannerPages
    guard (1...limit).contains(package.notebook.pages.count) else {
      throw PackError.invalidContent("a \(manifest.kind.title.lowercased()) holds 1 to \(limit) pages")
    }
    return package
  }

  private func expect(_ kind: PackKind) throws {
    guard manifest.kind == kind else { throw PackError.wrongKind(expected: kind, actual: manifest.kind) }
  }
}

extension NotebookPackage {
  // Adds the pages of another notebook (a page template, say) after page `index`, or at the end.
  // Objects and media get new identities and names, so nothing in this notebook can be replaced by
  // what comes with the pages. Returns the index of the first page added.
  @discardableResult
  public mutating func insertPages(of source: NotebookPackage, after index: Int? = nil) throws -> Int {
    var renamed: [String: String] = [:]
    func rename(_ name: String) throws -> String {
      if let done = renamed[name] { return done }
      guard let data = source.assets[name] else { throw PackageError.invalidAsset(name) }
      let ext = (name as NSString).pathExtension
      let fresh = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
      renamed[name] = fresh
      assets[fresh] = data
      return fresh
    }
    var added: [Page] = []
    for page in source.notebook.pages {
      var copy = InkGestures.duplicatePage(page)
      for i in copy.images.indices { copy.images[i].filename = try rename(copy.images[i].filename) }
      if let pdf = copy.backgroundPDF { copy.backgroundPDF = try rename(pdf) }
      added.append(copy)
    }
    let position = min(notebook.pages.count, max(0, (index ?? (notebook.pages.count - 1)) + 1))
    notebook.pages.insert(contentsOf: added, at: position)
    return position
  }
}
