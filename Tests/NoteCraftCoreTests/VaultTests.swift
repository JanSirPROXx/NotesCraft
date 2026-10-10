import Foundation
import Testing

@testable import NoteCraftCore

@Test func managedFilesKeepSidecarsAndTrashRestoresWithoutOverwriting() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let files = VaultFiles()
  let source = root.appendingPathComponent("Original.pdf")
  try Data([1, 2, 3]).write(to: source)
  let sidecar = await files.sidecar(for: source)
  try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: false)
  try Data([4, 5]).write(to: sidecar.appendingPathComponent("editable"))
  let destination = root.appendingPathComponent("Renamed.pdf")
  try await files.transfer(source, to: destination, in: root)
  #expect(!FileManager.default.fileExists(atPath: source.path))
  #expect(
    try Data(contentsOf: await files.sidecar(for: destination).appendingPathComponent("editable"))
      == Data([4, 5]))
  let copy = root.appendingPathComponent("Copy.pdf")
  try await files.transfer(destination, to: copy, in: root, copy: true)
  #expect(try Data(contentsOf: copy) == Data([1, 2, 3]))
  await #expect(throws: VaultOperationError.self) {
    try await files.transfer(destination, to: copy, in: root)
  }
  let item = try await files.trash(destination, in: root)
  #expect(try await files.trashItems(in: root).count == 1)
  #expect(try await files.list(root).count == 1)
  try Data([9]).write(to: destination)
  await #expect(throws: VaultOperationError.self) { try await files.restore(item, in: root) }
  #expect(try Data(contentsOf: destination) == Data([9]))
  #expect(try await files.trashItems(in: root).count == 1)
  try FileManager.default.removeItem(at: destination)
  #expect(try await files.restore(item, in: root) == destination)
  #expect(try Data(contentsOf: destination) == Data([1, 2, 3]))
  #expect(try await files.trashItems(in: root).isEmpty)
  let discarded = try await files.trash(copy, in: root)
  try await files.permanentlyDelete(discarded, in: root)
  #expect(try await files.trashItems(in: root).isEmpty)
  await #expect(throws: VaultOperationError.self) {
    try await files.transfer(
      destination, to: root.deletingLastPathComponent().appendingPathComponent("Outside.pdf"),
      in: root)
  }
}

@Test func foldersCannotMoveInsideThemselvesAndNamesAreValidated() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let folder = root.appendingPathComponent("Projects")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let files = VaultFiles()
  await #expect(throws: VaultOperationError.self) {
    try await files.transfer(folder, to: folder.appendingPathComponent("Nested"), in: root)
  }
  await #expect(throws: VaultOperationError.self) { try await files.validateName("../hidden") }
  let item = try await files.trash(folder, in: root)
  _ = try await files.restore(item, in: root)
  #expect(FileManager.default.fileExists(atPath: folder.path))
}

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
