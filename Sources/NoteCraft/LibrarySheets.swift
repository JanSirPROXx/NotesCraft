import NoteCraftCore
import SwiftUI

struct LibraryRenameSheet: View {
  @Bindable var vault: VaultController
  let entry: VaultEntry
  @State private var name = ""
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text("Rename").font(.theme(.title2).bold())
      TextField("Name", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier(
        "renameField")
      if entry.kind != .folder {
        Text("The .\(entry.url.pathExtension) extension is kept automatically.").font(.theme(.caption))
          .foregroundStyle(.secondary)
      }
      if let error = vault.error { Text(error).font(.theme(.caption)).foregroundStyle(.red) }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Rename") {
          Task {
            vault.error = nil
            await vault.rename(entry, to: name)
            if vault.error == nil { dismiss() }
          }
        }.buttonStyle(.themedProminent).disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || vault.busy)
      }
    }.padding(28).frame(minWidth: 340).onAppear { name = entry.title }.themedSheet()
  }
}

struct LibraryMoveSheet: View {
  @Bindable var vault: VaultController
  let entry: VaultEntry
  @State private var folder: URL?
  @State private var folders: [VaultEntry] = []
  @State private var loadError: String?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Text("Move “\(entry.title)”").font(.theme(.headline))
        HStack {
          if let folder, folder.vaultPath != vault.root?.vaultPath {
            Button {
              self.folder = folder.deletingLastPathComponent()
            } label: {
              Label("Up", systemImage: Icon.name("chevron.left"))
            }
          }
          Text(folder?.lastPathComponent ?? "Storage folder").font(.theme(.subheadline)).foregroundStyle(
            .secondary)
        }
        if let message = loadError ?? vault.error { Text(message).foregroundStyle(.red) }
        List(folders) { child in
          Button {
            folder = child.url
          } label: {
            Label(child.title, systemImage: Icon.name("folder"))
          }
        }.overlay {
          if folders.isEmpty && loadError == nil {
            Text("No subfolders. You can move here.").foregroundStyle(.secondary)
          }
        }
      }.padding(20).navigationTitle("Choose destination")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Move here") {
              if let folder {
                Task {
                  vault.error = nil
                  await vault.move(entry, to: folder)
                  if vault.error == nil { dismiss() }
                }
              }
            }.disabled(
              folder == nil || folder?.vaultPath == entry.url.deletingLastPathComponent().vaultPath
                || vault.busy
                || loadError != nil)
          }
        }
        .task(id: folder) {
          guard let folder else {
            self.folder = vault.root
            return
          }
          do {
            folders = try await vault.files.list(folder).filter {
              $0.kind == .folder && $0.url != entry.url
                && !$0.url.vaultPath.hasPrefix(entry.url.vaultPath + "/")
            }
            loadError = nil
          } catch { loadError = error.localizedDescription }
        }
    }.frame(minWidth: 380, minHeight: 420).themedSheet()
  }
}

struct TrashLibrary: View {
  @Bindable var vault: VaultController
  let items: [TrashItem]
  @State private var deletion: TrashItem?
  @State private var emptyTrash = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(
        "Restore items to their original folder. Items stay here until you delete them permanently."
      )
      .font(.theme(.subheadline)).foregroundStyle(.secondary)
      if !vault.trashItems.isEmpty {
        Button("Empty Trash", role: .destructive) { emptyTrash = true }.foregroundStyle(.red)
          .disabled(vault.busy)
      }
      if vault.trashItems.isEmpty {
        ContentUnavailableView(
          "Trash is empty", systemImage: Icon.name("trash"),
          description: Text("Deleted documents and folders will appear here."))
      }
      if !vault.trashItems.isEmpty && items.isEmpty {
        ContentUnavailableView(
          "No matching deleted items", systemImage: Icon.name("magnifyingglass"),
          description: Text("Try another search."))
      }
      ForEach(items) { item in
        HStack(spacing: 16) {
          Symbol("doc").font(.theme(.title2))
          VStack(alignment: .leading, spacing: 5) {
            Text(item.name).font(.theme(.headline))
            Text(item.originalPath).font(.theme(.caption)).foregroundStyle(.secondary)
            Text(item.deleted.formatted(date: .abbreviated, time: .shortened)).font(.theme(.caption))
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Restore") { Task { await vault.restore(item) } }.buttonStyle(.bordered).disabled(
            vault.busy)
          Button {
            deletion = item
          } label: {
            Symbol("trash")
          }.foregroundStyle(.red).accessibilityLabel("Delete permanently \(item.name)").disabled(
            vault.busy)
        }.padding(18).background(Color.theme(.surface), in: RoundedRectangle(cornerRadius: .corner(16)))
      }
    }.confirmationDialog(
      "Delete permanently?",
      isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }),
      titleVisibility: .visible
    ) {
      if let item = deletion {
        Button("Delete permanently", role: .destructive) {
          Task {
            await vault.deletePermanently(item)
            deletion = nil
          }
        }
        Button("Cancel", role: .cancel) { deletion = nil }
      }
    } message: {
      Text("This cannot be undone.")
    }.confirmationDialog(
      "Empty Trash permanently?", isPresented: $emptyTrash, titleVisibility: .visible
    ) {
      Button("Delete all permanently", role: .destructive) {
        Task {
          vault.error = nil
          for item in vault.trashItems {
            await vault.deletePermanently(item)
            if vault.error != nil { break }
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "All \(vault.trashItems.count) items will be permanently deleted. This cannot be undone.")
    }
  }
}

struct PDFUnlockSheet: View {
  @Bindable var vault: VaultController
  let entry: VaultEntry
  @State private var password = ""
  @State private var error: String?
  @State private var working = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Label("Password-protected PDF", systemImage: Icon.name("lock.doc")).font(.theme(.title2).bold())
      Text(entry.title).font(.theme(.headline))
      Text(
        "Enter the password to create an unlocked PDF copy in the same folder. Your encrypted original stays unchanged."
      ).foregroundStyle(.secondary)
      SecureField("PDF password", text: $password).textFieldStyle(.roundedBorder)
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button("Cancel") {
          vault.lockedPDF = nil
          dismiss()
        }
        Spacer()
        if working { ProgressView() }
        Button("Open unlocked copy") {
          working = true
          Task {
            do {
              try await vault.unlockCopy(entry, password: password)
              password = ""
              dismiss()
            } catch { self.error = error.localizedDescription }
            working = false
          }
        }.buttonStyle(.themedProminent).disabled(password.isEmpty || working)
      }
    }.padding(28).frame(minWidth: 360, idealWidth: 440).themedSheet()
  }
}
