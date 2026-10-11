import ImageIO
import NoteCraftCore
import SwiftUI
import UniformTypeIdentifiers

struct VaultRoot: View {
  @State private var vault = VaultController()
  @State private var folderPicker = false
  @State private var restoringStorage = true
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    Group {
      if restoringStorage {
        ProgressView("Opening your library…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if vault.root == nil {
        welcome
      } else if vault.showLibrary {
        Library(vault: vault, chooseFolder: { folderPicker = true })
      } else if let session = vault.active {
        if session.entryKind == .markdown {
          MarkdownWorkspace(vault: vault, session: session)
        } else if session.entryKind == .image {
          ImageFilePreview(vault: vault, session: session).id(session.id)
        } else {
          Workspace(
            document: Binding(
              get: { session.document },
              set: {
                session.document = $0
                vault.changed(session)
              }),
            activePage: Binding(
              get: { session.currentPageIndex },
              set: { vault.rememberPage(session, index: $0) }), fileURL: session.url,
            onBack: { Task { await vault.library() } }, tabs: vault.tabs,
            onSelectTab: { id in Task { await vault.selectTab(id) } }, saveStatus: session.status,
            history: session.history
          )
          .id(session.id)
        }
      }
    }
    .task {
      await vault.restoreLastStorage()
      restoringStorage = false
    }
    .sheet(item: $vault.lockedPDF) { entry in PDFUnlockSheet(vault: vault, entry: entry) }
    .preferredColorScheme(vault.root == nil || vault.showLibrary ? .dark : .light)
    .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder]) { result in
      do {
        let url = try result.get()
        Task { await vault.choose(url) }
      } catch { vault.error = error.localizedDescription }
    }
    .alert(
      "NoteCraft",
      isPresented: Binding(get: { vault.error != nil }, set: { if !$0 { vault.error = nil } })
    ) {
      Button("OK") { vault.error = nil }
      if let session = vault.active, session.dirty {
        Button("Retry save") { Task { await vault.save(session) } }
        Button("Save a copy") { Task { await vault.saveCopy(session) } }
      }
    } message: {
      Text(vault.error ?? "")
    }
    #if os(macOS)
      .onAppear { AppLifecycle.register(vault) }
    #endif
    .onChange(of: scenePhase) {
      if scenePhase != .active {
        Task {
          for session in vault.sessions {
            vault.rememberPage(session, index: session.currentPageIndex)
            if session.dirty { await vault.save(session) }
          }
        }
      } else if vault.showLibrary {
        Task { await vault.refresh() }
      }
    }
  }
  private var welcome: some View {
    VStack(spacing: 24) {
      Image(systemName: "folder.badge.plus").font(.system(size: 62, weight: .light))
        .foregroundStyle(Color.cyan)
      Text("Your notes. Your folder.").font(.system(size: 34, weight: .semibold))
      Text(
        "Choose a folder on this device or a connected drive.\nExisting PDFs, Markdown notes and folders appear alongside your notebooks."
      )
      .font(.system(size: 17)).foregroundStyle(Color(white: 0.72)).multilineTextAlignment(.center)
      .lineSpacing(5)
      Button {
        folderPicker = true
      } label: {
        Label("Choose storage folder", systemImage: "folder").font(.headline).padding(
          .horizontal, 24
        ).padding(.vertical, 14)
      }
      .buttonStyle(.borderedProminent).tint(Color(red: 0.02, green: 0.46, blue: 0.76))
      .accessibilityIdentifier("chooseStorageFolder")
      ForEach(vault.storages) { storage in
        Button("Open \(storage.name)") { Task { await vault.selectStorage(storage) } }
          .foregroundStyle(Color(white: 0.8))
      }
    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(Color.white)
      .background(Color(white: 0.035))
  }
}

