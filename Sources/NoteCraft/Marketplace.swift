import CoreGraphics
import Foundation
import ImageIO
import NoteCraftCore
import Observation

// The marketplace: a free catalog of themes, stickers, page templates and planners. See
// docs/MARKETPLACE.md. This file is everything that is not drawn: where the catalog comes from, what
// is installed and how a pack is installed and taken away again.

enum MarketplaceError: LocalizedError, Equatable {
  case badAddress
  case unreachable
  case server(Int)
  case tooLarge
  case notFound(String)

  var errorDescription: String? {
    switch self {
    case .badAddress: "The catalog address has to start with https://."
    case .unreachable: "The catalog could not be reached. Check your connection and try again."
    case .server(let code): "The catalog answered with an error (\(code))."
    case .tooLarge: "The download is larger than the catalog said it would be."
    case .notFound(let what): "“\(what)” is not here any more."
    }
  }
}

// MARK: where the catalog is

// A folder of files with an `index.json` in it: the packs and previews are paths inside it.
protocol CatalogSource: Sendable {
  func fetch(_ path: String, maxBytes: Int) async throws -> Data
}

// The catalog on disk: the one that comes with the app, and the one tests read.
struct FolderCatalogSource: CatalogSource {
  let root: URL
  func fetch(_ path: String, maxBytes: Int) async throws -> Data {
    try ZipArchive.validate(path: path)
    let url = root.appendingPathComponent(path)
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
      throw MarketplaceError.notFound(path)
    }
    guard size <= maxBytes else { throw MarketplaceError.tooLarge }
    return try Data(contentsOf: url)
  }
}

// The catalog on a web server, over https only.
struct WebCatalogSource: CatalogSource {
  let base: URL

  init?(address: String) {
    var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.hasSuffix("/") { text += "/" }
    guard let url = URL(string: text), url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else { return nil }
    base = url
  }

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 120
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
  }()

  func fetch(_ path: String, maxBytes: Int) async throws -> Data {
    try ZipArchive.validate(path: path)
    var request = URLRequest(url: base.appendingPathComponent(path))
    request.setValue("NotesCraft", forHTTPHeaderField: "User-Agent")
    do {
      let (stream, response) = try await Self.session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else { throw MarketplaceError.unreachable }
      guard http.statusCode == 200 else {
        throw http.statusCode == 404 ? MarketplaceError.notFound(path) : MarketplaceError.server(http.statusCode)
      }
      // A server that says it is sending more than it should is not listened to; one that says
      // nothing is cut off at the limit.
      if response.expectedContentLength > Int64(maxBytes) { throw MarketplaceError.tooLarge }
      var data = Data()
      data.reserveCapacity(max(0, min(maxBytes, Int(response.expectedContentLength))))
      for try await byte in stream {
        data.append(byte)
        if data.count > maxBytes { throw MarketplaceError.tooLarge }
      }
      return data
    } catch let error as MarketplaceError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw MarketplaceError.unreachable
    }
  }
}

// MARK: what is installed

struct InstalledPack: Codable, Identifiable, Equatable {
  var entry: CatalogEntry
  var installedAt: Date
  // For stickers: which of the elements of the library came from this pack.
  var clipIDs: [UUID] = []
  var id: String { entry.id }
}

// MARK: the store

@MainActor @Observable final class MarketplaceStore {
  static let shared = MarketplaceStore()
  static let defaultAddress = "https://raw.githubusercontent.com/JanSirPROXx/NotesCraft/main/catalog/"
  nonisolated static let maxPreviewBytes = 300 * 1024

  enum Status: Equatable {
    case idle
    case loading
    case failed(String)
  }

  // What the marketplace shows: the last catalog that was downloaded, or the one in the app.
  private(set) var index: CatalogIndex
  private(set) var status = Status.idle
  // When the index was downloaded last; nil while only the catalog of the app has been seen.
  private(set) var updated: Date?
  private(set) var installed: [InstalledPack] = []
  private(set) var saved: Set<String> = []
  private(set) var working: Set<String> = []
  private(set) var address: String

