#if os(macOS)
  import SwiftUI
  import UniformTypeIdentifiers
  import NoteCraftCore

  struct Library: View {
    @State private var root: URL?
    @State private var folder: URL?
    @State private var entries: [URL] = []
    @State private var list = false
    @State private var folderPicker = false
    @State private var pdfPicker = false
    @State private var templatePicker = false
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var search = ""
    private var filtered: [URL] {
      entries.filter {
        search.isEmpty
          || $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(search)
      }
    }
    var body: some View {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          VStack(alignment: .leading, spacing: 5) {
            Text("NoteCraft").font(.system(size: 28, weight: .semibold))
            Text("Your notebooks, in your files.").foregroundStyle(.secondary)
          }
          Spacer()
          Menu {
            Button("Notebook", systemImage: "book.closed") { templatePicker = true }
            Button("Folder", systemImage: "folder.badge.plus") { createFolder() }
            Button("Import PDF", systemImage: "doc") { pdfPicker = true }
          } label: {
            Label("New", systemImage: "plus")
          }.menuStyle(.borderlessButton).padding(10).background(
            Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
          Button {
            list.toggle()
          } label: {
            Image(systemName: list ? "square.grid.2x2" : "list.bullet")
          }.help("Toggle grid and list")
          Button {
            folderPicker = true
          } label: {
            Image(systemName: "folder")
          }.help("Choose a storage folder")
        }
        HStack {
          if folder != root {
            Button {
              folder = folder?.deletingLastPathComponent()
              refresh()
            } label: {
              Image(systemName: "chevron.left")
            }
          }
          Text(folder?.lastPathComponent ?? "Notebooks").font(.headline)
          Spacer()
          Image(systemName: "magnifyingglass")
          TextField("Search notebooks", text: $search).frame(width: 220)
        }
        if busy { ProgressView("Preparing notebook…") }
        ScrollView {
          if filtered.isEmpty {
            ContentUnavailableView(
              "A fresh start", systemImage: "book.closed",
              description: Text(
                "Create a notebook or choose a folder containing NoteCraft documents."))
          } else if list {
            LazyVStack(spacing: 0) {
              ForEach(filtered, id: \.self) { url in
                Button {
                  open(url)
                } label: {
                  HStack {
                    Image(systemName: isFolder(url) ? "folder" : "book.closed")
                    Text(url.deletingPathExtension().lastPathComponent)
                    Spacer()
                    Image(systemName: "chevron.right")
                  }.padding(16)
                }.buttonStyle(.plain)
                Divider()
              }
            }
          } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 28)], spacing: 28) {
              ForEach(filtered, id: \.self) { url in
                Button {
                  open(url)
                } label: {
                  VStack(spacing: 12) {
                    ZStack(alignment: .leading) {
                      RoundedRectangle(cornerRadius: 7).fill(
                        isFolder(url)
                          ? Color.blue.opacity(0.14) : Color(red: 0.21, green: 0.36, blue: 0.57))
                      if !isFolder(url) {
                        Rectangle().fill(.black.opacity(0.12)).frame(width: 10).padding(
                          .leading, 12)
                      }
                      Image(systemName: isFolder(url) ? "folder" : "book.closed").font(
                        .system(size: 34, weight: .light)
                      ).foregroundStyle(isFolder(url) ? Color.blue : .white.opacity(0.8)).frame(
                        maxWidth: .infinity)
                    }.frame(width: 132, height: 170)
                    Text(url.deletingPathExtension().lastPathComponent).font(
                      .system(size: 13, weight: .medium)
                    ).lineLimit(2).frame(height: 34)
                  }
                }.buttonStyle(.plain)
              }
            }.padding(.vertical, 10)
          }
        }
        HStack {
          Text("\(entries.filter { !isFolder($0) }.count) notebooks")
          Spacer()
          Text(folder?.path ?? "").lineLimit(1)
          Button("Refresh") { refresh() }
        }.font(.caption).foregroundStyle(.secondary)
      }.padding(30).frame(minWidth: 640, minHeight: 500)
        .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder]) { result in
          do {
            let url = try result.get()
            selectRoot(url)
            let bookmark = try url.bookmarkData(
              options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "libraryFolder")
          } catch { errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $pdfPicker, allowedContentTypes: [.pdf]) { result in
          do {
            let url = try result.get()
            busy = true
            Task {
              do {
                let imported = try await ImportEngine().pdf(url)
                create(imported)
              } catch {
                busy = false
                errorMessage = error.localizedDescription
              }
            }
          } catch { errorMessage = error.localizedDescription }
        }
        .sheet(isPresented: $templatePicker) {
          TemplatePicker { paper in
            create(NotebookPackage(notebook: Notebook(pages: [Page(paper: paper)])))
          }
        }
        .alert(
          "Library error",
          isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
          Button("OK") { errorMessage = nil }
        } message: {
          Text(errorMessage ?? "")
        }
        .onAppear {
          initialize()
          refresh()
        }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in refresh() }
    }
    private func isFolder(_ url: URL) -> Bool { url.pathExtension != "notecraft" }
    private func selectRoot(_ url: URL) {
      if let root { root.stopAccessingSecurityScopedResource() }
      _ = url.startAccessingSecurityScopedResource()
      root = url
      folder = url
      refresh()
    }
    private func initialize() {
      guard root == nil else { return }
      do {
        if let bookmark = UserDefaults.standard.data(forKey: "libraryFolder") {
          var stale = false
          let url = try URL(
            resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
            bookmarkDataIsStale: &stale)
          selectRoot(url)
          if stale {
            UserDefaults.standard.set(
              try url.bookmarkData(options: .withSecurityScope), forKey: "libraryFolder")
          }
        } else {
          let directory = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
          ).appendingPathComponent("NoteCraft", isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          selectRoot(directory)
        }
      } catch { errorMessage = error.localizedDescription }
    }
    private func refresh() {
      guard let folder else { return }
      do {
        entries = try FileManager.default.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter {
          $0.pathExtension == "notecraft"
            || ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
              && $0.pathExtension.isEmpty)
        }.sorted {
          $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
      } catch { errorMessage = error.localizedDescription }
    }
    private func open(_ url: URL) {
      if isFolder(url) {
        folder = url
        refresh()
      } else {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) {
          _, _, error in
          if let error { Task { @MainActor in errorMessage = error.localizedDescription } }
        }
      }
    }
    private func createFolder() {
      guard let folder else { return }
      do {
        try FileManager.default.createDirectory(
          at: folder.appendingPathComponent("New folder " + UUID().uuidString.prefix(4)),
          withIntermediateDirectories: false)
        refresh()
      } catch { errorMessage = error.localizedDescription }
    }
    private func create(_ package: NotebookPackage) {
      guard let folder else { return }
      busy = true
      let url = folder.appendingPathComponent(
        package.notebook.title + " " + UUID().uuidString.prefix(4) + ".notecraft")
      Task {
        do {
          try await PackageStore().save(package, to: url)
          refresh()
          open(url)
        } catch { errorMessage = error.localizedDescription }
        busy = false
      }
    }
  }
#endif
