import Foundation
import ImageIO
import NoteCraftCore
import Testing

@testable import NoteCraft

private let repository = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let catalog = repository.appendingPathComponent("catalog")

private struct Setup {
  var store: MarketplaceStore
  var themes: ThemeStore
  var elements: ElementLibrary
  var directory: URL
  var defaults: UserDefaults
}

// A store with its own folders and preferences, reading the committed catalog as the catalog of the app.
@MainActor private func setup(
  directory: URL? = nil, bundled: (any CatalogSource)? = FolderCatalogSource(root: catalog),
  remote: (any CatalogSource)? = nil
) -> Setup {
  let suite = "marketplace-tests-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let root = directory ?? FileManager.default.temporaryDirectory
    .appendingPathComponent("marketplace-" + UUID().uuidString, isDirectory: true)
  let themes = ThemeStore(defaults: defaults, directory: root.appendingPathComponent("Themes"))
  let elements = ElementLibrary(directory: root.appendingPathComponent("Elements"), defaults: defaults)
  let store = MarketplaceStore(
    directory: root.appendingPathComponent("Marketplace"), defaults: defaults, bundled: bundled,
    makeRemote: { _ in remote }, themes: themes, elements: elements)
  return Setup(store: store, themes: themes, elements: elements, directory: root, defaults: defaults)
}

@MainActor private func entry(_ s: Setup, _ id: String) throws -> CatalogEntry {
  try #require(s.store.entry(id), "\(id) is in the catalog")
}

private struct FailingSource: CatalogSource {
  func fetch(_ path: String, maxBytes: Int) async throws -> Data { throw MarketplaceError.unreachable }
}

// A catalog in memory: what a server would send.
private struct MemorySource: CatalogSource {
  var files: [String: Data]
  func fetch(_ path: String, maxBytes: Int) async throws -> Data {
    guard let data = files[path] else { throw MarketplaceError.notFound(path) }
    guard data.count <= maxBytes else { throw MarketplaceError.tooLarge }
    return data
  }
}

@MainActor @Test func theStoreStartsWithTheCatalogOfTheApp() {
  let s = setup()
  #expect(s.store.index.packs.count == 15)
  #expect(s.store.updated == nil)
  #expect(s.store.installed.isEmpty)
  #expect(s.store.status == .idle)
}

@MainActor @Test func aThemeIsInstalledChosenAndTakenAway() async throws {
  let s = setup()
  let ocean = try entry(s, "free.theme.ocean")
  try await s.store.install(ocean)
  #expect(s.store.isInstalled(ocean.id))
  #expect(s.themes.installed.map(\.id) == [ocean.id])
  s.themes.select(ocean.id)
  #expect(s.themes.current.name == "Ocean")
  s.store.uninstall(ocean.id)
  #expect(!s.store.isInstalled(ocean.id))
  #expect(s.themes.installed.isEmpty)
  #expect(s.themes.current.id == Theme.standard.id, "a theme that was taken away is not in use any more")
}

@MainActor @Test func stickersJoinTheLibraryAndLeaveItAgain() async throws {
  let s = setup()
  let strips = try entry(s, "free.sticker.highlighter-strips")
  try await s.store.install(strips)
  #expect(s.elements.clips.count == 6)
  let first = s.store.installedPack(strips.id)?.clipIDs
  #expect(first?.count == 6 && Set(first ?? []) == Set(s.elements.clips.map(\.id)))
  // Installing it again is an update: the six are replaced, not doubled.
  try await s.store.install(strips)
  #expect(s.elements.clips.count == 6)
  let second = Set(s.store.installedPack(strips.id)?.clipIDs ?? [])
  #expect(second.count == 6 && second.isDisjoint(with: Set(first ?? [])))
  // Other elements of the library are not touched by taking the pack away.
  var page = Page(paper: Paper(pattern: .blank))
  page.strokes = [Stroke(samples: [Sample(point: Point(0, 0))])]
  let own = ElementClip(title: "Mine", content: page)
  try s.elements.add(own)
  s.store.uninstall(strips.id)
  #expect(s.elements.clips.map(\.id) == [own.id])
}