  @ObservationIgnored private let directory: URL
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let bundled: (any CatalogSource)?
  @ObservationIgnored private let bundledIndex: CatalogIndex?
  @ObservationIgnored private let makeRemote: (String) -> (any CatalogSource)?
  @ObservationIgnored private let themes: ThemeStore
  @ObservationIgnored private let elements: ElementLibrary
  @ObservationIgnored private var previews: [String: CGImage] = [:]

  private enum Key {
    static let address = "marketplaceAddress"
  }

  init(
    directory: URL? = nil, defaults: UserDefaults = .standard,
    bundled: (any CatalogSource)? = MarketplaceStore.bundledSource(),
    makeRemote: @escaping (String) -> (any CatalogSource)? = { WebCatalogSource(address: $0) },
    themes: ThemeStore? = nil, elements: ElementLibrary? = nil
  ) {
    let directory =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("NotesCraft/Marketplace", isDirectory: true)
    self.directory = directory
    self.defaults = defaults
    self.bundled = bundled
    self.makeRemote = makeRemote
    self.themes = themes ?? .shared
    self.elements = elements ?? .shared
    address = defaults.string(forKey: Key.address) ?? Self.defaultAddress
    let bundledIndex = (bundled as? FolderCatalogSource).flatMap { Self.readIndex(at: $0.root) }
    self.bundledIndex = bundledIndex
    let catalogFolder = directory.appendingPathComponent("Catalog", isDirectory: true)
    let cached = Self.readIndex(at: catalogFolder)
    index = cached ?? bundledIndex ?? CatalogIndex(updated: "", packs: [])
    updated =
      cached == nil
      ? nil
      : (try? catalogFolder.appendingPathComponent("index.json")
        .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    installed = Self.load([InstalledPack].self, from: directory.appendingPathComponent("installed.json")) ?? []
    saved = Set(Self.load([String].self, from: directory.appendingPathComponent("saved.json")) ?? [])
    #if DEBUG
      if CommandLine.arguments.contains("--ui-test-reset-marketplace") { reset() }
    #endif
  }

  static func bundledSource() -> (any CatalogSource)? {
    #if DEBUG
      if let path = ProcessInfo.processInfo.environment["NOTECRAFT_CATALOG_FOLDER"] {
        return FolderCatalogSource(root: URL(fileURLWithPath: path))
      }
    #endif
    return Bundle.main.url(forResource: "catalog", withExtension: nil).map { FolderCatalogSource(root: $0) }
  }

  // A catalog that is only the one of the app: tests do not go to the network.
  static var usesNetwork: Bool {
    #if DEBUG
      return !CommandLine.arguments.contains("--ui-test-offline-catalog")
    #else
      return true
    #endif
  }

  // MARK: files

  private var installedFile: URL { directory.appendingPathComponent("installed.json") }
  private var savedFile: URL { directory.appendingPathComponent("saved.json") }
  private var indexFile: URL {
    directory.appendingPathComponent("Catalog", isDirectory: true).appendingPathComponent("index.json")
  }
  private var templatesDirectory: URL { directory.appendingPathComponent("Templates", isDirectory: true) }
  private var previewsDirectory: URL { directory.appendingPathComponent("Previews", isDirectory: true) }

  private static func readIndex(at folder: URL) -> CatalogIndex? {
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")) else { return nil }
    return try? CatalogIndex.parse(data)
  }

  private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(type, from: data)
  }