struct Library: View {
  @Bindable var vault: VaultController
  let chooseFolder: () -> Void
  @AppStorage("libraryList") private var list = false
  @State private var search = ""
  @State private var favoritesOnly = false
  @State private var sidebar = true
  @State private var newPopover = false
  @State private var creation: CreationKind?
  @State private var pdfImport = false
  @AppStorage("librarySortNewest") private var sortNewest = false
  @State private var trashVisible = false
  @State private var renameEntry: VaultEntry?
  @State private var moveEntry: VaultEntry?
  @State private var lastTrashed: TrashItem?
  private let background = Color(white: 0.025)
  private let secondary = Color(white: 0.63)
  private let blue = Color(red: 0.02, green: 0.48, blue: 0.78)
  enum CreationKind: String, Identifiable {
    case notebook, whiteboard, markdown, folder
    var id: String { rawValue }
  }
  private var filtered: [VaultEntry] {
    let result = (favoritesOnly ? vault.favoriteEntries : vault.entries).filter {
      (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
        && (!favoritesOnly || vault.favorites.contains($0.url.vaultPath))
    }
    return sortNewest ? result.sorted { $0.modified > $1.modified } : result
  }
  private var filteredTrash: [TrashItem] {
    vault.trashItems.filter {
      search.isEmpty || $0.originalPath.localizedCaseInsensitiveContains(search)
    }
  }
  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        if sidebar && geometry.size.width > 700 {
          navigation.frame(width: min(300, geometry.size.width * 0.25)).padding(12)
        }
        VStack(alignment: .leading, spacing: 28) {
          header
          controls
          if vault.busy { ProgressView("Working…").tint(.white) }
          if !trashVisible && !favoritesOnly { breadcrumbs }
          ScrollView {
            if trashVisible {
              TrashLibrary(vault: vault, items: filteredTrash)
            } else if filtered.isEmpty {
              ContentUnavailableView(
                search.isEmpty ? "No documents here yet" : "No matching files",
                systemImage: "folder",
                description: Text(
                  search.isEmpty
                    ? "Create a notebook, whiteboard or text document with New."
                    : "Try another search."))
            } else if list {
              LazyVStack(spacing: 0) {
                ForEach(filtered) { entry in
                  row(entry)
                  Divider().overlay(Color(white: 0.18))
                }
              }
            } else {
              LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170, maximum: 250), spacing: 38)],
                alignment: .leading, spacing: 42
              ) {
                ForEach(filtered) { entry in card(entry) }
              }.padding(.top, 24).padding(.bottom, 30)
            }
          }
          HStack {
            Text("\(trashVisible ? filteredTrash.count : filtered.count) items")
            Spacer()
            Text(vault.folder?.lastPathComponent ?? "")
            Button("Add storage", action: chooseFolder)
          }.font(.system(size: 12)).foregroundStyle(secondary)
        }.padding(.horizontal, geometry.size.width > 700 ? 30 : 20).padding(.top, 28).padding(
          .bottom, 16)
      }.background(background).foregroundStyle(Color.white)
    }
    .overlay(alignment: .bottom) {
      if let item = lastTrashed, vault.trashItems.contains(where: { $0.id == item.id }) {
        HStack {
          Label("Moved to Trash", systemImage: "trash")
          Button("Undo") {
            Task {
              await vault.restore(item)
              lastTrashed = nil
            }
          }
          Button {
            lastTrashed = nil
          } label: {
            Image(systemName: "xmark")
          }.accessibilityLabel("Dismiss")
        }.padding(14).background(.regularMaterial, in: Capsule()).padding(.bottom, 45)
      }
    }
    .sheet(item: $renameEntry) { entry in LibraryRenameSheet(vault: vault, entry: entry) }
    .sheet(item: $moveEntry) { entry in LibraryMoveSheet(vault: vault, entry: entry) }
    .sheet(item: $creation) { kind in creationSheet(kind) }
    .fileImporter(
      isPresented: $pdfImport, allowedContentTypes: [.pdf, .image, .plainText, .noteCraft]
    ) { result in
      do {
        let url = try result.get()
        Task { await importFile(url) }
      } catch { vault.error = error.localizedDescription }
    }
    .onChange(of: vault.activeStorageID) {
      favoritesOnly = false
      trashVisible = false
      search = ""
      lastTrashed = nil
    }
    .task { await vault.refresh() }
  }
  private var navigation: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("NoteCraft").font(.system(size: 17, weight: .semibold))
        Spacer()
        Button {
          sidebar = false
        } label: {
          Image(systemName: "sidebar.left")
        }
      }.padding(.bottom, 24)
      navigationItem("Documents", symbol: "folder.fill", selected: !favoritesOnly && !trashVisible)
      {
        favoritesOnly = false
        trashVisible = false
        if let root = vault.root { Task { await vault.navigate(root) } }
      }
      navigationItem("Favorites", symbol: "bookmark.fill", selected: favoritesOnly && !trashVisible)
      {
        favoritesOnly = true
        trashVisible = false
      }
      navigationItem("Trash", symbol: "trash", selected: trashVisible) {
        trashVisible = true
        favoritesOnly = false
        Task { await vault.refresh() }
      }
      Divider().padding(.vertical, 12)
      Text("STORAGE FOLDERS").font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
      ForEach(vault.storages) { storage in
        Button {
          favoritesOnly = false
          trashVisible = false
          search = ""
          lastTrashed = nil
          Task { await vault.selectStorage(storage) }
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "externaldrive")
            Text(storage.name).lineLimit(2)
            Spacer(minLength: 0)
            if storage.id == vault.activeStorageID { Image(systemName: "checkmark").font(.caption) }
          }.font(.system(size: 14)).padding(10)
            .background(
              storage.id == vault.activeStorageID ? Color(white: 0.18) : .clear,
              in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityIdentifier("storage-" + storage.id.uuidString)
          .disabled(vault.busy)
      }
      Button(action: chooseFolder) { Label("Add storage folder", systemImage: "plus") }
        .font(.system(size: 13)).foregroundStyle(secondary).accessibilityIdentifier(
          "addStorageFolder")
      Spacer()
      if !vault.sessions.isEmpty {
        Text("OPEN DOCUMENTS").font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
        ForEach(vault.sessions) { session in
          Button {
            Task { await vault.selectTab(session.id) }
          } label: {
            Label(
              session.title,
              systemImage: session.entryKind == .markdown ? "doc.text" : "book.closed"
            ).lineLimit(1).font(.system(size: 13))
          }.padding(.vertical, 4)
        }
      }
    }.buttonStyle(.plain).padding(22).frame(maxHeight: .infinity).background(
      Color(white: 0.055), in: RoundedRectangle(cornerRadius: 24)
    ).overlay(RoundedRectangle(cornerRadius: 24).stroke(Color(white: 0.16), lineWidth: 1))
  }
  private func navigationItem(
    _ text: String, symbol: String, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(text, systemImage: symbol).font(
        .system(size: 17, weight: selected ? .semibold : .regular)
      ).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17).padding(
        .vertical, 16
      ).background(selected ? Color(white: 0.18) : .clear, in: Capsule())
    }.foregroundStyle(Color.white)
  }
  private var header: some View {
    HStack {
      if !sidebar {
        Button {
          sidebar = true
        } label: {
          Image(systemName: "sidebar.left")
        }.buttonStyle(.plain)
      }
      Menu {
        Button("Documents", systemImage: "folder") {
          trashVisible = false
          favoritesOnly = false
          if let root = vault.root { Task { await vault.navigate(root) } }
        }.accessibilityIdentifier("showDocuments")
        Button("Favorites", systemImage: "star") {
          trashVisible = false
          favoritesOnly = true
        }
        Button("Trash", systemImage: "trash") {
          trashVisible = true
          favoritesOnly = false
        }.accessibilityIdentifier("showTrash")
      } label: {
        Image(systemName: "folder.badge.gearshape")
      }
      .accessibilityLabel("Library locations")
      if !trashVisible && !favoritesOnly && vault.folder?.vaultPath != vault.root?.vaultPath {
        Button {
          if let folder = vault.folder {
            Task { await vault.navigate(folder.deletingLastPathComponent()) }
          }
        } label: {
          Image(systemName: "chevron.left").font(.system(size: 19)).frame(width: 42, height: 42)
            .background(Color(white: 0.12), in: Circle())
        }.buttonStyle(.plain)
      }
      Text(
        trashVisible
          ? "Trash"
          : favoritesOnly
            ? "Favorites"
            : vault.folder?.vaultPath == vault.root?.vaultPath
              ? "Documents" : vault.folder?.lastPathComponent ?? "Documents"
      ).font(.system(size: 32, weight: .semibold)).lineLimit(1)
      Spacer()
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
        TextField("Search", text: $search).frame(maxWidth: 180).accessibilityLabel("Search library")
        if !search.isEmpty {
          Button {
            search = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }.buttonStyle(.plain).accessibilityLabel("Clear search")
        }
      }.padding(12).background(Color(white: 0.11), in: Capsule()).overlay(
        Capsule().stroke(Color(white: 0.2)))
    }
  }
  private var controls: some View {
    HStack(spacing: 20) {
      if trashVisible {
        Text("Deleted items").foregroundStyle(secondary)
      } else {
        Menu {
          Button("Name") { sortNewest = false }
          Button("Last modified") { sortNewest = true }
        } label: {
          Label(sortNewest ? "Last modified" : "Name", systemImage: "line.3.horizontal.decrease")
        }.foregroundStyle(secondary)
      }
      Spacer()
      if !trashVisible && !favoritesOnly {
        Button {
          newPopover.toggle()
        } label: {
          Label("New", systemImage: "plus").font(.system(size: 17)).padding(.horizontal, 20)
            .padding(
              .vertical, 12
            ).background(blue, in: Capsule())
        }.buttonStyle(.plain)
          .popover(isPresented: $newPopover, arrowEdge: .top) { newMenu }.accessibilityIdentifier(
            "newDocumentMenu"
          ).disabled(trashVisible || favoritesOnly || vault.busy)
      }
      if !trashVisible {
        Button {
          list.toggle()
        } label: {
          Image(systemName: list ? "list.bullet" : "square.grid.2x2").font(.system(size: 22))
        }.buttonStyle(.plain).accessibilityLabel("Toggle grid or list")
      }
      Button {
        Task { await vault.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise").font(.system(size: 20))
      }.buttonStyle(.plain).accessibilityLabel("Refresh folder")
    }
  }
  private var newMenu: some View {
    VStack(spacing: 14) {
      HStack(spacing: 12) {
        newTile("Notebook", "book.closed", .notebook)
        newTile("Whiteboard", "rectangle.and.pencil.and.ellipsis", .whiteboard)
        newTile("Text Doc", "doc.text", .markdown)
      }
      Button {
        newPopover = false
        pdfImport = true
      } label: {
        Label("Import", systemImage: "square.and.arrow.down").frame(
          maxWidth: .infinity, alignment: .leading
        ).padding(16).background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16))
      }
      Button {
        begin(.folder)
      } label: {
        Label("Folder", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
          .padding(16).background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16))
      }
    }.buttonStyle(.plain).foregroundStyle(Color.white).padding(20).background(Color(white: 0.10))
      .frame(width: 420)
  }
  private func newTile(_ title: String, _ symbol: String, _ kind: CreationKind) -> some View {
    Button {
      begin(kind)
    } label: {
      VStack(spacing: 16) {
        Image(systemName: symbol).font(.system(size: 27, weight: .light))
        Text(title).font(.system(size: 14))
      }.frame(maxWidth: .infinity).frame(height: 112).background(
        Color(white: 0.16), in: RoundedRectangle(cornerRadius: 18))
    }
  }
  private func begin(_ kind: CreationKind) {
    newPopover = false
    creation = kind
  }
  private func card(_ entry: VaultEntry) -> some View {
    VStack(spacing: 12) {
      ZStack(alignment: .topTrailing) {
        Button {
          Task { await vault.open(entry) }
        } label: {
          VaultCover(entry: entry).frame(height: 180).frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
        Button {
          vault.favorite(entry)
        } label: {
          Image(systemName: vault.favorites.contains(entry.url.vaultPath) ? "star.fill" : "star")
            .font(
              .system(size: 22)
            ).foregroundStyle(
              vault.favorites.contains(entry.url.vaultPath) ? Color.yellow : Color(white: 0.55)
            ).padding(8)
        }.buttonStyle(.plain).accessibilityLabel(
          vault.favorites.contains(entry.url.vaultPath)
            ? "Remove favorite \(entry.title)" : "Favorite \(entry.title)")
      }
      Button {
        Task { await vault.open(entry) }
      } label: {
        Text(entry.title).font(.system(size: 15)).multilineTextAlignment(.center).lineLimit(2)
          .frame(maxWidth: .infinity)
      }.buttonStyle(.plain)
      HStack(spacing: 6) {
        Text(entry.kind == .folder ? "Folder" : entry.kind.rawValue.capitalized).font(
          .system(size: 11)
        ).foregroundStyle(secondary)
        entryMenu(entry)
      }
      Text(entry.modified.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11))
        .foregroundStyle(secondary)
    }.accessibilityElement(children: .contain).contextMenu { entryActions(entry) }
  }
  private func row(_ entry: VaultEntry) -> some View {
    HStack(spacing: 16) {
      Button {
        Task { await vault.open(entry) }
      } label: {
        HStack(spacing: 18) {
          VaultCover(entry: entry).frame(width: 48, height: 54)
          VStack(alignment: .leading, spacing: 5) {
            Text(entry.title).font(.system(size: 16))
            Text(entry.kind.rawValue.capitalized).font(.caption).foregroundStyle(secondary)
          }
          Spacer()
          Text(entry.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption)
            .foregroundStyle(secondary)
        }
      }.buttonStyle(.plain)
      Button {
        vault.favorite(entry)
      } label: {
        Image(systemName: vault.favorites.contains(entry.url.vaultPath) ? "star.fill" : "star")
      }.buttonStyle(.plain).foregroundStyle(.yellow)
      entryMenu(entry)
    }.padding(.vertical, 14).contextMenu { entryActions(entry) }
  }
  private var breadcrumbs: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        if let root = vault.root, let folder = vault.folder {
          Button(root.lastPathComponent) { Task { await vault.navigate(root) } }
          ForEach(pathComponents(root: root, folder: folder), id: \.self) { url in
            Image(systemName: "chevron.right").font(.system(size: 9))
            Button(url.lastPathComponent) { Task { await vault.navigate(url) } }
          }
        }
      }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(secondary)
    }
  }
  private func pathComponents(root: URL, folder: URL) -> [URL] {
    var components: [URL] = []
    var current = folder
    while current != root && current.vaultPath.hasPrefix(root.vaultPath + "/") {
      components.insert(current, at: 0)
      current = current.deletingLastPathComponent()
    }
    return components
  }
  private func entryMenu(_ entry: VaultEntry) -> some View {
    Menu {
      entryActions(entry)
    } label: {
      Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
    }.accessibilityLabel("Actions for \(entry.title)").disabled(vault.busy)
  }
  @ViewBuilder private func entryActions(_ entry: VaultEntry) -> some View {
    Button("Open", systemImage: "arrow.up.forward.square") { Task { await vault.open(entry) } }
    Button("Rename", systemImage: "pencil") { renameEntry = entry }
    Button("Move", systemImage: "folder") { moveEntry = entry }
    Button("Duplicate", systemImage: "doc.on.doc") { Task { await vault.duplicate(entry) } }
    Button(
      vault.favorites.contains(entry.url.vaultPath) ? "Remove favorite" : "Favorite",
      systemImage: "star"
    ) { vault.favorite(entry) }
    Divider()
    Button("Move to Trash", systemImage: "trash", role: .destructive) {
      Task {
        await vault.trash(entry)
        lastTrashed = vault.trashItems.first
      }
    }
  }
  private func creationSheet(_ kind: CreationKind) -> some View {
    VaultCreationSheet(kind: kind) { name, paper in
      creation = nil
      Task {
        switch kind {
        case .folder: await vault.createFolder(title: name)
        case .markdown: await vault.createText(title: name)
        case .notebook: await vault.create(title: name, paper: paper)
        case .whiteboard:
          await vault.create(title: name, paper: Paper(pattern: .blank), whiteboard: true)
        }
      }
    }
  }
  private func importFile(_ url: URL) async {
    guard let folder = vault.folder else { return }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let destination = await vault.files.availableURL(
        in: folder, title: url.deletingPathExtension().lastPathComponent,
        extension: url.pathExtension)
      if url.pathExtension.lowercased() == "notecraft" {
        let package = try await vault.packages.read(from: url)
        try await vault.packages.save(package, to: destination)
      } else {
        let source = try await vault.files.read(url)
        try await vault.files.write(source.data, to: destination, expected: nil, createOnly: true)
      }
      await vault.refresh()
    } catch { vault.error = error.localizedDescription }
  }
}

