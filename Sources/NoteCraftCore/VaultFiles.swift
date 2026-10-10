import CryptoKit
import Foundation

public enum VaultEntryKind: String, Sendable {
  case folder, notebook, whiteboard, pdf, markdown, image, other
}
public struct VaultEntry: Identifiable, Sendable {
  public var id: URL { url }
  public let url: URL
  public let kind: VaultEntryKind
  public let title: String
  public let modified: Date
  public init(url: URL, kind: VaultEntryKind, title: String, modified: Date) {
    self.url = url
    self.kind = kind
    self.title = title
    self.modified = modified
  }
}
public struct FileStamp: Equatable, Sendable {
  public let digest: Data
  public init(data: Data) { digest = Data(SHA256.hash(data: data)) }
}
public struct FileSnapshot: Sendable {
  public let data: Data
  public var stamp: FileStamp { FileStamp(data: data) }
}
public actor VaultFiles {
  public init() {}
  private struct Header: Decodable {
    struct Summary: Decodable {
      var title: String
      var kind: NotebookKind?
    }
    var notebook: Summary
  }
  public func list(_ folder: URL) throws -> [VaultEntry] {
    try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ).map { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
      let ext = url.pathExtension.lowercased()
      var title = url.deletingPathExtension().lastPathComponent
      let kind: VaultEntryKind
      if ext == "notecraft" {
        let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let header = data.flatMap { try? JSONDecoder().decode(Header.self, from: $0) }
        title = header?.notebook.title ?? title
        kind = header?.notebook.kind == .whiteboard ? .whiteboard : .notebook
      } else if values.isDirectory == true {
        kind = .folder
        title = url.lastPathComponent
      } else {
        switch ext {
        case "pdf": kind = .pdf
        case "md", "markdown", "txt": kind = .markdown
        case "png", "jpg", "jpeg", "heic", "gif", "tiff": kind = .image
        default:
          kind = .other
          title = url.lastPathComponent
        }
      }
      return VaultEntry(
        url: url, kind: kind, title: title, modified: values.contentModificationDate ?? .distantPast
      )
    }.sorted { a, b in
      if (a.kind == .folder) != (b.kind == .folder) { return a.kind == .folder }
      return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
  }
  public func read(_ url: URL) throws -> FileSnapshot {
    var error: NSError?
    var result: Result<Data, Error>?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { location in
      result = Result { try Data(contentsOf: location) }
    }
    if let error { throw error }
    guard let result else { throw PackageError.invalidPackage }
    return FileSnapshot(data: try result.get())
  }
  @discardableResult public func write(
    _ data: Data, to url: URL, expected: FileStamp?, createOnly: Bool = false
  ) throws -> FileStamp {
    var error: NSError?
    var result: Result<Void, Error>?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) {
      location in
      result = Result {
        let exists = FileManager.default.fileExists(atPath: location.path)
        if createOnly && exists { throw PackageError.conflict }
        if let expected {
          guard exists, FileStamp(data: try Data(contentsOf: location)) == expected else {
            throw PackageError.conflict
          }
        }
        try data.write(to: location, options: .atomic)
      }
    }
    if let error { throw error }
    guard let result else { throw PackageError.invalidPackage }
    try result.get()
    return FileStamp(data: data)
  }
  public func availableURL(in folder: URL, title: String, extension ext: String) -> URL {
    let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r")).joined(
      separator: " "
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let name = safe.isEmpty ? "Untitled" : safe
    var index = 0
    while true {
      let url = folder.appendingPathComponent(name + (index == 0 ? "" : " \(index + 1)"))
        .appendingPathExtension(ext)
      if !FileManager.default.fileExists(atPath: url.path) { return url }
      index += 1
    }
  }
  public func createFolder(in parent: URL, name: String) throws {
    let url = availableURL(in: parent, title: name, extension: "")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  }
}
