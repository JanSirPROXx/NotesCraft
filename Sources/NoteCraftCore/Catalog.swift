import CryptoKit
import Foundation

// The marketplace: a free catalog of packs (themes, stickers, page templates, planners) that is a
// plain folder of files on a web server: an `index.json` and the packs and previews it names. There is
// no account, no server code and nothing to pay; anyone can add a pack by a pull request, and the
// app only trusts what the index says about a pack (its size and hash), not what the pack says.

public enum PackKind: String, Codable, CaseIterable, Sendable {
  case theme, sticker, template, planner

  public var title: String {
    switch self {
    case .theme: "Theme"
    case .sticker: "Stickers"
    case .template: "Page template"
    case .planner: "Planner"
    }
  }
  public var plural: String {
    switch self {
    case .theme: "Themes"
    case .sticker: "Stickers"
    case .template: "Templates"
    case .planner: "Planners"
    }
  }
  public var symbol: String {
    switch self {
    case .theme: "paintpalette"
    case .sticker: "star.square"
    case .template: "doc.text"
    case .planner: "calendar"
    }
  }
}

public enum CatalogCategory: String, Codable, CaseIterable, Sendable {
  case home, work, study, life
  public var title: String { rawValue.capitalized }
}

public enum CatalogError: Error, Equatable, LocalizedError {
  case notACatalog
  case unsupportedFormat(Int)
  case tooMany
  case invalid(id: String, why: String)
  case duplicate(String)

  public var errorDescription: String? {
    switch self {
    case .notACatalog: "The catalog could not be read."
    case .unsupportedFormat(let n): "The catalog uses format \(n), which this version cannot read."
    case .tooMany: "The catalog is too large."
    case .invalid(let id, let why): "The entry “\(id)” is not valid: \(why)."
    case .duplicate(let id): "The catalog lists “\(id)” twice."
    }
  }
}

public struct CatalogEntry: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var kind: PackKind
  public var name: String
  public var author: String
  public var summary: String
  public var category: CatalogCategory
  public var tags: [String] = []
  public var version: String
  public var license: String
  // Paths relative to the catalog.
  public var file: String
  public var preview: String?
  // What the file has to be: its size in bytes and its SHA-256 as 64 lowercase hex digits.
  public var size: Int
  public var sha256: String
  // For templates and planners: how many pages there are.
  public var pages: Int?

  public init(
    id: String, kind: PackKind, name: String, author: String, summary: String,
    category: CatalogCategory, tags: [String] = [], version: String = "1.0", license: String,
    file: String, preview: String? = nil, size: Int, sha256: String, pages: Int? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.author = author
    self.summary = summary
    self.category = category
    self.tags = tags
    self.version = version
    self.license = license
    self.file = file
    self.preview = preview
    self.size = size
    self.sha256 = sha256
    self.pages = pages
  }

  public static let maxPackBytes = 25 * 1024 * 1024

  // Checks what the index says before anything is fetched on the strength of it.
  public func validate() throws {
    func fail(_ why: String) -> CatalogError { .invalid(id: id, why: why) }
    guard ThemeFile.isValid(id: id) else { throw fail("the id is not 3 to 64 lowercase letters, digits, dots and dashes") }
    guard (1...60).contains(name.trimmingCharacters(in: .whitespaces).count) else { throw fail("the name is empty or over 60 characters") }
    guard author.count <= 60 else { throw fail("the author is over 60 characters") }
    guard summary.count <= 400 else { throw fail("the summary is over 400 characters") }
    guard tags.count <= 8, tags.allSatisfy({ (1...24).contains($0.count) }) else { throw fail("tags: at most 8 of 1 to 24 characters") }
    guard (1...24).contains(version.count) else { throw fail("the version is empty or over 24 characters") }
    guard (1...40).contains(license.count) else { throw fail("the license is empty or over 40 characters") }
    guard (1...Self.maxPackBytes).contains(size) else { throw fail("the size is not between 1 byte and 25 MB") }
    guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
      throw fail("the hash is not 64 lowercase hex digits")
    }
    guard file.hasSuffix(".ncpack"), (try? ZipArchive.validate(path: file)) != nil else {
      throw fail("the file is not a relative path ending in .ncpack")
    }
    if let preview {
      let lower = preview.lowercased()
      guard lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg"),
        (try? ZipArchive.validate(path: preview)) != nil
      else { throw fail("the preview is not a relative path to a png or jpg") }
    }
    if let pages { guard (1...500).contains(pages) else { throw fail("pages is not between 1 and 500") } }
  }

  // What search looks at.
  public func matches(_ query: String) -> Bool {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    guard !words.isEmpty else { return true }
    let text = ([name, author, summary, kind.title, category.title] + tags).joined(separator: " ").lowercased()
    return words.allSatisfy { text.contains($0) }
  }
}

public struct CatalogIndex: Equatable, Sendable {
  public static let format = 1
  public static let maxEntries = 500
  public static let maxBytes = 2 * 1024 * 1024

  public var updated: String
  public var packs: [CatalogEntry]

  public init(updated: String, packs: [CatalogEntry]) {
    self.updated = updated
    self.packs = packs
  }

  private struct Document: Codable {
    var format: Int
    var updated: String?
    var packs: [CatalogEntry]
  }

  public static func parse(_ data: Data) throws -> CatalogIndex {
    guard data.count <= maxBytes else { throw CatalogError.tooMany }
    guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
      throw CatalogError.notACatalog
    }
    guard document.format == format else { throw CatalogError.unsupportedFormat(document.format) }
    guard document.packs.count <= maxEntries else { throw CatalogError.tooMany }
    var ids = Set<String>()
    for entry in document.packs {
      try entry.validate()
      guard ids.insert(entry.id).inserted else { throw CatalogError.duplicate(entry.id) }
    }
    return CatalogIndex(updated: document.updated ?? "", packs: document.packs)
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(
      Document(format: Self.format, updated: updated, packs: packs.sorted { $0.id < $1.id }))
  }

  // The entries to show: filtered by category, kind and search, by name.
  public func entries(
    category: CatalogCategory? = nil, kind: PackKind? = nil, query: String = ""
  ) -> [CatalogEntry] {
    packs.filter { entry in
      (category == nil || entry.category == category) && (kind == nil || entry.kind == kind)
        && entry.matches(query)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}

public func sha256Hex(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
