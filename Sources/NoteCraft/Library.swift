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
            onSelectTab: { id in Task { await vault.selectTab(id) } },
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
    .onOpenURL { url in
      // A theme opened from Files or shared to the app is added and used.
      guard url.pathExtension == "notecrafttheme" else { return }
      do {
        let theme = try ThemeStore.shared.install(from: url)
        ThemeStore.shared.select(theme.id)
      } catch { vault.error = error.localizedDescription }
    }
    .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder]) { result in
      do {
        let url = try result.get()
        Task { await vault.choose(url) }
      } catch { vault.error = error.localizedDescription }
    }
    .alert(
      "NotesCraft",
      isPresented: Binding(get: { vault.error != nil }, set: { if !$0 { vault.error = nil } })
    ) {
      Button("OK") { vault.error = nil }
      if let session = vault.active, session.dirty {
        Button("Retry save") {
          session.lastFailure = nil
          Task { await vault.save(session) }
        }
        Button("Save a copy") { Task { await vault.saveCopy(session) } }
      }
    } message: {
      Text(vault.error ?? "")
    }
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
      Symbol("folder.badge.plus").font(.theme(62, .light))
        .foregroundStyle(Color.theme(.secondaryAccent))
      Text("Your notes. Your folder.").font(.theme(34, .semibold))
      Text(
        "Choose a folder on this device or a connected drive.\nExisting PDFs, Markdown notes and folders appear alongside your notebooks."
      )
      .font(.theme(17)).foregroundStyle(Color.theme(.textSecondary)).multilineTextAlignment(.center)
      .lineSpacing(5)
      Button {
        folderPicker = true
      } label: {
        Label("Choose storage folder", systemImage: Icon.name("folder")).font(.theme(.headline))
      }
      .buttonStyle(.themedProminent(horizontal: 24, vertical: 14))
      .accessibilityIdentifier("chooseStorageFolder")
      ForEach(vault.storages) { storage in
        Button("Open \(storage.name)") { Task { await vault.selectStorage(storage) } }
          .foregroundStyle(Color.theme(.textSecondary))
      }
    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
      .foregroundStyle(Color.theme(.textPrimary)).background(Color.theme(.background))
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
  @State private var settingsSheet = false
  @State private var creation: CreationKind?
  @State private var pdfImport = false
  @AppStorage("librarySortNewest") private var sortNewest = false
  @State private var trashVisible = false
  @State private var marketplaceVisible = false
  @State private var renameEntry: VaultEntry?
  @State private var moveEntry: VaultEntry?
  @State private var lastTrashed: TrashItem?
  private var background: Color { Color.theme(.background) }
  private var secondary: Color { Color.theme(.textSecondary) }
  private var blue: Color { Color.theme(.accent) }
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
        Group {
          if marketplaceVisible {
            MarketplaceView(vault: vault, sidebar: $sidebar) { marketplaceVisible = false }
          } else {
            documents
          }
        }.padding(.horizontal, geometry.size.width > 700 ? 30 : 20).padding(.top, 28).padding(
          .bottom, 16)
      }.background(background).foregroundStyle(Color.theme(.textPrimary))
    }
    .overlay(alignment: .bottom) {
      if let item = lastTrashed, vault.trashItems.contains(where: { $0.id == item.id }) {
        HStack {
          Label("Moved to Trash", systemImage: Icon.name("trash"))
          Button("Undo") {
            Task {
              await vault.restore(item)
              lastTrashed = nil
            }
          }
          Button {
            lastTrashed = nil
          } label: {
            Symbol("xmark")
          }.accessibilityLabel("Dismiss")
        }.padding(14).background(.regularMaterial, in: Capsule()).padding(.bottom, 45)
      }
    }
    .sheet(isPresented: $settingsSheet) {
      SettingsView(
        storage: SettingsStorage(
          activeName: vault.storages.first { $0.id == vault.activeStorageID }?.name ?? "None",
          addFolder: chooseFolder))
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
      marketplaceVisible = false
      search = ""
      lastTrashed = nil
    }
    .task { await vault.refresh() }
  }
  // The documents of the folder, or of the favorites or the trash.
  private var documents: some View {
    VStack(alignment: .leading, spacing: 28) {
      header
      controls
      if vault.busy { ProgressView("Working…").tint(Color.theme(.textPrimary)) }
      if !trashVisible && !favoritesOnly { breadcrumbs }
      ScrollView {
        if trashVisible {
          TrashLibrary(vault: vault, items: filteredTrash)
        } else if filtered.isEmpty {
          ContentUnavailableView(
            search.isEmpty ? "No documents here yet" : "No matching files",
            systemImage: Icon.name("folder"),
            description: Text(
              search.isEmpty
                ? "Create a notebook, whiteboard or text document with New."
                : "Try another search."))
        } else if list {
          LazyVStack(spacing: 0) {
            ForEach(filtered) { entry in
              row(entry)
              Divider().overlay(Color.theme(.separator))
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
      }.font(.theme(12)).foregroundStyle(secondary)
    }
  }
  private var navigation: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("NotesCraft").font(.theme(17, .semibold))
        Spacer()
        Button {
          sidebar = false
        } label: {
          Symbol("sidebar.left")
        }
      }.padding(.bottom, 24)
      navigationItem(
        "Documents", symbol: "folder.fill",
        selected: !favoritesOnly && !trashVisible && !marketplaceVisible
      ) {
        favoritesOnly = false
        trashVisible = false
        marketplaceVisible = false
        if let root = vault.root { Task { await vault.navigate(root) } }
      }
      navigationItem(
        "Favorites", symbol: "bookmark.fill",
        selected: favoritesOnly && !trashVisible && !marketplaceVisible
      ) {
        favoritesOnly = true
        trashVisible = false
        marketplaceVisible = false
      }
      navigationItem("Trash", symbol: "trash", selected: trashVisible && !marketplaceVisible) {
        trashVisible = true
        favoritesOnly = false
        marketplaceVisible = false
        Task { await vault.refresh() }
      }
      navigationItem("Marketplace", symbol: "storefront", selected: marketplaceVisible) {
        marketplaceVisible = true
      }.accessibilityIdentifier("showMarketplace")
      Divider().padding(.vertical, 12)
      Text("STORAGE FOLDERS").font(.theme(11, .medium)).foregroundStyle(secondary)
      ForEach(vault.storages) { storage in
        Button {
          favoritesOnly = false
          trashVisible = false
          marketplaceVisible = false
          search = ""
          lastTrashed = nil
          Task { await vault.selectStorage(storage) }
        } label: {
          HStack(spacing: 10) {
            Symbol("externaldrive")
            Text(storage.name).lineLimit(2)
            Spacer(minLength: 0)
            if storage.id == vault.activeStorageID { Symbol("checkmark").font(.theme(.caption)) }
          }.font(.theme(14)).padding(10)
            .background(
              storage.id == vault.activeStorageID ? Color.theme(.surfaceRaised) : .clear,
              in: RoundedRectangle(cornerRadius: 10))
        }.accessibilityIdentifier("storage-" + storage.id.uuidString)
          .disabled(vault.busy)
      }
      Button(action: chooseFolder) { Label("Add storage folder", systemImage: Icon.name("plus")) }
        .font(.theme(13)).foregroundStyle(secondary).accessibilityIdentifier(
          "addStorageFolder")
      Spacer()
      if !vault.sessions.isEmpty {
        Text("OPEN DOCUMENTS").font(.theme(11, .medium)).foregroundStyle(secondary)
        ForEach(vault.sessions) { session in
          Button {
            Task { await vault.selectTab(session.id) }
          } label: {
            Label(
              session.title,
              systemImage: Icon.name(session.entryKind == .markdown ? "doc.text" : "book.closed")
            ).lineLimit(1).font(.theme(13))
          }.padding(.vertical, 4)
        }
      }
    }.buttonStyle(.plain).padding(22).frame(maxHeight: .infinity).background(
      Color.theme(.surface), in: RoundedRectangle(cornerRadius: .corner(24))
    ).overlay(RoundedRectangle(cornerRadius: .corner(24)).stroke(Color.theme(.separator), lineWidth: 1))
  }
  private func navigationItem(
    _ text: String, symbol: String, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label { Text(text).lineLimit(1).minimumScaleFactor(0.8) } icon: { Symbol(symbol) }.font(
        .system(size: 17, weight: selected ? .semibold : .regular)
      ).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17).padding(
        .vertical, 16
      ).background(selected ? Color.theme(.surfaceRaised) : .clear, in: Capsule())
    }.foregroundStyle(Color.theme(.textPrimary))
  }
  private var header: some View {
    HStack {
      if !sidebar {
        Button {
          sidebar = true
        } label: {
          Symbol("sidebar.left")
        }.buttonStyle(.plain)
      }
      Menu {
        Button("Documents", systemImage: Icon.name("folder")) {
          trashVisible = false
          favoritesOnly = false
          marketplaceVisible = false
          if let root = vault.root { Task { await vault.navigate(root) } }
        }.accessibilityIdentifier("showDocuments")
        Button("Favorites", systemImage: Icon.name("star")) {
          trashVisible = false
          favoritesOnly = true
          marketplaceVisible = false
        }
        Button("Trash", systemImage: Icon.name("trash")) {
          trashVisible = true
          favoritesOnly = false
          marketplaceVisible = false
        }.accessibilityIdentifier("showTrash")
        Button("Marketplace", systemImage: Icon.name("storefront")) {
          marketplaceVisible = true
        }.accessibilityIdentifier("showMarketplaceMenu")
      } label: {
        Symbol("folder.badge.gearshape")
      }
      .accessibilityLabel("Library locations")
      if !trashVisible && !favoritesOnly && vault.folder?.vaultPath != vault.root?.vaultPath {
        Button {
          if let folder = vault.folder {
            Task { await vault.navigate(folder.deletingLastPathComponent()) }
          }
        } label: {
          Symbol("chevron.left").font(.theme(19)).frame(width: 42, height: 42)
            .background(Color.theme(.field), in: Circle())
        }.buttonStyle(.plain)
      }
      Text(
        trashVisible
          ? "Trash"
          : favoritesOnly
            ? "Favorites"
            : vault.folder?.vaultPath == vault.root?.vaultPath
              ? "Documents" : vault.folder?.lastPathComponent ?? "Documents"
      ).font(.theme(32, .semibold)).lineLimit(1)
      Spacer()
      HStack(spacing: 10) {
        Symbol("magnifyingglass")
        TextField("Search", text: $search).frame(maxWidth: 180).accessibilityLabel("Search library")
        if !search.isEmpty {
          Button {
            search = ""
          } label: {
            Symbol("xmark.circle.fill")
          }.buttonStyle(.plain).accessibilityLabel("Clear search")
        }
      }.padding(12).background(Color.theme(.field), in: Capsule()).overlay(
        Capsule().stroke(Color.theme(.separator)))
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
          Label(sortNewest ? "Last modified" : "Name", systemImage: Icon.name("line.3.horizontal.decrease"))
        }.foregroundStyle(secondary)
      }
      Spacer()
      if !trashVisible && !favoritesOnly {
        Button {
          newPopover.toggle()
        } label: {
          Label("New", systemImage: Icon.name("plus")).font(.theme(17)).padding(.horizontal, 20)
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
          Symbol(list ? "list.bullet" : "square.grid.2x2").font(.theme(22))
        }.buttonStyle(.plain).accessibilityLabel("Toggle grid or list")
      }
      Button {
        Task { await vault.refresh() }
      } label: {
        Symbol("arrow.clockwise").font(.theme(20))
      }.buttonStyle(.plain).accessibilityLabel("Refresh folder")
      Button {
        settingsSheet = true
      } label: {
        Symbol("gearshape").font(.theme(21))
      }.buttonStyle(.plain).accessibilityLabel("Settings")
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
        Label("Import", systemImage: Icon.name("square.and.arrow.down")).frame(
          maxWidth: .infinity, alignment: .leading
        ).padding(16).background(Color.theme(.surfaceRaised), in: RoundedRectangle(cornerRadius: .corner(16)))
      }
      Button {
        begin(.folder)
      } label: {
        Label("Folder", systemImage: Icon.name("folder")).frame(maxWidth: .infinity, alignment: .leading)
          .padding(16).background(Color.theme(.surfaceRaised), in: RoundedRectangle(cornerRadius: .corner(16)))
      }
    }.buttonStyle(.plain).foregroundStyle(Color.theme(.textPrimary)).padding(20)
      .background(Color.theme(.surface))
      .adaptiveWidth(420)
  }
  private func newTile(_ title: String, _ symbol: String, _ kind: CreationKind) -> some View {
    Button {
      begin(kind)
    } label: {
      VStack(spacing: 16) {
        Symbol(symbol).font(.theme(27, .light))
        Text(title).font(.theme(14))
      }.frame(maxWidth: .infinity).frame(height: 112).background(
        Color.theme(.surfaceRaised), in: RoundedRectangle(cornerRadius: .corner(18)))
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
          Symbol(vault.favorites.contains(entry.url.vaultPath) ? "star.fill" : "star")
            .font(
              .system(size: 22)
            ).foregroundStyle(
              vault.favorites.contains(entry.url.vaultPath) ? Color.theme(.favorite) : Color.theme(.textTertiary)
            ).padding(8)
        }.buttonStyle(.plain).accessibilityLabel(
          vault.favorites.contains(entry.url.vaultPath)
            ? "Remove favorite \(entry.title)" : "Favorite \(entry.title)")
      }
      Button {
        Task { await vault.open(entry) }
      } label: {
        Text(entry.title).font(.theme(15)).multilineTextAlignment(.center).lineLimit(2)
          .frame(maxWidth: .infinity)
      }.buttonStyle(.plain)
      HStack(spacing: 6) {
        Text(entry.kind == .folder ? "Folder" : entry.kind.rawValue.capitalized).font(
          .system(size: 11)
        ).foregroundStyle(secondary)
        entryMenu(entry)
      }
      Text(entry.modified.formatted(date: .abbreviated, time: .shortened)).font(.theme(11))
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
            Text(entry.title).font(.theme(16))
            Text(entry.kind.rawValue.capitalized).font(.theme(.caption)).foregroundStyle(secondary)
          }
          Spacer()
          Text(entry.modified.formatted(date: .abbreviated, time: .shortened)).font(.theme(.caption))
            .foregroundStyle(secondary)
        }
      }.buttonStyle(.plain)
      Button {
        vault.favorite(entry)
      } label: {
        Symbol(vault.favorites.contains(entry.url.vaultPath) ? "star.fill" : "star")
      }.buttonStyle(.plain).foregroundStyle(Color.theme(.favorite))
      entryMenu(entry)
    }.padding(.vertical, 14).contextMenu { entryActions(entry) }
  }
  private var breadcrumbs: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        if let root = vault.root, let folder = vault.folder {
          Button(root.lastPathComponent) { Task { await vault.navigate(root) } }
          ForEach(pathComponents(root: root, folder: folder), id: \.self) { url in
            Symbol("chevron.right").font(.theme(9))
            Button(url.lastPathComponent) { Task { await vault.navigate(url) } }
          }
        }
      }.buttonStyle(.plain).font(.theme(12)).foregroundStyle(secondary)
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
      Symbol("ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
    }.accessibilityLabel("Actions for \(entry.title)").disabled(vault.busy)
  }
  @ViewBuilder private func entryActions(_ entry: VaultEntry) -> some View {
    Button("Open", systemImage: Icon.name("arrow.up.forward.square")) { Task { await vault.open(entry) } }
    Button("Rename", systemImage: Icon.name("pencil")) { renameEntry = entry }
    Button("Move", systemImage: Icon.name("folder")) { moveEntry = entry }
    Button("Duplicate", systemImage: Icon.name("doc.on.doc")) { Task { await vault.duplicate(entry) } }
    Button(
      vault.favorites.contains(entry.url.vaultPath) ? "Remove favorite" : "Favorite",
      systemImage: Icon.name("star")
    ) { vault.favorite(entry) }
    Divider()
    Button("Move to Trash", systemImage: Icon.name("trash"), role: .destructive) {
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
          await vault.create(title: name, paper: paper, whiteboard: true)
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
          Label("Documents", systemImage: Icon.name("chevron.left"))
        }
        Spacer()
        Text(session.title).font(.theme(.headline))
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
      }.font(.theme(.caption)).foregroundStyle(Color.theme(.sheetSecondaryText)).padding(12)
    }.foregroundStyle(Color.theme(.sheetText)).background(Color.theme(.sheet))
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
    _paper = State(initialValue: Paper(pattern: kind == .whiteboard ? .blank : .ruled))
    _title = State(
      initialValue: kind == .folder
        ? "New folder"
        : kind == .whiteboard
          ? "Untitled Whiteboard" : kind == .markdown ? "Untitled" : "Untitled Notebook")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Text("New \(kind.rawValue.capitalized)").font(.theme(.title2).bold())
      TextField("Name", text: $title).textFieldStyle(.roundedBorder)
      // The name field stays outside the scroll view: with the keyboard up the sheet shrinks and
      // only the options scroll, so what is typed never moves out of sight.
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if kind == .notebook {
            Picker("Size", selection: $paper.size) {
              ForEach(PaperSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Toggle("Landscape", isOn: $paper.landscape)
          }
          if kind == .notebook || kind == .whiteboard {
            PaperPatternPicker(pattern: $paper.pattern, whiteboard: kind == .whiteboard)
          }
          if kind == .whiteboard {
            Text("An open canvas with two-finger pan and pinch zoom.").foregroundStyle(.secondary)
          }
        }
      }.scrollDismissesKeyboard(.interactively)
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Create") {
          onCreate(title, paper)
        }.buttonStyle(.themedProminent).disabled(
          title.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }.padding(28).frame(minWidth: 340, idealWidth: 440)
      .foregroundStyle(Color.theme(.sheetText)).background(Color.theme(.sheet))
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
          Label("Documents", systemImage: Icon.name("chevron.left"))
        }
        Spacer()
        VStack(spacing: 3) {
          Text(session.title).font(.theme(.headline)).lineLimit(1)
          Label("Read only", systemImage: Icon.name("lock")).font(.theme(.caption)).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Import into notebook", systemImage: Icon.name("square.and.arrow.down")) {
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
              pencilOnly: true, zoomEnabled: true
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
          ContentUnavailableView("Unable to display image", systemImage: Icon.name("photo"))
        }
      }.accessibilityIdentifier("readOnlyImagePreview")
    }.background(Color.theme(.sheet))
  }
}
