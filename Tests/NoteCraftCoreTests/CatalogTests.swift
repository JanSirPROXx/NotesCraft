import Foundation
import Testing

@testable import NoteCraftCore

// MARK: the index

private func entry(
  _ id: String = "com.example.pack", kind: PackKind = .template, size: Int = 1000,
  sha256: String = String(repeating: "a", count: 64)
) -> CatalogEntry {
  CatalogEntry(
    id: id, kind: kind, name: "Pack", author: "Someone", summary: "A pack.", category: .study,
    tags: ["notes"], version: "1.0", license: "CC0-1.0", file: "packs/pack.ncpack",
    preview: "previews/pack.png", size: size, sha256: sha256, pages: 1)
}

@Test func anIndexIsWrittenAndReadBack() throws {
  let index = CatalogIndex(updated: "2026-10-26", packs: [entry("com.example.b"), entry("com.example.a")])
  let parsed = try CatalogIndex.parse(index.encoded())
  #expect(parsed.packs.map(\.id) == ["com.example.a", "com.example.b"], "sorted by id, so diffs are small")
  #expect(parsed.packs[0] == entry("com.example.a"))
  #expect(parsed.updated == "2026-10-26")
}

@Test func anEntryIsCheckedBeforeAnythingIsFetchedForIt() {
  func rejected(_ change: (inout CatalogEntry) -> Void) -> Bool {
    var e = entry()
    change(&e)
    return (try? e.validate()) == nil
  }
  #expect(!rejected { _ in })
  #expect(rejected { $0.id = "Bad Id" })
  #expect(rejected { $0.name = "  " })
  #expect(rejected { $0.name = String(repeating: "x", count: 61) })
  #expect(rejected { $0.summary = String(repeating: "x", count: 401) })
  #expect(rejected { $0.tags = (0..<9).map { "t\($0)" } })
  #expect(rejected { $0.license = "" })
  #expect(rejected { $0.size = 0 })
  #expect(rejected { $0.size = CatalogEntry.maxPackBytes + 1 })
  #expect(rejected { $0.sha256 = "ABC" })
  #expect(rejected { $0.sha256 = String(repeating: "A", count: 64) })
  #expect(rejected { $0.file = "packs/pack.zip" })
  #expect(rejected { $0.file = "../outside.ncpack" })
  #expect(rejected { $0.file = "https://evil.example/pack.ncpack" })
  #expect(rejected { $0.preview = "previews/pack.svg" })
  #expect(rejected { $0.preview = "/etc/passwd.png" })
  #expect(rejected { $0.pages = 0 })
}

@Test func anIndexRefusesWhatItCannotRead() throws {
  #expect(throws: CatalogError.notACatalog) { try CatalogIndex.parse(Data("nope".utf8)) }
  #expect(throws: CatalogError.unsupportedFormat(2)) { try CatalogIndex.parse(Data(#"{"format":2,"packs":[]}"#.utf8)) }
  let twice = CatalogIndex(updated: "", packs: [entry(), entry()])
  #expect(throws: CatalogError.duplicate("com.example.pack")) { try CatalogIndex.parse(twice.encoded()) }
  let big = CatalogIndex(updated: "", packs: (0..<501).map { entry("com.example.p\($0)") })
  #expect(throws: CatalogError.tooMany) { try CatalogIndex.parse(big.encoded()) }
}

@Test func searchAndFiltersFindWhatYouWouldLookFor() {
  var cornell = entry("com.example.cornell", kind: .template)
  cornell.name = "Cornell Notes"
  cornell.tags = ["lecture", "study"]
  cornell.category = .study
  var planner = entry("com.example.week", kind: .planner)
  planner.name = "Weekly Planner"
  planner.category = .work
  var sunset = entry("com.example.sunset", kind: .theme)
  sunset.name = "Sunset"
  sunset.category = .life
  sunset.author = "Ada"
  let index = CatalogIndex(updated: "", packs: [cornell, planner, sunset])
  #expect(index.entries().map(\.name) == ["Cornell Notes", "Sunset", "Weekly Planner"])
  #expect(index.entries(query: "lecture").map(\.name) == ["Cornell Notes"], "tags count")
  #expect(index.entries(query: "ada").map(\.name) == ["Sunset"], "so does the author")
  #expect(index.entries(query: "WEEKLY plan").map(\.name) == ["Weekly Planner"], "every word, any case")
  #expect(index.entries(category: .work).map(\.name) == ["Weekly Planner"])
  #expect(index.entries(kind: .theme).map(\.name) == ["Sunset"])
  #expect(index.entries(category: .work, kind: .theme).isEmpty)
  #expect(index.entries(query: "planner theme").isEmpty)
}

