import Foundation
import ImageIO
import NoteCraftCore
import Observation
import PDFKit

struct SavedStorage: Codable, Identifiable {
  let id: UUID
  var name: String
  var path: String
  var bookmark: Data
}
private struct ReadingPosition: Codable {
  var pageID: UUID
  var index: Int
}

struct WorkspaceTab: Identifiable {
  let id: UUID
  var title: String
  var selected: Bool
}
@MainActor @Observable final class EditHistory {
  var undo: [NotebookPackage] = []
  var redo: [NotebookPackage] = []
}

@MainActor @Observable final class VaultSession: Identifiable {
  let id = UUID()
  let history = EditHistory()
  var url: URL
  let entryKind: VaultEntryKind
  var document: NoteDocument
  var markdown: String = ""
  var dirty = false
  var status = "Saved"
  var saving = false
  var stamp: FileStamp?
  var currentPageIndex = 0
  var savedRevision: UInt64
  var sidecarURL: URL?
  var diskSidecarRevision: UInt64?
  var generation: UInt64 = 0
  var lastSavedGeneration: UInt64 = 0
  var lastFailure: String?
  @ObservationIgnored var saveTask: Task<Void, Never>?
  init(url: URL, kind: VaultEntryKind, package: NotebookPackage, stamp: FileStamp? = nil) {
    self.url = url
    self.entryKind = kind
    self.document = NoteDocument(package: package)
    self.stamp = stamp
    self.savedRevision = package.notebook.revision
  }
  var title: String {
    entryKind == .markdown
      ? url.deletingPathExtension().lastPathComponent : document.package.notebook.title
  }
}

