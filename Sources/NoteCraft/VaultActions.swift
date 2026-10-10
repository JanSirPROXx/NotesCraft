import Foundation
import NoteCraftCore

extension VaultController {
  private func finishManagement() {
    busy = false
    let resume = managing
    managing = false
    guard resume else { return }
    for session in sessions where session.dirty && !session.saving {
      session.saveTask = Task { await save(session) }
    }
  }
  private func affected(by url: URL) -> [VaultSession] {
    sessions.filter {
      $0.url.vaultPath == url.vaultPath || $0.url.vaultPath.hasPrefix(url.vaultPath + "/")
    }
  }
  private func prepare(_ url: URL) async throws {
    for session in affected(by: url) {
      session.saveTask?.cancel()
      while session.saving { try await Task.sleep(for: .milliseconds(20)) }
      await save(session)
      guard !session.dirty else { throw PackageError.conflict }
    }
  }
  private func relocated(_ source: URL, to destination: URL) {
    func update(_ url: URL) -> URL {
      url.vaultPath == source.vaultPath
        ? destination
        : destination.appendingPathComponent(
          String(url.vaultPath.dropFirst(source.vaultPath.count + 1)))
    }
    for session in affected(by: source) {
      session.url = update(session.url)
      if session.entryKind == .pdf {
        session.sidecarURL = session.url.deletingLastPathComponent().appendingPathComponent(
          "." + session.url.lastPathComponent + ".notecraft")
      }
    }
    favorites = Set(
      favorites.map { path in
        path == source.vaultPath || path.hasPrefix(source.vaultPath + "/")
          ? update(URL(fileURLWithPath: path)).vaultPath : path
      })
    persistFavorites()
  }
  func rename(_ entry: VaultEntry, to name: String) async {
    guard let root, !busy else { return }
    busy = true
    defer { finishManagement() }
    do {
      let name = try await files.validateName(name)
      var destination = entry.url.deletingLastPathComponent().appendingPathComponent(name)
      if entry.kind != .folder { destination.appendPathExtension(entry.url.pathExtension) }
      if destination == entry.url && name == entry.title { return }
      try await prepare(entry.url)
      managing = true
      if destination != entry.url {
        try await files.transfer(entry.url, to: destination, in: root)
        relocated(entry.url, to: destination)
      }
      if entry.kind == .notebook || entry.kind == .whiteboard {
        var package = try await packages.read(from: destination)
        let revision = package.notebook.revision
        package.notebook.title = name
        package.notebook.revision += 1
        try await packages.save(package, to: destination, expectedRevision: revision)
        if let session = sessions.first(where: { $0.url.vaultPath == destination.vaultPath }) {
          session.document = NoteDocument(package: package)
          session.savedRevision = package.notebook.revision
          // Old snapshots keep their content but adopt the new library name on undo/redo.
          for i in session.history.undo.indices { session.history.undo[i].notebook.title = name }
          for i in session.history.redo.indices { session.history.redo[i].notebook.title = name }
        }
      } else if entry.kind == .pdf,
        let session = sessions.first(where: { $0.url.vaultPath == destination.vaultPath })
      {
        session.document.package.notebook.title = name
      }
      await refresh()
    } catch {
      self.error = error.localizedDescription
      await refresh()
    }
  }
  func move(_ entry: VaultEntry, to folder: URL) async {
    guard let root, !busy else { return }
    busy = true
    defer { finishManagement() }
    do {
      try await prepare(entry.url)
      managing = true
      let destination = folder.appendingPathComponent(entry.url.lastPathComponent)
      try await files.transfer(entry.url, to: destination, in: root)
      relocated(entry.url, to: destination)
      await refresh()
    } catch { self.error = error.localizedDescription }
  }
  func duplicate(_ entry: VaultEntry) async {
    guard let root, !busy else { return }
    busy = true
    defer { finishManagement() }
    do {
      try await prepare(entry.url)
      managing = true
      let destination = await files.availableURL(
        in: entry.url.deletingLastPathComponent(),
        title: entry.title + " copy",
        extension: entry.kind == .folder ? "" : entry.url.pathExtension)
      try await files.transfer(entry.url, to: destination, in: root, copy: true)
      if entry.kind == .notebook || entry.kind == .whiteboard {
        var package = try await packages.read(from: destination)
        let revision = package.notebook.revision
        package.notebook.id = UUID()
        package.notebook.title = destination.deletingPathExtension().lastPathComponent
        package.notebook.revision += 1
        try await packages.save(package, to: destination, expectedRevision: revision)
      }
      await refresh()
    } catch {
      self.error = error.localizedDescription
      await refresh()
    }
  }
  func trash(_ entry: VaultEntry) async {
    guard let root, !busy else { return }
    busy = true
    defer { finishManagement() }
    do {
      try await prepare(entry.url)
      managing = true
      _ = try await files.trash(entry.url, in: root, favorites: Array(favorites))
      let removed = Set(affected(by: entry.url).map(\.id))
      sessions.removeAll { removed.contains($0.id) }
      if let activeID, removed.contains(activeID) {
        self.activeID = nil
        showLibrary = true
      }
      favorites = favorites.filter {
        $0 != entry.url.vaultPath && !$0.hasPrefix(entry.url.vaultPath + "/")
      }
      persistFavorites()
      await refresh()
    } catch { self.error = error.localizedDescription }
  }
  func restore(_ item: TrashItem) async {
    guard let root, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      _ = try await files.restore(item, in: root)
      for path in item.favoritePaths ?? [] {
        let restored = root.appendingPathComponent(path).vaultPath
        if restored.hasPrefix(root.vaultPath + "/") { favorites.insert(restored) }
      }
      persistFavorites()
      await refresh()
    } catch { self.error = error.localizedDescription }
  }
  func deletePermanently(_ item: TrashItem) async {
    guard let root, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      try await files.permanentlyDelete(item, in: root)
      await refresh()
    } catch { self.error = error.localizedDescription }
  }
  func unlockCopy(_ entry: VaultEntry, password: String) async throws {
    let data = try await files.read(entry.url).data
    let unlocked = try PDFEditor.unlock(data, password: password)
    let destination = await files.availableURL(
      in: entry.url.deletingLastPathComponent(), title: entry.title + " unlocked", extension: "pdf")
    try await files.write(unlocked, to: destination, expected: nil, createOnly: true)
    lockedPDF = nil
    await refresh()
    await open(
      VaultEntry(
        url: destination, kind: .pdf, title: destination.deletingPathExtension().lastPathComponent,
        modified: Date()))
  }
}