// MARK: packs

private func notebookContent(pages: Int = 1) throws -> [String: Data] {
  var notebook = Notebook(title: "Template", pages: (0..<pages).map { _ in Page() })
  notebook.pages[0].texts = [TextBox(origin: Point(40, 40), text: "Title")]
  let wrapper = try NotebookPackage(notebook: notebook).fileWrapper()
  var files: [String: Data] = [:]
  files["manifest.json"] = wrapper.fileWrappers?["manifest.json"]?.regularFileContents
  return files
}

private func make(
  _ kind: PackKind, content: [String: Data], id: String = "com.example.pack"
) throws -> (data: Data, entry: CatalogEntry) {
  let manifest = PackManifest(id: id, kind: kind, name: "Pack", version: "1.0")
  let data = try Pack.build(manifest: manifest, content: content)
  var e = entry(id, kind: kind, size: data.count, sha256: sha256Hex(data))
  e.kind = kind
  return (data, e)
}

@Test func aPackIsOpenedOnlyIfItIsWhatTheCatalogPromised() throws {
  let (data, e) = try make(.planner, content: try notebookContent(pages: 3))
  let pack = try Pack.open(data, expecting: e)
  #expect(pack.manifest.id == e.id)
  #expect(try pack.notebook().notebook.pages.count == 3)
  var other = data
  other[other.count / 2] ^= 1
  #expect(throws: PackError.wrongHash) { try Pack.open(other, expecting: e) }
  var short = e
  short.size += 1
  #expect(throws: PackError.wrongSize(expected: short.size, actual: data.count)) { try Pack.open(data, expecting: short) }
  var renamed = e
  renamed.id = "com.example.other"
  #expect(throws: PackError.manifestDoesNotMatch("id")) { try Pack.open(data, expecting: renamed) }
  var kind = e
  kind.kind = .theme
  #expect(throws: PackError.manifestDoesNotMatch("kind")) { try Pack.open(data, expecting: kind) }
  var version = e
  version.version = "9"
  #expect(throws: PackError.manifestDoesNotMatch("version")) { try Pack.open(data, expecting: version) }
}

@Test func theSameInputMakesTheSamePackAndHash() throws {
  let content = try notebookContent()
  let a = try make(.template, content: content)
  let b = try make(.template, content: content)
  #expect(a.data == b.data && a.entry.sha256 == b.entry.sha256)
}

@Test func aPackWithoutAManifestOrWithStrayFilesIsRefused() throws {
  let bare = try ZipArchive.write(["content/a.txt": Data("x".utf8)])
  #expect(throws: PackError.noManifest) { try Pack.open(bare) }
  let manifest = try JSONEncoder().encode(PackManifest(id: "com.example.pack", kind: .template, name: "P", version: "1"))
  let stray = try ZipArchive.write(["pack.json": manifest, "run.sh": Data("x".utf8)])
  #expect(throws: PackError.unexpectedFile("run.sh")) { try Pack.open(stray) }
}

@Test func aTemplateOrPlannerIsANotebook() throws {
  let (data, e) = try make(.template, content: try notebookContent(pages: 2))
  let notebook = try Pack.open(data, expecting: e).notebook()
  #expect(notebook.notebook.pages.count == 2)
  let tooMany = try make(.template, content: try notebookContent(pages: Pack.maxTemplatePages + 1))
  #expect(throws: PackError.self) { try Pack.open(tooMany.data, expecting: tooMany.entry).notebook() }
  let strange = try make(.template, content: ["manifest.json": Data("{}".utf8)])
  #expect(throws: PackError.self) { try Pack.open(strange.data).notebook() }
  var assets = try notebookContent()
  assets["assets/sub/deep.png"] = Data([1])
  let nested = try make(.template, content: assets)
  #expect(throws: PackError.unexpectedFile("assets/sub/deep.png")) { try Pack.open(nested.data).notebook() }
}