@MainActor @Test func aTemplateIsKeptAndAPlannerStartsANewNotebook() async throws {
  let s = setup()
  let template = try entry(s, "free.template.cornell-notes")
  let planner = try entry(s, "free.planner.weekly-planner")
  try await s.store.install(template)
  try await s.store.install(planner)
  #expect(s.store.templates.map(\.id) == [template.id], "planners are not page templates")
  #expect(try s.store.notebook(of: template.id).notebook.pages.count == 1)

  let one = try s.store.newNotebook(from: planner.id)
  let two = try s.store.newNotebook(from: planner.id)
  #expect(one.notebook.title == "Weekly Planner" && one.notebook.pages.count == 4)
  #expect(one.notebook.id != two.notebook.id)
  #expect(Set(one.notebook.pages.map(\.id)).isDisjoint(with: two.notebook.pages.map(\.id)))

  // The installed packs are still there after the app starts again.
  let again = setup(directory: s.directory)
  #expect(Set(again.store.installed.map(\.id)) == [template.id, planner.id])
  again.store.uninstall(planner.id)
  #expect(throws: MarketplaceError.self) { try again.store.notebook(of: planner.id) }
}

@MainActor @Test func aPackThatIsNotWhatTheIndexSaysIsNotInstalled() async throws {
  // A catalog of the app whose pack was changed after the index was made.
  let copy = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: copy) }
  try FileManager.default.copyItem(at: catalog, to: copy)
  let file = copy.appendingPathComponent("packs/free.template.to-do-list.ncpack")
  var bytes = try Data(contentsOf: file)
  bytes[bytes.count / 2] ^= 0xFF
  try bytes.write(to: file)

  let s = setup(bundled: FolderCatalogSource(root: copy))
  let todo = try entry(s, "free.template.to-do-list")
  await #expect(throws: PackError.wrongHash) { try await s.store.install(todo) }
  #expect(!s.store.isInstalled(todo.id) && s.store.templates.isEmpty)
  #expect(s.store.working.isEmpty, "the store is not left busy")
}

@MainActor @Test func theCatalogIsDownloadedKeptAndKeptWhenTheNetworkFails() async throws {
  let index = try Data(contentsOf: catalog.appendingPathComponent("index.json"))
  var parsed = try CatalogIndex.parse(index)
  parsed.packs.removeAll { $0.id == "free.theme.forest" }
  parsed.updated = "2026-11-01"
  let served = try parsed.encoded()

  var s = setup(remote: MemorySource(files: ["index.json": served]))
  await s.store.refresh()
  #expect(s.store.status == .idle && s.store.updated != nil)
  #expect(s.store.index.packs.count == 14 && s.store.entry("free.theme.forest") == nil)

  // The next start shows the catalog that was downloaded, before anything is asked of the network.
  s = setup(directory: s.directory, remote: FailingSource())
  #expect(s.store.index.packs.count == 14 && s.store.updated != nil)
  await s.store.refresh()
  if case .failed(let why) = s.store.status { #expect(why.contains("could not be reached")) } else {
    Issue.record("a catalog that cannot be reached is a failure")
  }
  #expect(s.store.index.packs.count == 14, "what was shown stays")
}

@MainActor @Test func anIndexThatIsNotACatalogIsNotUsed() async {
  let s = setup(remote: MemorySource(files: ["index.json": Data("<html>Not found</html>".utf8)]))
  await s.store.refresh()
  if case .failed = s.store.status {} else { Issue.record("not a catalog") }
  #expect(s.store.index.packs.count == 15 && s.store.updated == nil)
}

@MainActor @Test func aPackOfTheCatalogOfTheAppNeedsNoNetwork() async throws {
  // The packs of the app are used when the file is the same, so installing works on a plane.
  let s = setup(remote: FailingSource())
  try await s.store.install(try entry(s, "free.theme.sunset"))
  #expect(s.store.isInstalled("free.theme.sunset"))
}