struct MarkdownWorkspace: View {
  @Bindable var vault: VaultController
  @Bindable var session: VaultSession
  @State private var preview = false
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button {
          Task { await vault.library() }
        } label: {
          Label("Documents", systemImage: "chevron.left")
        }
        Spacer()
        Text(session.title).font(.headline)
        Spacer()
        Button(preview ? "Edit" : "Preview") { preview.toggle() }
        Button("Save") { Task { await vault.save(session) } }
      }.padding(18)
      Divider()
      if preview {
        ScrollView {
          Text(
            (try? AttributedString(
              markdown: session.markdown, options: .init(interpretedSyntax: .full)))
              ?? AttributedString(session.markdown)
          ).frame(maxWidth: 800, alignment: .leading).padding(30).frame(
            maxWidth: .infinity, alignment: .center
          ).textSelection(.enabled)
        }
      } else {
        TextEditor(
          text: Binding(
            get: { session.markdown },
            set: {
              session.markdown = $0
              vault.changed(session)
            })
        ).font(.system(size: 16, design: .monospaced)).padding(20).scrollContentBackground(.hidden)
      }
      Divider()
      HStack {
        Text(session.url.lastPathComponent)
        Spacer()
        Text(session.status)
      }.font(.caption).foregroundStyle(Color(white: 0.4)).padding(12)
    }.foregroundStyle(Color(white: 0.12)).background(Color.white).environment(\.colorScheme, .light)
  }
}

