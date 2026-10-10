import Foundation
import NoteCraftCore
import PDFKit
import Testing

@testable import NoteCraft

@MainActor @Test func vaultEditsMarkdownInPlaceAndProtectsExternalChanges() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let preferences = try #require(UserDefaults(suiteName: UUID().uuidString))
  let vault = VaultController(preferences: preferences)
  let url = folder.appendingPathComponent("Note.md")
  try Data("# Existing\n[[Wiki link]]\n".utf8).write(to: url)
  await vault.choose(folder)
  #expect(vault.sessions.isEmpty)
  await vault.open(try #require(vault.entries.first))
  let session = try #require(vault.active)
  #expect(session.markdown.contains("[[Wiki link]]"))
  session.markdown += "New line\n"
  vault.changed(session)
  await vault.save(session)
  #expect(try String(contentsOf: url, encoding: .utf8) == session.markdown)
  #expect(!session.dirty)
  try Data("Changed in Obsidian".utf8).write(to: url)
  session.markdown += "My next edit"
  vault.changed(session)
  await vault.save(session)
  session.saveTask?.cancel()
  #expect(session.dirty)
  #expect(vault.error != nil)
  #expect(try String(contentsOf: url, encoding: .utf8) == "Changed in Obsidian")
  let unsaved = session.markdown
  await vault.saveCopy(session)
  #expect(vault.active?.url != url)
  #expect(vault.active?.markdown == unsaved)
  #expect(try String(contentsOf: url, encoding: .utf8) == "Changed in Obsidian")
}

@MainActor @Test func PDFInPlaceSaveKeepsOriginalAnnotationsAndEditableInk() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let source = try #require(PDFDocument(data: PageRenderer.export(NotebookPackage())))
  let first = try #require(source.page(at: 0))
  let existing = PDFAnnotation(
    bounds: CGRect(x: 30, y: 600, width: 180, height: 30), forType: .freeText, withProperties: nil)
  existing.contents = "Original annotation"
  first.addAnnotation(existing)
  let url = folder.appendingPathComponent("Lecture.pdf")
  try #require(source.dataRepresentation()).write(to: url)
  let vault = VaultController(preferences: try #require(UserDefaults(suiteName: UUID().uuidString)))
  await vault.choose(folder)
  await vault.open(try #require(vault.entries.first))
  let session = try #require(vault.active)
  let ink = Stroke(
    samples: [Sample(point: Point(50, 100)), Sample(point: Point(220, 130))], color: .blue, width: 3
  )
  session.document.package.notebook.pages[0].strokes.append(ink)
  session.document.package.notebook.revision += 1
  vault.changed(session)
  await vault.save(session)
  session.saveTask?.cancel()
  #expect(!session.dirty)
  let saved = try #require(PDFDocument(url: url))
  let annotations = try #require(saved.page(at: 0)).annotations
  #expect(annotations.contains { $0.contents == "Original annotation" })
  #expect(annotations.contains { $0.type == "Ink" })
  let reopened = VaultController(
    preferences: try #require(UserDefaults(suiteName: UUID().uuidString)))
  await reopened.choose(folder)
  #expect(reopened.entries.count == 1)
  await reopened.open(try #require(reopened.entries.first))
  #expect(reopened.active?.document.package.notebook.pages[0].strokes == [ink])
  let replacement = try PageRenderer.export(
    NotebookPackage(notebook: Notebook(pages: [Page(), Page()])))
  try replacement.write(to: url)
  let externallyUpdated = VaultController(
    preferences: try #require(UserDefaults(suiteName: UUID().uuidString)))
  await externallyUpdated.choose(folder)
  await externallyUpdated.open(try #require(externallyUpdated.entries.first))
  #expect(externallyUpdated.active?.document.package.notebook.pages.count == 2)
  #expect(externallyUpdated.active?.document.package.notebook.pages[0].strokes.isEmpty == true)
}

@MainActor @Test func whiteboardExportIncludesInkBeyondNominalPage() throws {
  var page = Page(paper: Paper(pattern: .blank))
  page.strokes = [
    Stroke(
      samples: [Sample(point: Point(-400, -200)), Sample(point: Point(2800, 2500))], color: .blue,
      width: 3)
  ]
  var notebook = Notebook(pages: [page])
  notebook.kind = .whiteboard
  let package = NotebookPackage(notebook: notebook)
  let pdf = try #require(PDFDocument(data: PageRenderer.export(package)))
  let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
  #expect(bounds.width > 3200)
  #expect(bounds.height > 2700)
  #expect(try PageRenderer.thumbnail(package).count > 100)
}

@MainActor @Test func newlyCreatedNotebooksAndWhiteboardsOpenImmediately() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let vault = VaultController(preferences: try #require(UserDefaults(suiteName: UUID().uuidString)))
  await vault.choose(folder)
  await vault.create(title: "Class notes", paper: Paper())
  #expect(vault.active?.title == "Class notes")
  #expect(!vault.showLibrary)
  await vault.library()
  await vault.create(title: "Ideas", paper: Paper(pattern: .blank), whiteboard: true)
  let board = try #require(vault.active)
  #expect(board.document.package.notebook.kind == .whiteboard)
  board.document.package.notebook.viewport = ViewTransform(scale: 0.8, offset: Point(-2000, 500))
  board.document.package.notebook.revision += 1
  vault.changed(board)
  await vault.save(board)
  board.saveTask?.cancel()
  let stored = try await PackageStore().read(from: board.url)
  #expect(stored.notebook.viewport == board.document.package.notebook.viewport)
}

@MainActor @Test func elementCollectionPersistsAndPreservesUnreadableFiles() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
  let library = ElementLibrary(directory: directory, defaults: defaults)
  var page = Page()
  page.strokes = [Stroke(samples: [Sample(point: Point(10, 20))])]
  let clip = try ElementClip.capture(
    title: "Example", page: page, ids: [page.strokes[0].id], assets: [:])
  try library.add(clip)
  try library.rename(clip.id, title: "Renamed")
  let reopened = ElementLibrary(directory: directory, defaults: defaults)
  #expect(reopened.clips.count == 1 && reopened.clips[0].title == "Renamed")
  try reopened.remove(clip.id)
  #expect(ElementLibrary(directory: directory, defaults: defaults).clips.isEmpty)
  let url = directory.appendingPathComponent("Elements.json")
  let unreadable = Data("invalid content".utf8)
  try unreadable.write(to: url)
  let broken = ElementLibrary(directory: directory, defaults: defaults)
  #expect(broken.loadError != nil)
  #expect(throws: PackageError.self) { try broken.add(clip) }
  #expect(try Data(contentsOf: url) == unreadable)
}
