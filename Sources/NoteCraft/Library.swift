import NoteCraftCore
import SwiftUI
import UniformTypeIdentifiers

struct VaultRoot: View {
  @State private var vault = VaultController()
  @State private var folderPicker = false
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    Group {
      if vault.root == nil {
        welcome
      } else if vault.showLibrary {
        Library(vault: vault, chooseFolder: { folderPicker = true })
      } else if let session = vault.active {
        if session.entryKind == .markdown {
          MarkdownWorkspace(vault: vault, session: session)
        } else {
          Workspace(
            document: Binding(
              get: { session.document },
              set: {
                session.document = $0
                vault.changed(session)
              }), fileURL: session.url,
            onBack: { Task { await vault.library() } }, tabs: vault.tabs,
            onSelectTab: { id in Task { await vault.selectTab(id) } }, saveStatus: session.status,
            history: session.history
          )
          .id(session.id)
        }
      }
    }
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
        Task { for session in vault.sessions where session.dirty { await vault.save(session) } }
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
      if let previous = vault.previousFolder() {
        Button("Open \(previous.lastPathComponent)") { Task { await vault.choose(previous) } }
          .foregroundStyle(Color(white: 0.8))
      }
    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(Color.white)
      .background(Color(white: 0.035))
  }
}

struct Library: View {
  @Bindable var vault: VaultController
  let chooseFolder: () -> Void
  @State private var list = false
  @State private var search = ""
  @State private var favoritesOnly = false
  @State private var sidebar = true
  @State private var newPopover = false
  @State private var creation: CreationKind?
  @State private var pdfImport = false
  @State private var sortNewest = false
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
        && (!favoritesOnly || vault.favorites.contains($0.url.path))
    }
    return sortNewest ? result.sorted { $0.modified > $1.modified } : result
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
          if vault.busy { ProgressView("Opening…").tint(.white) }
          ScrollView {
            if filtered.isEmpty {
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
            Text("\(filtered.count) items")
            Spacer()
            Text(vault.folder?.lastPathComponent ?? "")
            Button("Change folder", action: chooseFolder)
          }.font(.system(size: 12)).foregroundStyle(secondary)
        }.padding(.horizontal, geometry.size.width > 700 ? 30 : 20).padding(.top, 28).padding(
          .bottom, 16)
      }.background(background).foregroundStyle(Color.white)
    }
    .sheet(item: $creation) { kind in creationSheet(kind) }
    .fileImporter(
      isPresented: $pdfImport, allowedContentTypes: [.pdf, .image, .plainText, .noteCraft]
    ) { result in
      do {
        let url = try result.get()
        Task { await importFile(url) }
      } catch { vault.error = error.localizedDescription }
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
      navigationItem("Documents", symbol: "folder.fill", selected: !favoritesOnly) {
        favoritesOnly = false
        if let root = vault.root { Task { await vault.navigate(root) } }
      }
      navigationItem("Favorites", symbol: "bookmark.fill", selected: favoritesOnly) {
        favoritesOnly = true
      }
      Divider().padding(.vertical, 12)
      Text("STORAGE FOLDER").font(.system(size: 11, weight: .medium)).foregroundStyle(secondary)
      Label(vault.root?.lastPathComponent ?? "", systemImage: "externaldrive").font(
        .system(size: 14)
      ).lineLimit(2)
      Button("Choose another folder", action: chooseFolder).font(.system(size: 13)).foregroundStyle(
        secondary)
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
      if vault.folder != vault.root {
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
        favoritesOnly
          ? "Favorites"
          : vault.folder == vault.root
            ? "Documents" : vault.folder?.lastPathComponent ?? "Documents"
      ).font(.system(size: 32, weight: .semibold)).lineLimit(1)
      Spacer()
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
        TextField("Search", text: $search).frame(maxWidth: 180)
      }.padding(12).background(Color(white: 0.11), in: Capsule()).overlay(
        Capsule().stroke(Color(white: 0.2)))
    }
  }
  private var controls: some View {
    HStack(spacing: 20) {
      Menu {
        Button("Name") { sortNewest = false }
        Button("Last modified") { sortNewest = true }
      } label: {
        Label(sortNewest ? "Last modified" : "All", systemImage: "line.3.horizontal.decrease")
      }.foregroundStyle(secondary)
      Spacer()
      Button {
        newPopover.toggle()
      } label: {
        Label("New", systemImage: "plus").font(.system(size: 17)).padding(.horizontal, 20).padding(
          .vertical, 12
        ).background(blue, in: Capsule())
      }.buttonStyle(.plain)
        .popover(isPresented: $newPopover, arrowEdge: .top) { newMenu }.accessibilityIdentifier(
          "newDocumentMenu")
      Button {
        list.toggle()
      } label: {
        Image(systemName: list ? "list.bullet" : "square.grid.2x2").font(.system(size: 22))
      }.buttonStyle(.plain).accessibilityLabel("Toggle grid or list")
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
          Image(systemName: vault.favorites.contains(entry.url.path) ? "star.fill" : "star").font(
            .system(size: 22)
          ).foregroundStyle(
            vault.favorites.contains(entry.url.path) ? Color.yellow : Color(white: 0.55)
          ).padding(8)
        }.buttonStyle(.plain)
      }
      Button {
        Task { await vault.open(entry) }
      } label: {
        Text(entry.title).font(.system(size: 15)).multilineTextAlignment(.center).lineLimit(2)
          .frame(maxWidth: .infinity)
      }.buttonStyle(.plain)
      Text(entry.modified.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11))
        .foregroundStyle(secondary)
    }.accessibilityElement(children: .contain)
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
        Image(systemName: vault.favorites.contains(entry.url.path) ? "star.fill" : "star")
      }.buttonStyle(.plain).foregroundStyle(.yellow)
    }.padding(.vertical, 14)
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