@MainActor @Test func aPackOnlyTheWebHasIsDownloadedAndChecked() async throws {
  let source = try Data(contentsOf: catalog.appendingPathComponent("packs/free.template.meeting-notes.ncpack"))
  var e = try #require(CatalogIndex.parse(Data(contentsOf: catalog.appendingPathComponent("index.json")))
    .packs.first { $0.id == "free.template.meeting-notes" })
  e.id = "someone.template.minutes"
  e.file = "packs/someone.template.minutes.ncpack"
  // The pack says it is another pack than the entry says: not installed.
  let remote = MemorySource(files: [e.file: source])
  let s = setup(remote: remote)
  await #expect(throws: PackError.self) { try await s.store.install(e) }
  #expect(s.store.installed.isEmpty)
}

@MainActor @Test func theAddressIsAnHttpsFolderAndCanBeSetBackToTheDefault() throws {
  let s = setup()
  #expect(s.store.address == MarketplaceStore.defaultAddress)
  try s.store.setAddress("https://example.com/notescraft/catalog")
  #expect(s.store.address == "https://example.com/notescraft/catalog")
  #expect(throws: MarketplaceError.badAddress) { try s.store.setAddress("http://example.com/catalog/") }
  #expect(throws: MarketplaceError.badAddress) { try s.store.setAddress("file:///etc/") }
  #expect(throws: MarketplaceError.badAddress) { try s.store.setAddress("https://user:pw@example.com/") }
  #expect(s.store.address == "https://example.com/notescraft/catalog", "a wrong address changes nothing")
  try s.store.setAddress("")
  #expect(s.store.address == MarketplaceStore.defaultAddress)
  #expect(WebCatalogSource(address: "https://example.com/c")?.base.absoluteString == "https://example.com/c/")
}

@MainActor @Test func savedPacksAreRemembered() {
  let s = setup()
  s.store.toggleSaved("free.theme.ocean")
  #expect(s.store.isSaved("free.theme.ocean"))
  let again = setup(directory: s.directory)
  #expect(again.store.isSaved("free.theme.ocean"))
  again.store.toggleSaved("free.theme.ocean")
  #expect(!again.store.isSaved("free.theme.ocean"))
}

@MainActor @Test func aNewVersionInTheCatalogIsAnUpdate() async throws {
  let s = setup()
  let ocean = try entry(s, "free.theme.ocean")
  try await s.store.install(ocean)
  #expect(!s.store.hasUpdate(ocean.id))
  // The catalog now has another version of it.
  var parsed = try CatalogIndex.parse(Data(contentsOf: catalog.appendingPathComponent("index.json")))
  let position = try #require(parsed.packs.firstIndex { $0.id == ocean.id })
  parsed.packs[position].version = "1.1"
  let again = setup(directory: s.directory, remote: MemorySource(files: ["index.json": try parsed.encoded()]))
  await again.store.refresh()
  #expect(again.store.hasUpdate(ocean.id))
}

@MainActor @Test func aPreviewIsReadAtABoundedSize() async throws {
  let s = setup()
  let image = await s.store.preview(for: try entry(s, "free.template.cornell-notes"))
  #expect(image != nil && image!.width <= 840 && image!.height <= 840)
  // A picture that is small to send and huge to draw is not drawn.
  let context = try #require(
    CGContext(
      data: nil, width: 4100, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  let wide = NSMutableData()
  let destination = try #require(CGImageDestinationCreateWithData(wide, "public.png" as CFString, 1, nil))
  CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
  #expect(CGImageDestinationFinalize(destination))
  #expect(wide.length < MarketplaceStore.maxPreviewBytes)
  #expect(MarketplaceStore.decodePreview(wide as Data) == nil)
  #expect(MarketplaceStore.decodePreview(Data("not an image".utf8)) == nil)
}