  private func persist<T: Encodable>(_ value: T, to url: URL) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
  }

  // MARK: the catalog

  var canRefresh: Bool { Self.usesNetwork && makeRemote(address) != nil }

  // Fetches the index again. What was shown stays when it cannot be reached.
  func refresh() async {
    guard Self.usesNetwork else { return }
    guard let remote = makeRemote(address) else {
      status = .failed(MarketplaceError.badAddress.localizedDescription)
      return
    }
    guard status != .loading else { return }
    status = .loading
    do {
      let data = try await remote.fetch("index.json", maxBytes: CatalogIndex.maxBytes)
      let fetched = try CatalogIndex.parse(data)
      let folder = indexFile.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try data.write(to: indexFile, options: .atomic)
      index = fetched
      updated = Date()
      status = .idle
    } catch is CancellationError {
      status = .idle
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  // Where the catalog is looked for. An empty address is the default one.
  func setAddress(_ new: String) throws {
    let text = new.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty || text == Self.defaultAddress {
      defaults.removeObject(forKey: Key.address)
      address = Self.defaultAddress
    } else {
      guard WebCatalogSource(address: text) != nil else { throw MarketplaceError.badAddress }
      defaults.set(text, forKey: Key.address)
      address = text
    }
    // What was downloaded was from the other address.
    try? FileManager.default.removeItem(at: indexFile.deletingLastPathComponent())
    index = bundledIndex ?? CatalogIndex(updated: "", packs: [])
    updated = nil
    status = .idle
  }

  func entry(_ id: String) -> CatalogEntry? { index.packs.first { $0.id == id } }

  // MARK: previews

  func preview(for entry: CatalogEntry) async -> CGImage? {
    guard let path = entry.preview else { return nil }
    if let image = previews[entry.sha256] { return image }
    var data: Data?
    if let bundled, let same = bundledIndex?.packs.first(where: { $0.id == entry.id && $0.sha256 == entry.sha256 }),
      let bundledPath = same.preview
    {
      data = try? await bundled.fetch(bundledPath, maxBytes: Self.maxPreviewBytes)
    }
    let cacheFile = previewsDirectory.appendingPathComponent(entry.sha256 + ".png")
    if data == nil { data = try? Data(contentsOf: cacheFile) }
    if data == nil, Self.usesNetwork, let remote = makeRemote(address) {
      data = try? await remote.fetch(path, maxBytes: Self.maxPreviewBytes)
      if let data, Self.decodePreview(data) != nil {
        try? FileManager.default.createDirectory(at: previewsDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile, options: .atomic)
      }
    }
    guard let data, let image = Self.decodePreview(data) else { return nil }
    previews[entry.sha256] = image
    return image
  }

  // A preview comes from the internet and is not covered by the hash of the pack: it is read at a
  // bounded size, whatever dimensions it says it has.
  nonisolated static func decodePreview(_ data: Data) -> CGImage? {
    guard data.count <= maxPreviewBytes,
      let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      (1...4000).contains(width), (1...4000).contains(height)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 840,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  // MARK: saved

  func isSaved(_ id: String) -> Bool { saved.contains(id) }

  func toggleSaved(_ id: String) {
    if saved.contains(id) { saved.remove(id) } else { saved.insert(id) }
    persist(saved.sorted(), to: savedFile)
  }

  // MARK: installed

  func installedPack(_ id: String) -> InstalledPack? { installed.first { $0.id == id } }
  func isInstalled(_ id: String) -> Bool { installedPack(id) != nil }

  // An installed pack whose entry in the catalog has another version.
  func hasUpdate(_ id: String) -> Bool {
    guard let have = installedPack(id), let now = entry(id) else { return false }
    return now.version != have.entry.version
  }

  var templates: [InstalledPack] {
    installed.filter { $0.entry.kind == .template }.sorted {
      $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending
    }
  }

  // The notebook of an installed template or planner.
  func notebook(of id: String) throws -> NotebookPackage {
    guard let pack = installedPack(id), pack.entry.kind == .template || pack.entry.kind == .planner else {
      throw MarketplaceError.notFound(id)
    }
    let url = templatesDirectory.appendingPathComponent(id + ".notecraft")
    guard let wrapper = try? FileWrapper(url: url, options: .immediate) else {
      throw MarketplaceError.notFound(pack.entry.name)
    }
    return try NotebookPackage(fileWrapper: wrapper)
  }

  // A planner (or a template) as a new notebook of its own.
  func newNotebook(from id: String) throws -> NotebookPackage {
    guard let pack = installedPack(id) else { throw MarketplaceError.notFound(id) }
    return try notebook(of: id).asNewNotebook(title: pack.entry.name)
  }

  // MARK: installing

  // Which copy of a pack to use: the one in the app if it is the same file, else the web.
  private func source(for entry: CatalogEntry) -> (source: any CatalogSource, path: String)? {
    if let bundled, let same = bundledIndex?.packs.first(where: { $0.id == entry.id && $0.sha256 == entry.sha256 }) {
      return (bundled, same.file)
    }
    guard Self.usesNetwork, let remote = makeRemote(address) else { return nil }
    return (remote, entry.file)
  }

  func install(_ entry: CatalogEntry) async throws {
    guard !working.contains(entry.id) else { return }
    working.insert(entry.id)
    defer { working.remove(entry.id) }
    try entry.validate()
    guard let (source, path) = source(for: entry) else { throw MarketplaceError.unreachable }
    let data = try await source.fetch(path, maxBytes: entry.size)
    // Unzipping and hashing up to 25 MB is not done on the main thread.
    let pack = try await Task.detached(priority: .userInitiated) {
      try Pack.open(data, expecting: entry)
    }.value

    let previous = installedPack(entry.id)
    var record = InstalledPack(entry: entry, installedAt: Date())
    switch entry.kind {
    case .theme:
      let staging = FileManager.default.temporaryDirectory
        .appendingPathComponent("theme-" + UUID().uuidString, isDirectory: true)
      defer { try? FileManager.default.removeItem(at: staging) }
      let package = staging.appendingPathComponent(entry.id + ".notecrafttheme", isDirectory: true)
      _ = try pack.theme(writingTo: package)
      _ = try themes.install(from: package)
    case .sticker:
      // Fresh identities: the same pack installed again, or by someone else, never collides.
      let clips = try pack.stickers().map { clip -> ElementClip in
        var copy = clip
        copy.id = UUID()
        return copy
      }
      try elements.add(contentsOf: clips)
      record.clipIDs = clips.map(\.id)
      if let old = previous?.clipIDs, !old.isEmpty { try? elements.remove(ids: Set(old)) }
    case .template, .planner:
      let notebook = try pack.notebook()
      try FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
      let url = templatesDirectory.appendingPathComponent(entry.id + ".notecraft")
      try notebook.fileWrapper().write(to: url, options: .atomic, originalContentsURL: nil)
    }
    installed.removeAll { $0.id == entry.id }
    installed.append(record)
    persist(installed, to: installedFile)
  }

  // Takes away what the pack added. What was made with it stays: notebooks started from a planner,
  // pages added from a template, stickers already on a page.
  func uninstall(_ id: String) {
    guard let pack = installedPack(id) else { return }
    removeArtifacts(of: pack)
    installed.removeAll { $0.id == id }
    persist(installed, to: installedFile)
  }

  private func removeArtifacts(of pack: InstalledPack) {
    switch pack.entry.kind {
    case .theme: themes.remove(pack.entry.id)
    case .sticker: try? elements.remove(ids: Set(pack.clipIDs))
    case .template, .planner:
      try? FileManager.default.removeItem(
        at: templatesDirectory.appendingPathComponent(pack.entry.id + ".notecraft"))
    }
  }

  #if DEBUG
    // A test starts from nothing: what an earlier run installed is taken away too.
    private func reset() {
      for pack in installed { removeArtifacts(of: pack) }
      try? FileManager.default.removeItem(at: directory)
      defaults.removeObject(forKey: Key.address)
      address = Self.defaultAddress
      installed = []
      saved = []
      updated = nil
      index = bundledIndex ?? CatalogIndex(updated: "", packs: [])
    }
  #endif
}
