import Foundation

public struct TrashItem: Codable, Identifiable, Sendable {
  public let id: UUID
  public let originalPath: String
  public let deleted: Date
  public let favoritePaths: [String]?
  public var name: String { URL(fileURLWithPath: originalPath).lastPathComponent }
}

extension VaultFiles {
  public func sidecar(for url: URL) -> URL {
    url.deletingLastPathComponent().appendingPathComponent(
      "." + url.lastPathComponent + ".notecraft")
  }

  public func validateName(_ name: String) throws -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."),
      value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\n\r")) == nil
    else { throw VaultOperationError.invalidName }
    return value
  }

  // Coordinate the primary file and its adjacent editable annotation data together. Roll back
  // the primary operation if the sidecar cannot follow it; never replace a destination.
  public func transfer(_ source: URL, to destination: URL, in root: URL, copy: Bool = false) throws
  {
    try check(source, in: root)
    try check(destination, in: root)
    let origin = source.standardizedFileURL
    let target = destination.standardizedFileURL
    guard origin != target, !target.path.hasPrefix(origin.path + "/") else {
      throw VaultOperationError.invalidDestination
    }
    let sourceSidecar = sidecar(for: origin)
    let targetSidecar = sidecar(for: target)
    var coordinationError: NSError?
    var outcome: Result<Void, Error>?
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(
      writingItemAt: origin, options: copy ? [] : .forMoving,
      writingItemAt: target, options: [], error: &coordinationError
    ) { from, to in
      func perform(_ sideFrom: URL, _ sideTo: URL) -> Result<Void, Error> {
        Result {
          let manager = FileManager.default
          guard !manager.fileExists(atPath: to.path),
            !manager.fileExists(atPath: targetSidecar.path)
          else { throw VaultOperationError.destinationExists }
          let hasSidecar =
            manager.fileExists(atPath: sideFrom.path)
          if copy {
            try manager.copyItem(at: from, to: to)
          } else {
            try manager.moveItem(at: from, to: to)
          }
          do {
            if hasSidecar {
              if copy {
                try manager.copyItem(at: sideFrom, to: sideTo)
              } else {
                try manager.moveItem(at: sideFrom, to: sideTo)
              }
            }
          } catch {
            if copy {
              try manager.removeItem(at: to)
            } else {
              try manager.moveItem(at: to, to: from)
            }
            throw error
          }
        }
      }
      if !copy { coordinator.item(at: from, willMoveTo: to) }
      if FileManager.default.fileExists(atPath: sourceSidecar.path) {
        var sideError: NSError?
        let sideCoordinator = NSFileCoordinator()
        sideCoordinator.coordinate(
          writingItemAt: sourceSidecar, options: copy ? [] : .forMoving,
          writingItemAt: targetSidecar, options: [], error: &sideError
        ) { a, b in
          if !copy { sideCoordinator.item(at: a, willMoveTo: b) }
          outcome = perform(a, b)
          if !copy, case .success? = outcome { sideCoordinator.item(at: a, didMoveTo: b) }
        }
        if let sideError { outcome = .failure(sideError) }
      } else {
        outcome = perform(sourceSidecar, targetSidecar)
      }
      if !copy, case .success? = outcome { coordinator.item(at: from, didMoveTo: to) }
    }
    if let coordinationError { throw coordinationError }
    guard let outcome else { throw PackageError.invalidPackage }
    try outcome.get()
  }

  public func trash(_ source: URL, in root: URL, favorites: [String] = []) throws -> TrashItem {
    try check(source, in: root)
    let path = String(
      source.vaultPath.dropFirst(root.vaultPath.count + 1))
    let preserved = favorites.filter {
      $0 == source.vaultPath || $0.hasPrefix(source.vaultPath + "/")
    }
    .map { String($0.dropFirst(root.vaultPath.count + 1)) }
    let item = TrashItem(id: UUID(), originalPath: path, deleted: Date(), favoritePaths: preserved)
    let directory = trashDirectory(root).appendingPathComponent(
      item.id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      try JSONEncoder().encode(item).write(
        to: directory.appendingPathComponent("info.json"), options: .atomic)
      try transfer(source, to: directory.appendingPathComponent(item.name), in: root)
    } catch {
      // Keep recoverable payloads even if a provider also rejects rollback.
      if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(item.name).path) {
        try? FileManager.default.removeItem(at: directory)
      }
      throw error
    }
    return item
  }

  public func trashItems(in root: URL) throws -> [TrashItem] {
    let directory = trashDirectory(root)
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .compactMap { url in
      guard let data = try? Data(contentsOf: url.appendingPathComponent("info.json")),
        let item = try? JSONDecoder().decode(TrashItem.self, from: data),
        url.lastPathComponent == item.id.uuidString,
        FileManager.default.fileExists(atPath: url.appendingPathComponent(item.name).path)
      else { return nil }
      return item
    }.sorted { $0.deleted > $1.deleted }
  }

  public func restore(_ item: TrashItem, in root: URL) throws -> URL {
    let destination = root.appendingPathComponent(item.originalPath)
    try check(destination, in: root)
    let directory = trashDirectory(root).appendingPathComponent(item.id.uuidString)
    let stored = try JSONDecoder().decode(
      TrashItem.self, from: Data(contentsOf: directory.appendingPathComponent("info.json")))
    guard stored.originalPath == item.originalPath else { throw PackageError.invalidPackage }
    // Check collisions before creating a missing original parent folder.
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw VaultOperationError.destinationExists
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try transfer(directory.appendingPathComponent(item.name), to: destination, in: root)
    try? FileManager.default.removeItem(at: directory)
    return destination
  }

  public func permanentlyDelete(_ item: TrashItem, in root: URL) throws {
    let directory = trashDirectory(root).appendingPathComponent(item.id.uuidString)
    try check(directory, in: root)
    var error: NSError?
    var outcome: Result<Void, Error>?
    NSFileCoordinator().coordinate(writingItemAt: directory, options: .forDeleting, error: &error) {
      url in
      outcome = Result { try FileManager.default.removeItem(at: url) }
    }
    if let error { throw error }
    try outcome?.get()
  }

  private func trashDirectory(_ root: URL) -> URL {
    root.appendingPathComponent(".notecraft-trash", isDirectory: true)
  }
  private func check(_ url: URL, in root: URL) throws {
    let base = root.vaultPath
    let path = url.vaultPath
    guard path.hasPrefix(base + "/") else { throw VaultOperationError.invalidDestination }
  }
}

public enum VaultOperationError: LocalizedError {
  case invalidName, invalidDestination, destinationExists
  public var errorDescription: String? {
    switch self {
    case .invalidName: return "Enter a name without slashes, colons or a leading dot."
    case .invalidDestination: return "Choose a different folder inside your storage folder."
    case .destinationExists: return "An item with this name already exists. Nothing was replaced."
    }
  }
}

// Directory URLs may carry a trailing slash; file-provider listings and newly created
// package URLs must still identify the same document.
extension URL {
  public var vaultPath: String {
    var current = standardizedFileURL
    var suffix: [String] = []
    while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
      suffix.insert(current.lastPathComponent, at: 0)
      current = current.deletingLastPathComponent()
    }
    current = current.resolvingSymlinksInPath()
    for component in suffix { current.appendPathComponent(component) }
    let path = current.path
    return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
  }
}