private struct VaultCreationSheet: View {
  let kind: Library.CreationKind
  let onCreate: (String, Paper) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var paper = Paper()
  init(kind: Library.CreationKind, onCreate: @escaping (String, Paper) -> Void) {
    self.kind = kind
    self.onCreate = onCreate
    _title = State(
      initialValue: kind == .folder
        ? "New folder"
        : kind == .whiteboard
          ? "Untitled Whiteboard" : kind == .markdown ? "Untitled" : "Untitled Notebook")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Text("New \(kind.rawValue.capitalized)").font(.title2.bold())
      TextField("Name", text: $title).textFieldStyle(.roundedBorder)
      if kind == .notebook {
        Picker("Size", selection: $paper.size) {
          ForEach(PaperSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
        Picker("Paper", selection: $paper.pattern) {
          ForEach(PaperPattern.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        Toggle("Landscape", isOn: $paper.landscape)
      }
      if kind == .whiteboard {
        Text("An open canvas with two-finger pan and pinch zoom.").foregroundStyle(.secondary)
      }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Create") {
          onCreate(title, paper)
        }.buttonStyle(.borderedProminent).disabled(
          title.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }.padding(28).frame(minWidth: 340, idealWidth: 440).preferredColorScheme(.light)
      .foregroundStyle(Color.black)
  }
}

private struct ImageFilePreview: View {
  let vault: VaultController
  let session: VaultSession
  @State private var zoom = 1.0
  @State private var zoomBase = 1.0
  private var image: CGImage? {
    guard let asset = session.document.package.notebook.pages.first?.images.first,
      let data = session.document.package.assets[asset.filename],
      let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        Button {
          Task { await vault.library() }
        } label: {
          Label("Documents", systemImage: "chevron.left")
        }
        Spacer()
        VStack(spacing: 3) {
          Text(session.title).font(.headline).lineLimit(1)
          Label("Read only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Import into notebook", systemImage: "square.and.arrow.down") {
          Task { await vault.importImageNotebook(session) }
        }.disabled(vault.busy).accessibilityIdentifier("importImageNotebook")
      }.padding(16).background(.bar)
      GeometryReader { geometry in
        if let image {
          let scale = min(
            (geometry.size.width - 48) / Double(image.width),
            (geometry.size.height - 48) / Double(image.height))
          let size = CGSize(
            width: Double(image.width) * max(0.01, scale),
            height: Double(image.height) * max(0.01, scale))
          #if os(iOS)
            ZoomableNotebookPage(
              contentSize: size, viewportSize: geometry.size,
              pencilOnly: true, zoomEnabled: true, onActivity: {}
            ) {
              Image(decorative: image, scale: 1).resizable().frame(
                width: size.width, height: size.height)
            }
          #else
            ScrollView([.horizontal, .vertical]) {
              Image(decorative: image, scale: 1).resizable()
                .frame(width: size.width * zoom, height: size.height * zoom)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }.simultaneousGesture(
              MagnifyGesture().onChanged { value in
                zoom = min(6, max(1, zoomBase * value.magnification))
              }.onEnded { _ in zoomBase = zoom })
          #endif
        } else {
          ContentUnavailableView("Unable to display image", systemImage: "photo")
        }
      }.accessibilityIdentifier("readOnlyImagePreview")
    }.background(Color(white: 0.94)).preferredColorScheme(.light)
  }
}
