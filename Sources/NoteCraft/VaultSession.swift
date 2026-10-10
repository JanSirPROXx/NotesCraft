import Foundation
import ImageIO
import NoteCraftCore
import Observation
import PDFKit

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
  var savedRevision: UInt64
  var sidecarURL: URL?
  var diskSidecarRevision: UInt64?
  var generation: UInt64 = 0
  var lastSavedGeneration: UInt64 = 0
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
  init(preferences: UserDefaults = .standard) { self.preferences = preferences }
  @ObservationIgnored let files = VaultFiles()
  @ObservationIgnored let packages = PackageStore()
  @ObservationIgnored private var listGeneration = 0
  var active: VaultSession? { sessions.first { $0.id == activeID } }
  var tabs: [WorkspaceTab] {
    sessions.map { WorkspaceTab(id: $0.id, title: $0.title, selected: $0.id == activeID) }
  }
  func choose(_ url: URL) async {
    if sessions.contains(where: \.dirty) {
      error = "Save open edits before changing the storage folder."
      return
    }
    if let root { root.stopAccessingSecurityScopedResource() }
    _ = url.startAccessingSecurityScopedResource()
    root = url
    folder = url
    sessions = []
    activeID = nil
    showLibrary = true
    do {
      #if os(macOS)
        let bookmark = try url.bookmarkData(options: .withSecurityScope)
      #else
        let bookmark = try url.bookmarkData(
          options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      #endif
      preferences.set(bookmark, forKey: "vaultBookmark")
      favorites = Set(
        (preferences.stringArray(forKey: favoritesKey) ?? []).map {
          URL(fileURLWithPath: $0).vaultPath
        })
      await refresh()
    } catch { self.error = error.localizedDescription }
  }
  func previousFolder() -> URL? {
    guard let data = preferences.data(forKey: "vaultBookmark") else { return nil }
    var stale = false
    #if os(macOS)
      return try? URL(
        resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
        bookmarkDataIsStale: &stale)
    #else
      return try? URL(
        resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    #endif
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
          url: await files.availableURL(
            in: entry.url.deletingLastPathComponent(), title: entry.title, extension: "notecraft"),
          kind: .notebook,
          package: NotebookPackage(
            notebook: Notebook(title: entry.title, pages: [page]), assets: [name: snapshot.data]))
        try await packages.save(session.document.package, to: session.url)
        session.status = "Saved · imported image notebook"
      default:
        error = "This file type can be browsed, but is not editable in NoteCraft."
        return
      }
      sessions.append(session)
      activeID = session.id
      showLibrary = false
    } catch PackageError.lockedPDF {
      lockedPDF = entry
    } catch { self.error = error.localizedDescription }
  }
  func changed(_ session: VaultSession) {
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
    guard session.dirty, !session.saving, !managing, session.entryKind != .image else { return }
    session.saving = true
    session.status = "Saving…"
    let generation = session.generation
    let snapshot = session.document.package
    do {
      switch session.entryKind {
      case .markdown:
        session.stamp = try await files.write(
          Data(session.markdown.utf8), to: session.url, expected: session.stamp)
      case .pdf:
        let pdf = try PDFEditor.export(snapshot)
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
      session.savedRevision = snapshot.notebook.revision
      session.lastSavedGeneration = generation
      session.dirty = session.generation != generation
      session.status = session.dirty ? "Unsaved changes" : "Saved"
    } catch {
      session.status = "Save failed"
      self.error = error.localizedDescription
    }
    session.saving = false
    if session.dirty && session.generation != generation { await save(session) }
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
    if let active { await save(active) }
    showLibrary = true
    await refresh()
  }
  func selectTab(_ id: UUID) async {
    if let active { await save(active) }
    activeID = id
    showLibrary = false
  }
  func create(title: String, paper: Paper, whiteboard: Bool = false) async {
    guard let folder else { return }
    var notebook = Notebook(title: title, pages: [Page(paper: paper)])
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