@Test func aStickerPackHoldsElements() throws {
  var page = Page(paper: Paper(pattern: .blank))
  page.strokes = [Stroke(samples: [Sample(point: Point(0, 0)), Sample(point: Point(20, 20))], width: 3)]
  page.backgroundSize = Point(20, 20)
  let clip = ElementClip(title: "Line", content: page)
  let json = try JSONEncoder().encode([clip])
  let (data, e) = try make(.sticker, content: ["elements.json": json])
  let clips = try Pack.open(data, expecting: e).stickers()
  #expect(clips.count == 1 && clips[0].title == "Line")
  let empty = try make(.sticker, content: ["elements.json": Data("[]".utf8)])
  #expect(throws: PackError.self) { try Pack.open(empty.data).stickers() }
  let extra = try make(.sticker, content: ["elements.json": json, "x.png": Data([1])])
  #expect(throws: PackError.self) { try Pack.open(extra.data).stickers() }
  // Asking a pack for what it is not.
  #expect(throws: PackError.self) { try Pack.open(data).notebook() }
}

@Test func aThemePackIsCheckedLikeAThemeFolder() throws {
  let theme = Data(##"{"format":1,"id":"com.example.pack","name":"T","colors":{"dark":{"accent":"#112233"}}}"##.utf8)
  let (data, e) = try make(.theme, content: ["theme.json": theme])
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pack-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let loaded = try Pack.open(data, expecting: e).theme(writingTo: directory)
  #expect(loaded.id == "com.example.pack" && loaded.dark[.accent]?.hex == "#112233")
  // A theme whose id is not the pack's.
  let wrong = Data(#"{"format":1,"id":"com.example.another","name":"T"}"#.utf8)
  let mismatch = try make(.theme, content: ["theme.json": wrong])
  let other = FileManager.default.temporaryDirectory.appendingPathComponent("pack-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: other) }
  #expect(throws: PackError.manifestDoesNotMatch("theme id")) { try Pack.open(mismatch.data).theme(writingTo: other) }
  // A script in a theme.
  let script = try make(.theme, content: ["theme.json": theme, "install.sh": Data("x".utf8)])
  let third = FileManager.default.temporaryDirectory.appendingPathComponent("pack-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: third) }
  #expect(throws: ThemeError.unsupportedFile("install.sh")) { try Pack.open(script.data).theme(writingTo: third) }
}

// MARK: adding the pages of a template

@Test func thePagesOfATemplateAreAddedWithNewIdentitiesAndMedia() throws {
  var template = NotebookPackage(notebook: Notebook(title: "T", pages: [Page(), Page()]))
  template.notebook.pages[0].images = [PageAsset(filename: "pic.png", frame: Rect(x: 0, y: 0, width: 10, height: 10))]
  template.notebook.pages[1].backgroundPDF = "form.pdf"
  template.notebook.pages[0].strokes = [Stroke(samples: [Sample(point: Point(1, 1))])]
  template.assets = ["pic.png": Data([1, 2]), "form.pdf": Data([3, 4])]
  var notebook = NotebookPackage(notebook: Notebook(title: "Mine", pages: [Page(), Page()]))
  notebook.assets = ["pic.png": Data([9, 9, 9])]

  let first = try notebook.insertPages(of: template, after: 0)
  #expect(first == 1 && notebook.notebook.pages.count == 4)
  let added = notebook.notebook.pages[1...2]
  #expect(Set(added.map(\.id)).isDisjoint(with: template.notebook.pages.map(\.id)))
  #expect(added.first!.strokes[0].id != template.notebook.pages[0].strokes[0].id)
  // The notebook's own picture with the same name is still its own.
  #expect(notebook.assets["pic.png"] == Data([9, 9, 9]))
  let imageName = added.first!.images[0].filename
  #expect(imageName != "pic.png" && notebook.assets[imageName] == Data([1, 2]))
  let pdfName = try #require(added.last!.backgroundPDF)
  #expect(pdfName != "form.pdf" && notebook.assets[pdfName] == Data([3, 4]))
  #expect(notebook.notebook.pages[3].id == notebook.notebook.pages.last!.id, "the page that was last stays last")
  _ = try notebook.manifestData()  // every picture it names is there
}

@Test func aTemplateWithAMissingPictureIsRefused() {
  var template = NotebookPackage(notebook: Notebook(title: "T", pages: [Page()]))
  template.notebook.pages[0].images = [PageAsset(filename: "gone.png", frame: Rect(x: 0, y: 0, width: 1, height: 1))]
  var notebook = NotebookPackage(notebook: Notebook(title: "Mine", pages: [Page()]))
  #expect(throws: PackageError.self) { try notebook.insertPages(of: template) }
}
