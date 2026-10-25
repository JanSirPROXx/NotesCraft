import Foundation
import Testing

@testable import NoteCraftCore

// The catalog that is committed to this repository (`catalog/`) is what the app downloads. These
// tests are what a pull request that adds a pack has to pass: every entry is read the way the app
// reads it, so a pack that does not pass here would not install on a device either.
private let catalogFolder = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .appendingPathComponent("catalog")

private func loadIndex() throws -> CatalogIndex {
  try CatalogIndex.parse(Data(contentsOf: catalogFolder.appendingPathComponent("index.json")))
}

@Test func theCommittedIndexIsValidAndListsOnlyFilesThatExist() throws {
  let index = try loadIndex()
  #expect(!index.packs.isEmpty)
  let packs = catalogFolder.appendingPathComponent("packs")
  let listed = Set(index.packs.map { URL(fileURLWithPath: $0.file).lastPathComponent })
  let onDisk = Set(try FileManager.default.contentsOfDirectory(atPath: packs.path).filter { $0.hasSuffix(".ncpack") })
  #expect(listed == onDisk, "every pack file is in the index, and every entry has its file")
  for entry in index.packs {
    try entry.validate()
    if let preview = entry.preview {
      let data = try Data(contentsOf: catalogFolder.appendingPathComponent(preview))
      #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "\(entry.id): the preview is a PNG")
      #expect(data.count <= 300_000, "\(entry.id): the preview is small")
    }
  }
}

@Test func everyCommittedPackIsTheSizeAndHashOfItsEntryAndLoadsAsItsKind() throws {
  let index = try loadIndex()
  for entry in index.packs {
    let data = try Data(contentsOf: catalogFolder.appendingPathComponent(entry.file))
    #expect(data.count == entry.size, "\(entry.id): size")
    #expect(sha256Hex(data) == entry.sha256, "\(entry.id): hash")
    let pack = try Pack.open(data, expecting: entry)
    switch entry.kind {
    case .theme:
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("theme-" + UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let theme = try pack.theme(writingTo: directory)
      #expect(theme.id == entry.id)
    case .sticker:
      let clips = try pack.stickers()
      #expect(!clips.isEmpty, "\(entry.id)")
    case .template, .planner:
      let package = try pack.notebook()
      #expect(package.notebook.pages.count == entry.pages, "\(entry.id): the index says how many pages")
    }
  }
}
