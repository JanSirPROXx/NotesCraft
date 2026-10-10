import Foundation
import Testing

@testable import NoteCraftCore

@Test func vaultPreservesExistingFilesAndDetectsExternalWrites() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let note = folder.appendingPathComponent("Existing.md")
  let original = Data("# Obsidian\n[[Another note]]\n".utf8)
  try original.write(to: note)
  try FileManager.default.createDirectory(
    at: folder.appendingPathComponent("Work.projects"), withIntermediateDirectories: false)
  try FileManager.default.createDirectory(
    at: folder.appendingPathComponent(".obsidian"), withIntermediateDirectories: false)
  let files = VaultFiles()
  let entries = try await files.list(folder)
  #expect(entries.count == 2)
  #expect(entries.first?.title == "Work.projects")
  #expect(entries.last?.kind == .markdown)
  #expect(try Data(contentsOf: note) == original)
  let snapshot = try await files.read(note)
  let external = Data("Updated externally".utf8)
  try external.write(to: note)
  await #expect(throws: PackageError.self) {
    try await files.write(Data("My changes".utf8), to: note, expected: snapshot.stamp)
  }
  #expect(try Data(contentsOf: note) == external)
  await #expect(throws: PackageError.self) {
    try await files.write(Data(), to: note, expected: nil, createOnly: true)
  }
  let alternative = await files.availableURL(in: folder, title: "Existing", extension: "md")
  #expect(alternative.lastPathComponent == "Existing 2.md")
}

@Test func vaultReadsNotebookMetadataAndWhiteboardKind() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  var notebook = Notebook(title: "Design sketches")
  notebook.kind = .whiteboard
  let url = folder.appendingPathComponent("Different filename.notecraft")
  try await PackageStore().save(NotebookPackage(notebook: notebook), to: url)
  let entries = try await VaultFiles().list(folder)
  #expect(entries.first?.title == "Design sketches")
  #expect(entries.first?.kind == .whiteboard)
}