@MainActor @Observable final class VaultController {
  var root: URL?
  var folder: URL?
  var entries: [VaultEntry] = []
  var sessions: [VaultSession] = []
  var activeID: UUID?
  var error: String?
  var busy = false
  var showLibrary = true
  var favorites: Set<String> = []
  var favoriteEntries: [VaultEntry] = []
  var trashItems: [TrashItem] = []
  var lockedPDF: VaultEntry?
  @ObservationIgnored var managing = false
  @ObservationIgnored private let preferences: UserDefaults
  var storages: [SavedStorage] = []
  var activeStorageID: UUID?
  @ObservationIgnored private var restoredStorage = false
  init(preferences: UserDefaults = .standard) {
    self.preferences = preferences
    if let data = preferences.data(forKey: "savedStorages") {
      storages = (try? JSONDecoder().decode([SavedStorage].self, from: data)) ?? []
    }
    activeStorageID = preferences.string(forKey: "activeStorageID").flatMap(UUID.init(uuidString:))
  }
  @ObservationIgnored let files = VaultFiles()
  @ObservationIgnored let packages = PackageStore()
  @ObservationIgnored private var listGeneration = 0
  var active: VaultSession? { sessions.first { $0.id == activeID } }
  var tabs: [WorkspaceTab] {
    sessions.map { WorkspaceTab(id: $0.id, title: $0.title, selected: $0.id == activeID) }
  }
  func choose(_ url: URL, storageID: UUID? = nil) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    for session in sessions {
      rememberPage(session, index: session.currentPageIndex)
      session.saveTask?.cancel()
      while session.saving { try? await Task.sleep(for: .milliseconds(20)) }
      await save(session)
    }
    guard !sessions.contains(where: \.dirty) else {
      error = "Unable to switch storage until open changes are saved."
      return
    }
    let scoped = url.startAccessingSecurityScopedResource()
    do {
      // Validate the new location before releasing the current folder's access.
      _ = try await files.list(url)
      let bookmark = try url.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      let existing = storages.firstIndex { $0.id == storageID || $0.path == url.vaultPath }
      let storage = SavedStorage(
        id: existing.map { storages[$0].id } ?? UUID(),
        name: url.lastPathComponent, path: url.vaultPath, bookmark: bookmark)
      if let existing { storages[existing] = storage } else { storages.append(storage) }
      if let root { root.stopAccessingSecurityScopedResource() }
      root = url
      folder = url
      activeStorageID = storage.id
      preferences.set(try JSONEncoder().encode(storages), forKey: "savedStorages")
      preferences.set(storage.id.uuidString, forKey: "activeStorageID")
      preferences.set(bookmark, forKey: "vaultBookmark")
      sessions = []
      activeID = nil
      showLibrary = true
      favorites = Set(
        (preferences.stringArray(forKey: favoritesKey) ?? []).map {
          URL(fileURLWithPath: $0).vaultPath
        })
      favoriteEntries = []
      entries = []
      trashItems = []
      error = nil
      await refresh()
    } catch {
      if scoped { url.stopAccessingSecurityScopedResource() }
      self.error = error.localizedDescription
    }
  }
  private func resolveBookmark(_ data: Data) throws -> URL {
    var stale = false
    return try URL(
      resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
  }
  func selectStorage(_ storage: SavedStorage) async {
    do { await choose(try resolveBookmark(storage.bookmark), storageID: storage.id) } catch {
      self.error =
        "Unable to open \(storage.name). Re-add the folder to restore access. \(error.localizedDescription)"
    }
  }
  func restoreLastStorage() async {
    guard !restoredStorage else { return }
    restoredStorage = true
    if let storage = storages.first(where: { $0.id == activeStorageID }) ?? storages.first {
      await selectStorage(storage)
    } else if let previous = previousFolder() {
      await choose(previous)
    }
  }
  func previousFolder() -> URL? {
    guard let data = preferences.data(forKey: "vaultBookmark") else { return nil }
    return try? resolveBookmark(data)
  }
  private var readingPositions: [String: ReadingPosition] {
    get {
      guard let data = preferences.data(forKey: "readingPositions") else { return [:] }
      return (try? JSONDecoder().decode([String: ReadingPosition].self, from: data)) ?? [:]
    }
    set { preferences.set(try? JSONEncoder().encode(newValue), forKey: "readingPositions") }
  }
  func rememberPage(_ session: VaultSession, index: Int) {
    guard session.entryKind != .markdown && session.entryKind != .image,
      !session.document.package.notebook.pages.isEmpty
    else { return }
    let pages = session.document.package.notebook.pages
    let index = min(max(0, index), pages.count - 1)
    session.currentPageIndex = index
    var positions = readingPositions
    positions[session.url.vaultPath] = ReadingPosition(pageID: pages[index].id, index: index)
    readingPositions = positions
  }
  func relocateReadingPositions(_ source: URL, to destination: URL, copy: Bool = false) {
    var positions = readingPositions
    for (path, position) in positions
    where path == source.vaultPath || path.hasPrefix(source.vaultPath + "/") {
      let suffix = String(path.dropFirst(source.vaultPath.count))
      positions[destination.vaultPath + suffix] = position
      if !copy { positions.removeValue(forKey: path) }
    }
    readingPositions = positions
  }
  private var favoritesKey: String { "favorites." + (root?.absoluteString ?? "") }
  func persistFavorites() { preferences.set(Array(favorites), forKey: favoritesKey) }
  func favorite(_ entry: VaultEntry) {
    if favorites.contains(entry.url.vaultPath) {
      favorites.remove(entry.url.vaultPath)
    } else {
      favorites.insert(entry.url.vaultPath)
    }
    preferences.set(Array(favorites), forKey: favoritesKey)
    Task { await refreshFavorites() }
  }
  func refreshFavorites() async {
    let requested = favorites
    let parents = Set(requested.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
    var result: [VaultEntry] = []
    for parent in parents {
      if let entries = try? await files.list(parent) {
        result += entries.filter { requested.contains($0.url.vaultPath) }
      }
    }
    if requested == favorites {
      favoriteEntries = result.sorted {
        $0.title.localizedStandardCompare($1.title) == .orderedAscending
      }
    }
  }
  func refresh() async {
    guard let folder else { return }
    listGeneration += 1
    let token = listGeneration
    do {
      let result = try await files.list(folder)
      if token == listGeneration { entries = result }
      await refreshFavorites()
      if let root { trashItems = try await files.trashItems(in: root) }
    } catch { self.error = error.localizedDescription }
  }
  func navigate(_ url: URL) async {
    folder = url
    await refresh()
  }
  func open(_ entry: VaultEntry) async {
    if entry.kind == .folder {
      await navigate(entry.url)
      return
    }
    if let existing = sessions.first(where: { $0.url.vaultPath == entry.url.vaultPath }) {
      activeID = existing.id
      showLibrary = false
      return
    }
    busy = true
    defer { busy = false }
    do {
      let session: VaultSession
      switch entry.kind {
      case .notebook, .whiteboard:
        session = VaultSession(
          url: entry.url, kind: entry.kind, package: try await packages.read(from: entry.url))
      case .pdf:
        let snapshot = try await files.read(entry.url)
        let sidecar = entry.url.deletingLastPathComponent().appendingPathComponent(
          "." + entry.url.lastPathComponent + ".notecraft")
        let cached = try? await packages.read(from: sidecar)
        // The PDF digest prevents a stale editable sidecar from masking edits made by another application.
        let useCache = cached?.assets["source.sha256"] == snapshot.stamp.digest
        let package: NotebookPackage
        if useCache, let cached {
          package = cached
        } else {
          package = try await ImportEngine().pdf(entry.url)
        }
        var namedPackage = package
        namedPackage.notebook.title = entry.title
        session = VaultSession(
          url: entry.url, kind: .pdf, package: namedPackage, stamp: snapshot.stamp)
        session.sidecarURL = sidecar
        session.diskSidecarRevision = cached?.notebook.revision
      case .markdown:
        let snapshot = try await files.read(entry.url)
        guard let text = String(data: snapshot.data, encoding: .utf8) else {
          throw PackageError.invalidPackage
        }
        session = VaultSession(
          url: entry.url, kind: .markdown, package: NotebookPackage(), stamp: snapshot.stamp)
        session.markdown = text
      case .image:
        let snapshot = try await files.read(entry.url)
        let name = entry.url.lastPathComponent
        var page = Page(paper: Paper(pattern: .blank))
        guard let image = CGImageSourceCreateWithData(snapshot.data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
          let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? Double,
          let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? Double,
          pixelWidth > 0, pixelHeight > 0
        else { throw PackageError.invalidPackage }
        let scale = min(1, 1000 / max(pixelWidth, pixelHeight))
        let size = Point(pixelWidth * scale, pixelHeight * scale)
        page.backgroundSize = Point(size.x + 60, size.y + 60)
        page.images = [
          PageAsset(filename: name, frame: Rect(x: 30, y: 30, width: size.x, height: size.y))
        ]
        session = VaultSession(
          url: entry.url, kind: .image,
          package: NotebookPackage(
            notebook: Notebook(title: entry.title, pages: [page]), assets: [name: snapshot.data]),
          stamp: snapshot.stamp)
      default:
        error = "This file type can be browsed, but is not editable in NotesCraft."
        return
      }
      if let position = readingPositions[session.url.vaultPath] {
        let pages = session.document.package.notebook.pages
        session.currentPageIndex =
          pages.firstIndex(where: { $0.id == position.pageID })
          ?? min(max(0, position.index), max(0, pages.count - 1))
      }
      sessions.append(session)
      activeID = session.id
      showLibrary = false
    } catch PackageError.lockedPDF {
      lockedPDF = entry
    } catch { self.error = error.localizedDescription }
  }
  func importImageNotebook(_ session: VaultSession) async {
    guard session.entryKind == .image, !busy else { return }
    busy = true
    let destination = await files.availableURL(
      in: session.url.deletingLastPathComponent(),
      title: session.title, extension: "notecraft")
    do {
      var package = session.document.package
      // Existing annotation data remains recoverable by importing it into a notebook.
      let sidecar = await files.sidecar(for: session.url)
      if let previous = try? await packages.read(from: sidecar),
        previous.assets["source.sha256"] == session.stamp?.digest
      {
        package = previous
      }
      package.notebook.id = UUID()
      package.notebook.title = session.title
      package.assets.removeValue(forKey: "source.sha256")
      try await packages.save(package, to: destination, createOnly: true)
      await refresh()
      busy = false
      await open(
        VaultEntry(url: destination, kind: .notebook, title: session.title, modified: Date()))
    } catch {
      busy = false
      self.error = error.localizedDescription
    }
  }
  func changed(_ session: VaultSession) {
    guard session.entryKind != .image else { return }
    session.generation += 1
    session.dirty = true
    session.status = "Unsaved changes"
    session.saveTask?.cancel()
    session.saveTask = Task {
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      await save(session)
    }
  }
  func save(_ session: VaultSession) async {
    guard session.entryKind != .image, session.dirty, !session.saving, !managing else { return }
    session.saving = true
    session.status = "Saving…"
    let generation = session.generation
    if session.entryKind != .markdown {
      // Applied to the live document too, so the broken reference stops resurfacing.
      var repaired = session.document.package
      if !repaired.pruneMissingAssets().isEmpty { session.document.package = repaired }
    }
    let snapshot = session.document.package
    do {
      switch session.entryKind {
      case .markdown:
        session.stamp = try await files.write(
          Data(session.markdown.utf8), to: session.url, expected: session.stamp)
      case .pdf:
        let pdf = try await DocumentRenderWorker.shared.exportPDF(snapshot)
        session.stamp = try await files.write(pdf, to: session.url, expected: session.stamp)
        if let sidecar = session.sidecarURL {
          var editable = snapshot
          editable.assets["source.sha256"] = session.stamp!.digest
          try await packages.save(
            editable, to: sidecar, expectedRevision: session.diskSidecarRevision)
          session.diskSidecarRevision = editable.notebook.revision
        }
      default:
        try await packages.save(snapshot, to: session.url, expectedRevision: session.savedRevision)
      }
      session.lastFailure = nil
      session.savedRevision = snapshot.notebook.revision
      session.lastSavedGeneration = generation
      session.dirty = session.generation != generation
      session.status = session.dirty ? "Unsaved changes" : "Saved"
    } catch {
      session.status = "Save failed"
      // Every later edit retries the save; one dialog per distinct failure is enough.
      if session.lastFailure != error.localizedDescription { self.error = error.localizedDescription }
      session.lastFailure = error.localizedDescription
    }
    session.saving = false
    if session.dirty && session.generation != generation && session.lastFailure == nil {
      await save(session)
    }
  }
  func saveCopy(_ session: VaultSession) async {
    let ext = session.entryKind == .markdown ? session.url.pathExtension : "notecraft"
    let destination = await files.availableURL(
      in: session.url.deletingLastPathComponent(), title: session.title + " copy", extension: ext)
    do {
      if session.entryKind == .markdown {
        try await files.write(
          Data(session.markdown.utf8), to: destination, expected: nil, createOnly: true)
      } else {
        try await packages.save(session.document.package, to: destination)
      }
      session.saveTask?.cancel()
      sessions.removeAll { $0.id == session.id }
      await refresh()
      let candidates = try await files.list(destination.deletingLastPathComponent())
      if let copy = candidates.first(where: {
        $0.url.standardizedFileURL.path == destination.standardizedFileURL.path
      }) {
        await open(copy)
      }
    } catch { self.error = error.localizedDescription }
  }
  func library() async {
    let previous = active
    if let previous {
      rememberPage(previous, index: previous.currentPageIndex)
    }
    showLibrary = true
    if let previous { await save(previous) }
    await refresh()
  }
  func selectTab(_ id: UUID) async {
    let previous = active
    if let previous {
      rememberPage(previous, index: previous.currentPageIndex)
    }
    activeID = id
    showLibrary = false
    if let previous { await save(previous) }
  }
  func create(title: String, paper: Paper, whiteboard: Bool = false) async {
    guard let folder else { return }
    var notebook = Notebook(title: title, pages: [Page(paper: paper)])
    #if DEBUG
      if !whiteboard && CommandLine.arguments.contains("--ui-test-large-notebook") {
        notebook.pages = (0..<300).map { _ in Page(paper: paper) }
      }
    #endif
    notebook.kind = whiteboard ? .whiteboard : .notebook
    if whiteboard { notebook.pages[0].backgroundSize = Point(2000, 2000) }
    let url = await files.availableURL(in: folder, title: title, extension: "notecraft")
    do {
      try await packages.save(NotebookPackage(notebook: notebook), to: url)
      await refresh()
      if let entry = entries.first(where: {
        $0.url.standardizedFileURL.path == url.standardizedFileURL.path
      }) {
        await open(entry)
      }
    } catch { self.error = error.localizedDescription }
  }
  func createText(title: String) async {
    guard let folder else { return }
    let url = await files.availableURL(in: folder, title: title, extension: "md")
    do {
      try await files.write(Data("# \(title)\n\n".utf8), to: url, expected: nil, createOnly: true)
      await refresh()
      if let entry = entries.first(where: {
        $0.url.standardizedFileURL.path == url.standardizedFileURL.path
      }) {
        await open(entry)
      }
    } catch { self.error = error.localizedDescription }
  }
  func createFolder(title: String) async {
    guard let folder else { return }
    do {
      try await files.createFolder(in: folder, name: title)
      await refresh()
    } catch { self.error = error.localizedDescription }
  }
}
