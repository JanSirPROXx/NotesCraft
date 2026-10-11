import NoteCraftCore
import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  import VisionKit
#endif

struct NotebookExport: FileDocument {
  static let readableContentTypes: [UTType] = [.pdf, .png]
  var data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct Workspace: View {
  @Binding var document: NoteDocument
  @Binding var activePage: Int
  let fileURL: URL?
  var onBack: (() -> Void)? = nil
  var tabs: [WorkspaceTab] = []
  var onSelectTab: ((UUID) -> Void)? = nil
  var history: EditHistory = EditHistory()
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(\.openWindow) private var openWindow
  @State private var tool: InkTool = .pen
  @State private var previousTool: InkTool = .pen
  @AppStorage("inkColorHex") private var colorHex = "#1F2B3D"
  @AppStorage("penWidth") private var penWidth = 2.5
  @AppStorage("highlighterWidth") private var highlighterWidth = 16.0
  @AppStorage("eraserWidth") private var eraserWidth = 12.0
  @AppStorage("penWidth1") private var firstWidth = 1.0
  @AppStorage("penWidth2") private var secondWidth = 2.5
  @AppStorage("penWidth3") private var thirdWidth = 5.0
  @AppStorage("highlighterWidth1") private var highlighterFirst = 10.0
  @AppStorage("highlighterWidth2") private var highlighterSecond = 16.0
  @AppStorage("highlighterWidth3") private var highlighterThird = 26.0
  @State private var elements = ElementLibrary.shared
  @State private var selectedElementID: UUID?
  @State private var saveElementSheet = false
  @State private var elementName = "Element"
  @State private var fillShapes = false
  @State private var shapePreset: ShapePreset = .automatic
  @State private var hexColor = "#1F2B3D"
  @AppStorage("penStyle") private var penStyle: PenStyle = .ballpoint
  @State private var eraserMode: EraserMode = .stroke
  @State private var highlighterOnly = false
  @State private var autoDeselect = false
  @State private var straightHighlight = false
  @AppStorage("pencilOnlyDrawing") private var pencilOnly = true
  @AppStorage("holdToShape") private var holdToShape = true
  @AppStorage("scratchToErase") private var scratchToErase = true
  @State private var pagePullProgress = 0.0
  @State private var settings = false
  @State private var thumbnails = false
  @State private var navigator = false
  @State private var pdfForms = false
  @State private var templateSheet = false
  @State private var paperSheet = false
  @State private var renameSheet = false
  @State private var titleDraft = ""
  @State private var importer = false
  @State private var importing = false
  @State private var photoLibrary = false
  @State private var photoItem: PhotosPickerItem?
  @State private var scanner = false
  @State private var importType: UTType = .pdf
  @State private var exporter = false
  @State private var exportData = Data()
  @State private var exportType: UTType = .pdf
  @State private var selectInk = true
  @State private var selectImages = true
  @State private var selectTexts = true
  private var clipboardImages: [PageAsset] {
    get { InkClipboard.shared.images }
    nonmutating set { InkClipboard.shared.images = newValue }
  }
  private var clipboardTexts: [TextBox] {
    get { InkClipboard.shared.texts }
    nonmutating set { InkClipboard.shared.texts = newValue }
  }
  @State private var errorMessage: String?
  @State private var selection: Set<UUID> = []
  @State private var selectionMenuPresented = false
  private var undoStack: [NotebookPackage] {
    get { history.undo }
    nonmutating set { history.undo = newValue }
  }
  private var redoStack: [NotebookPackage] {
    get { history.redo }
    nonmutating set { history.redo = newValue }
  }
  private var clipboard: [Stroke] {
    get { InkClipboard.shared.strokes }
    nonmutating set { InkClipboard.shared.strokes = newValue }
  }
  @State private var textSheet = false
  @State private var text = ""
  @State private var textSize = 20.0
  @State private var textFont = "System"
  @State private var textAlignment = "left"
  @State private var textBorder = false
  @State private var textBackground = false
  @State private var textWidth = 280.0
  @State private var editingTextID: UUID?
  @State private var insertPoint = Point(60, 80)
  @State private var searchVisible = false
  @State private var search = ""
  @State private var documentSearch = DocumentSearch()
  @AppStorage("horizontalNotebookPages") private var horizontalSetting = true
  @AppStorage("infiniteScroll") private var infinite = false
  // Infinite scrolling is one continuous vertical sheet, so it overrides page-by-page layout.
  private var horizontal: Bool { horizontalSetting && !infinite }
  @State private var pageHUD = false
  @State private var lastHUDActivation = Date.distantPast
  @State private var pageHUDTask: Task<Void, Never>?
  @State private var horizontalPageID: UUID?
  @State private var pageChangedByScroll = false
  // A blank page after the last one: swiping onto it turns it into a real page, so adding a
  // page is part of the swipe instead of a separate pull-and-hold gesture.
  @State private var trailingPage: Page?
  @AppStorage("keepZoomOnNewPage") private var keepZoomOnNewPage = true
  @State private var pageZoom = NotebookZoomMemory()
  @State private var zoom = 1.0
  @State private var zoomBase = 1.0
  @State private var customColor = Color.black
  @State private var imageSelection: UUID?
  private var boardViewport: ViewTransform {
    get { notebook.viewport ?? ViewTransform(scale: 1, offset: Point(30, 30)) }
    nonmutating set {
      document.package.notebook.viewport = newValue
      document.package.notebook.revision += 1
    }
  }
  private let accent = Color(red: 0.17, green: 0.36, blue: 0.72)
  private var minimumWidth: Double {
    #if os(macOS)
      600
    #else
      0
    #endif
  }
  private var color: InkColor {
    get { InkColor(hex: colorHex) ?? .ink }
    nonmutating set { colorHex = newValue.hex }
  }
  private var colorBinding: Binding<InkColor> {
    Binding(get: { color }, set: { color = $0 })
  }
  // Each tool remembers its own size; a shared value made the eraser and highlighter
  // inherit the pen's thickness.
  private var width: Double {
    get {
      switch tool {
      case .highlighter: highlighterWidth
      case .eraser: eraserWidth
      default: penWidth
      }
    }
    nonmutating set {
      switch tool {
      case .highlighter: highlighterWidth = newValue
      case .eraser: eraserWidth = newValue
      default: penWidth = newValue
      }
    }
  }
  private var widthBinding: Binding<Double> { Binding(get: { width }, set: { width = $0 }) }
  private var widthSlots: Binding<[Double]> {
    if tool == .highlighter {
      Binding(
        get: { [highlighterFirst, highlighterSecond, highlighterThird] },
        set: { (highlighterFirst, highlighterSecond, highlighterThird) = ($0[0], $0[1], $0[2]) })
    } else {
      Binding(
        get: { [firstWidth, secondWidth, thirdWidth] },
        set: { (firstWidth, secondWidth, thirdWidth) = ($0[0], $0[1], $0[2]) })
    }
  }
  @ViewBuilder private func notebookScroller(_ geometry: GeometryProxy) -> some View {
    ScrollViewReader { proxy in
      ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
        if horizontal {
          LazyHStack(alignment: .top, spacing: 0) {
            ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, p in
              notebookPage(p, index: index, size: geometry.size)
                .frame(width: geometry.size.width).id(p.id)
            }
            if let next = trailingPage {
              // Same ID as the page it becomes, so committing it causes no visual jump.
              notebookPage(next, index: notebook.pages.count, size: geometry.size)
                .frame(width: geometry.size.width).id(next.id).allowsHitTesting(false)
            }
          }.scrollTargetLayout()
        } else {
          LazyVStack(spacing: infinite ? 0 : 28) {
            ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, p in
              notebookPage(p, index: index, size: geometry.size, vertical: true)
            }
          }.scrollTargetLayout().frame(maxWidth: .infinity)
        }
      }.frame(width: geometry.size.width, height: geometry.size.height)
        .scrollTargetBehavior(NotebookPageBehavior(horizontal: horizontal))
        .scrollPosition(id: $horizontalPageID, anchor: .topLeading)
        .accessibilityIdentifier("notebookScrollView")
        .background(Color(red: 0.105, green: 0.11, blue: 0.115)).onChange(of: activePage) {
          previous, current in
          if pageChangedByScroll {
            pageChangedByScroll = false
            return
          }
          let move = {
            if horizontal {
              horizontalPageID = page.id
            } else {
              proxy.scrollTo(page.id, anchor: .top)
            }
          }
          // A distant jump should not build/render every page along an animation.
          if abs(current - previous) > 1 { move() } else { withAnimation { move() } }
        }.onChange(of: horizontalPageID) {
          if let id = horizontalPageID, let next = trailingPage, id == next.id {
            pageChangedByScroll = true
            trailingPage = nil
            appendPage(next)
            return
          }
          if let id = horizontalPageID,
            let index = notebook.pages.firstIndex(where: { $0.id == id })
          {
            if activePage != index {
              pageChangedByScroll = true
              activePage = index
            }
          }
        }.task(id: horizontal) {
          let targetID = page.id
          // Changing axes rebuilds the page layout. Reapply the position even when
          // the selected page ID has not changed.
          await Task.yield()
          proxy.scrollTo(targetID, anchor: .topLeading)
          horizontalPageID = targetID
        }
    }
  }
  private var notebook: Notebook { document.package.notebook }
  private var page: Page { notebook.pages[min(activePage, notebook.pages.count - 1)] }
  private var editorContent: some View {
    VStack(spacing: 0) {
      tabBar
      toolBar
      if searchVisible { searchBar }
      if let imageSelection { imageControls(imageSelection) }
      HStack(spacing: 0) {
        if thumbnails { pageSidebar }
        GeometryReader { geometry in
          if notebook.kind == .whiteboard {
            pageView(
              page, index: 0, availableWidth: geometry.size.width, boardHeight: geometry.size.height
            )
          } else {
            notebookScroller(geometry)
          }
        }
      }
      .overlay(alignment: .top) {
        contextualToolBar.padding(.top, 8)
      }
      .overlay(alignment: .bottomTrailing) {
        if pageHUD && notebook.kind != .whiteboard {
          Text("\(activePage + 1) / \(notebook.pages.count)")
            .font(.system(size: 13, weight: .medium)).monospacedDigit()
            .padding(10).background(.regularMaterial, in: Capsule()).padding(18)
            .allowsHitTesting(false).accessibilityIdentifier("pageIndicator")
        }
      }
      .overlay(alignment: .bottom) {
        if pagePullProgress > 0 {
          HStack(spacing: 10) {
            ProgressView(value: pagePullProgress).frame(width: 60)
            Text("Keep pulling to add a page").font(.system(size: 12))
          }.padding(10).background(.regularMaterial, in: Capsule()).padding(18)
            .allowsHitTesting(false).accessibilityIdentifier("pagePullProgress")
        }
      }
      if importing { ProgressView("Importing…").padding(8) }
    }
    .background(Color.white).foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22)).tint(accent)
    .environment(\.colorScheme, .light).preferredColorScheme(.dark)
    .frame(minWidth: minimumWidth, minHeight: 500)
  }
  private var syncedContent: some View {
    // Split into stages: one chained expression this long exceeds the type checker.
    editorContent
    .onChange(of: activePage) { showPageIndicator() }
    .onChange(of: notebook.pages.count) {
      showPageIndicator()
      refreshTrailingPage()
    }
    .onChange(of: horizontal) { refreshTrailingPage() }
    .onChange(of: lastPageHasContent) { ensureBlankTrailingPage() }
    .onChange(of: infinite) { ensureBlankTrailingPage() }
    .onAppear {
      refreshTrailingPage()
      ensureBlankTrailingPage()
    }
    .onChange(of: notebook.pages.first?.id) {
      // The tab switched to another notebook; this view's state is reused across tabs.
      selection = []
      imageSelection = nil
      refreshTrailingPage()
    }
    .onDisappear { pageHUDTask?.cancel() }
  }
  var body: some View {
    syncedContent
    .sheet(isPresented: $templateSheet) {
      TemplatePicker(initialPaper: page.paper) { paper in
        appendPage(Page(paper: paper))
      }
    }
    .sheet(isPresented: $paperSheet) {
      PaperBackgroundSheet(
        initialPattern: page.paper.pattern, whiteboard: notebook.kind == .whiteboard
      ) { pattern, allPages in
        let currentID = page.id
        edit { package in
          for index in package.notebook.pages.indices {
            if package.notebook.pages[index].backgroundPDF == nil,
              allPages || package.notebook.pages[index].id == currentID
            {
              package.notebook.pages[index].paper.pattern = pattern
            }
          }
        }
      }
    }
    .sheet(isPresented: $navigator) {
      DocumentNavigator(package: document.package, currentPage: activePage) { id in
        if let i = notebook.pages.firstIndex(where: { $0.id == id }) { activePage = i }
      }
    }
    .sheet(isPresented: $pdfForms) {
      PDFFormsSheet(package: document.package, page: page) { assets in
        edit { $0.assets.merge(assets) { _, updated in updated } }
      }
    }
    .sheet(isPresented: $textSheet) { textEditor }
    .sheet(isPresented: $saveElementSheet) {
      VStack(alignment: .leading, spacing: 20) {
        Text("Save element").font(.title2.bold())
        TextField("Name", text: $elementName).textFieldStyle(.roundedBorder)
        HStack {
          Button("Cancel") { saveElementSheet = false }
          Spacer()
          Button("Save") {
            do {
              let clip = try ElementClip.capture(
                title: elementName, page: page, ids: selection,
                assets: document.package.assets)
              try elements.add(clip)
              selectedElementID = clip.id
              saveElementSheet = false
            } catch { errorMessage = error.localizedDescription }
          }.disabled(elementName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }.padding(28).frame(minWidth: 300)
    }
    .photosPicker(isPresented: $photoLibrary, selection: $photoItem, matching: .images)
    .onChange(of: photoItem) {
      Task {
        do {
          if let data = try await photoItem?.loadTransferable(type: Data.self) {
            try insertImage(data, name: UUID().uuidString + ".image")
          }
          photoItem = nil
        } catch { errorMessage = error.localizedDescription }
      }
    }
    #if os(iOS)
      .sheet(isPresented: $scanner) {
        DocumentScanner(onScan: insertScans, onError: { errorMessage = $0 })
      }
    #endif
    .fileImporter(isPresented: $importer, allowedContentTypes: [importType]) { result in
      importFile(result)
    }
    .fileExporter(
      isPresented: $exporter, document: NotebookExport(data: exportData), contentType: exportType,
      defaultFilename: notebook.title
    ) { result in if case .failure(let error) = result { errorMessage = error.localizedDescription }
    }
    .alert(
      "Unable to complete the operation",
      isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
    .alert("Notebook title", isPresented: $renameSheet) {
      TextField("Title", text: $titleDraft)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { edit { $0.notebook.title = titleDraft } }
        .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .onChange(of: activePage) {
      let ids = Set(page.strokes.map(\.id) + page.images.map(\.id) + page.texts.map(\.id))
      selection.formIntersection(ids)
      if let imageSelection, !ids.contains(imageSelection) { self.imageSelection = nil }
    }
  }
  private var documentMenu: some View {
    Menu {
      Button("Rename notebook", systemImage: "pencil") {
        titleDraft = notebook.title
        renameSheet = true
      }
      Button("Navigate document", systemImage: "list.bullet") { navigator = true }
        .accessibilityIdentifier("documentNavigatorMenu")
      Button("Fill PDF forms", systemImage: "rectangle.and.pencil.and.ellipsis") {
        pdfForms = true
      }.disabled(page.backgroundPDF == nil)
      Button("Export current page", systemImage: "square.and.arrow.up") {
        do {
          var single = document.package
          single.notebook.pages = [page]
          exportData = try PDFEditor.export(single)
          exportType = .pdf
          exporter = true
        } catch { errorMessage = error.localizedDescription }
      }
      Divider()
      Button("Import PDF", systemImage: "doc") {
        importType = .pdf
        importer = true
      }
      Button("Photo library", systemImage: "photo.on.rectangle") { photoLibrary = true }
      #if os(iOS)
        Button("Scan documents", systemImage: "doc.viewfinder") { scanner = true }.disabled(
          !VNDocumentCameraViewController.isSupported)
      #endif
      Button("Paper background", systemImage: "square.grid.3x3") { paperSheet = true }
        .disabled(page.backgroundPDF != nil)
      Button("Add page", systemImage: "plus") { templateSheet = true }
      Button("Paste ink", systemImage: "doc.on.clipboard") { paste() }.disabled(
        clipboard.isEmpty && clipboardImages.isEmpty && clipboardTexts.isEmpty)
      Toggle("Infinite scrolling", isOn: $infinite)
      Toggle("Horizontal pages", isOn: $horizontalSetting).disabled(infinite)
      Toggle("Keep zoom on new pages", isOn: $keepZoomOnNewPage)
      Toggle("Apple Pencil only", isOn: $pencilOnly)
      Toggle("Draw and hold for shapes", isOn: $holdToShape)
      Toggle("Scribble to erase", isOn: $scratchToErase)
      Text(
        pencilOnly
          ? "Pencil writes · one finger navigates" : "One finger draws · two fingers navigate")
      Button("Delete current page", role: .destructive) {
        if notebook.pages.count > 1 {
          edit { $0.notebook.pages.remove(at: activePage) }
          activePage = min(activePage, notebook.pages.count - 1)
        }
      }.disabled(notebook.pages.count == 1)
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 20)).hitTarget()
    }
    .accessibilityLabel("More")
  }
  private var documentActions: some View {
    HStack(spacing: 0) {
      Button {
        thumbnails.toggle()
      } label: {
        Image(systemName: "sidebar.left").font(.system(size: 20)).hitTarget()
      }
      .accessibilityLabel("Pages")
      Button {
        searchVisible.toggle()
      } label: {
        Image(systemName: "magnifyingglass").font(.system(size: 20)).hitTarget()
      }
      .accessibilityLabel("Search text")
      Button {
        edit { $0.notebook.pages[activePage].bookmarked.toggle() }
      } label: {
        Image(systemName: page.bookmarked ? "bookmark.fill" : "bookmark").font(.system(size: 20))
          .hitTarget()
      }.accessibilityLabel("Bookmark page")
    }
  }
  private var exportButton: some View {
    Button {
      do {
        exportData = try PDFEditor.export(document.package)
        exportType = .pdf
        exporter = true
      } catch { errorMessage = error.localizedDescription }
    } label: {
      Image(systemName: "square.and.arrow.up").font(.system(size: 20)).hitTarget()
    }
    .accessibilityLabel("Export PDF")
  }

  private var tabBar: some View {
    HStack(spacing: 0) {
      Button {
        if let onBack { onBack() } else { dismiss() }
      } label: {
        Image(systemName: "house").font(.system(size: 17)).frame(width: 56, height: 40)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain).accessibilityLabel("Documents")

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
          if tabs.isEmpty { Text(notebook.title).padding(.horizontal, 20).frame(height: 34) }
          ForEach(tabs) { tab in
            Button {
              onSelectTab?(tab.id)
            } label: {
              Label(tab.selected ? notebook.title : tab.title, systemImage: "book.closed")
                .lineLimit(1).padding(.horizontal, 18)
                .frame(height: 40).contentShape(Rectangle())
                .background(
                  tab.selected ? Color.white.opacity(0.2) : .clear, ignoresSafeAreaEdges: []
                )
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 9, topTrailingRadius: 9))
            }.buttonStyle(.plain)
          }
        }
      }
      if notebook.kind != .whiteboard {
        Button {
          templateSheet = true
        } label: {
          Image(systemName: "plus").font(.system(size: 17)).frame(width: 52, height: 40)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("Add page").accessibilityIdentifier(
          "newPageButton")
      }
    }.font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white).background(
      Color(red: 0.12, green: 0.20, blue: 0.36))
  }
  private var toolBar: some View {
    GeometryReader { geometry in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          documentActions
          Spacer(minLength: 16)
          Divider().frame(height: 24)
          ForEach(InkTool.allCases, id: \.self) { item in
            Button {
              if tool == item {
                settings.toggle()
              } else {
                previousTool = tool
                tool = item
                selection = []
                imageSelection = nil
                if item == .elements || item == .image { settings = true }
              }
            } label: {
              Image(systemName: icon(item)).font(.system(size: 21)).hitTarget(width: 44)
                .foregroundStyle(tool == item ? Color(red: 0.12, green: 0.20, blue: 0.36) : .white)
                .background(
                  tool == item ? Color.white.opacity(0.85) : .clear,
                  in: RoundedRectangle(cornerRadius: 7))
            }
            .help(label(item)).accessibilityLabel(label(item))
            .popover(
              isPresented: Binding(get: { settings && tool == item }, set: { settings = $0 })
            ) { toolSettings.padding(22).frame(width: 320).preferredColorScheme(.dark) }
          }
          Spacer(minLength: 8)
          exportButton
          documentMenu
        }.buttonStyle(.plain).frame(minWidth: max(0, geometry.size.width - 32)).padding(
          .horizontal, 16
        ).frame(height: 44)
      }
    }.frame(height: 44).foregroundStyle(.white).background(
      Color(red: 0.17, green: 0.29, blue: 0.47))
  }
  private var contextualToolBar: some View {
    HStack(spacing: 12) {
      Button {
        undo()
      } label: {
        Image(systemName: "arrow.uturn.backward").font(.system(size: 19)).hitTarget(width: 42)
      }.disabled(undoStack.isEmpty).help("Undo").accessibilityLabel("Undo").keyboardShortcut(
        "z", modifiers: .command)
      Button {
        redo()
      } label: {
        Image(systemName: "arrow.uturn.forward").font(.system(size: 19)).hitTarget(width: 42)
      }.disabled(redoStack.isEmpty).help("Redo").accessibilityLabel("Redo").keyboardShortcut(
        "z", modifiers: [.command, .shift])

      if [.pen, .highlighter, .shapes].contains(tool) {
        Divider().frame(height: 24)
        if tool == .shapes {
          ForEach(ShapePreset.allCases, id: \.self) { preset in
            Button {
              shapePreset = preset
            } label: {
              Image(systemName: preset.symbol).font(.system(size: 18)).hitTarget(width: 38)
                .background(
                  shapePreset == preset ? Color.white.opacity(0.2) : .clear,
                  in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityLabel(preset.rawValue.capitalized + " shape")
          }
        }
        if tool == .pen {
          ForEach(PenStyle.allCases, id: \.self) { style in
            Button {
              penStyle = style
            } label: {
              Image(
                systemName: style == .fountain
                  ? "pencil.tip" : style == .ballpoint ? "pencil" : "paintbrush.pointed"
              )
              .font(.system(size: 18)).hitTarget(width: 38)
              .background(
                penStyle == style ? Color.cyan.opacity(0.35) : .clear,
                in: RoundedRectangle(cornerRadius: 7))
            }.accessibilityLabel(style.rawValue.capitalized + " pen")
          }
        }
        Divider().frame(height: 24)
        QuickColorRow(color: colorBinding, accent: accent)
        Divider().frame(height: 24)
        QuickWidthRow(
          slots: widthSlots, width: widthBinding,
          range: tool == .highlighter ? 6...40 : 0.5...12, color: color,
          highlighter: tool == .highlighter)
      } else if tool == .eraser {
        ForEach(EraserMode.allCases, id: \.self) { mode in
          Button {
            eraserMode = mode
          } label: {
            Text(mode.rawValue.capitalized).padding(.horizontal, 10).frame(height: 44)
              .contentShape(Rectangle())
          }.foregroundStyle(eraserMode == mode ? Color.cyan : Color.white)
        }
      } else if tool == .lasso {
        Toggle("Ink", isOn: $selectInk)
        Toggle("Images", isOn: $selectImages)
        Toggle("Text", isOn: $selectTexts)
      }
    }.buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(.white)
      .padding(.horizontal, 14).frame(height: 44)
      .background(Color(red: 0.16, green: 0.17, blue: 0.18), in: Capsule())
      .overlay(Capsule().stroke(Color.white.opacity(0.18)))
      .fixedSize(horizontal: true, vertical: false)
  }
  @ViewBuilder private var toolSettings: some View {
    VStack(alignment: .leading, spacing: 16) {
      if tool != .elements { Text(label(tool)).font(.headline) }
      switch tool {
      case .pen:
        Picker("Pen style", selection: $penStyle) {
          ForEach(PenStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }.pickerStyle(.segmented)
        Text("Thickness \(width.formatted()) pt")
        Slider(value: widthBinding, in: 0.5...12)
        ColorPicker("Custom color", selection: $customColor).onChange(of: customColor) {
          color = convertColor(customColor)
        }
        TextField("Hex color, e.g. #265DD4", text: $hexColor).onSubmit {
          if let parsed = InkColor(hex: hexColor) { color = parsed }
        }
        Stepper(
          "Preset 1: \(firstWidth.formatted()) pt", value: $firstWidth, in: 0.5...12, step: 0.5)
        Stepper(
          "Preset 2: \(secondWidth.formatted()) pt", value: $secondWidth, in: 0.5...12, step: 0.5)
        Stepper(
          "Preset 3: \(thirdWidth.formatted()) pt", value: $thirdWidth, in: 0.5...12, step: 0.5)
      case .eraser:
        Picker("Mode", selection: $eraserMode) {
          ForEach(EraserMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        Toggle("Erase highlighter only", isOn: $highlighterOnly)
        Toggle("Auto-deselect", isOn: $autoDeselect)
        Text("Radius \(width.formatted()) pt")
        Slider(value: widthBinding, in: 3...40)
      case .highlighter:
        Toggle("Draw straight lines", isOn: $straightHighlight)
        Text("Width \(width.formatted()) pt")
        Slider(value: widthBinding, in: 6...40)
      case .shapes:
        Toggle("Fill closed shapes", isOn: $fillShapes)
        Text("Draw a line, rectangle or circle. Closed strokes snap to geometric shapes.").font(
          .callout)
      case .lasso:
        Toggle("Handwriting", isOn: $selectInk)
        Toggle("Images", isOn: $selectImages)
        Toggle("Text boxes", isOn: $selectTexts)
        Text("Circle content to select it, then use the selection menu.").font(.callout)
      case .image:
        Text("Insert image from").font(.headline)
        Button("Files") {
          settings = false
          importType = .image
          importer = true
        }
        Button("Photo library") {
          settings = false
          photoLibrary = true
        }
        Divider()
        Button("Cancel") { settings = false }
      case .text: Text("Tap the page to add a text box.")
      case .elements:
        ElementPicker(
          library: elements,
          onSelect: { clip in
            selectedElementID = clip?.id
            settings = false
          }, onError: { errorMessage = $0 })
      case .readOnly: Text("Drawing is locked. Use the scroll view to read your pages.")
      }
    }
  }
  private var pageSidebar: some View {
    ScrollView {
      LazyVStack(spacing: 18) {
        ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, p in
          Button {
            activePage = index
          } label: {
            VStack(spacing: 8) {
              Canvas { context, size in
                context.withCGContext { c in
                  c.scaleBy(x: size.width / p.dimensions.x, y: size.width / p.dimensions.x)
                  PageRenderer.render(p, assets: document.package.assets, in: c)
                }
              }.frame(width: 112, height: 112 * p.dimensions.y / p.dimensions.x).background(.white)
                .overlay(
                  Rectangle().stroke(
                    index == activePage ? accent : Color.gray.opacity(0.25),
                    lineWidth: index == activePage ? 2 : 1))
              HStack {
                Text("\(index + 1)")
                if p.bookmarked { Image(systemName: "bookmark.fill") }
              }.font(.caption)
            }
          }.buttonStyle(.plain).accessibilityLabel("Page \(index + 1)")
            .accessibilityIdentifier("pageThumbnail-\(index)").contextMenu {
              Button("Insert page after") {
                edit { $0.notebook.pages.insert(InkGestures.blankPage(matching: p), at: index + 1) }
                activePage = index + 1
              }
              Button("Duplicate page") {
                edit { $0.notebook.pages.insert(InkGestures.duplicatePage(p), at: index + 1) }
                activePage = index + 1
              }
              Button("Move earlier") {
                edit { $0.notebook.pages.swapAt(index, index - 1) }
                activePage = index - 1
              }.disabled(index == 0)
              Button("Move later") {
                edit { $0.notebook.pages.swapAt(index, index + 1) }
                activePage = index + 1
              }.disabled(index == notebook.pages.count - 1)
              Button(p.bookmarked ? "Remove bookmark" : "Bookmark") {
                edit { $0.notebook.pages[index].bookmarked.toggle() }
              }
              Button("Delete page", role: .destructive) {
                edit { $0.notebook.pages.remove(at: index) }
                activePage = min(activePage, notebook.pages.count - 1)
              }.disabled(notebook.pages.count == 1)
            }
        }
      }.padding(20)
    }.frame(width: 160).background(Color(red: 0.96, green: 0.97, blue: 0.98))
  }
  private func pageView(
    _ p: Page, index: Int, availableWidth: Double, availableHeight: Double? = nil,
    boardHeight: Double? = nil
  )
    -> some View
  {
    let fittedWidth =
      availableHeight.map { max(120, ($0 - 80) * p.dimensions.x / p.dimensions.y) } ?? 780
    let w =
      boardHeight == nil
      ? max(120, min(availableWidth - 56, fittedWidth)) * zoom : availableWidth
    return VStack(spacing: 10) {
      NativeCanvas(
        configuration: CanvasConfiguration(
          page: displayPage(p, index: index), assets: document.package.assets, tool: tool,
          color: color, width: width, style: penStyle,
          pencilOnly: pencilOnly, selection: index == activePage ? selection : [],
          onStroke: { stroke in
            activePage = index
            var s = stroke
            if tool == .shapes {
              s = Editing.shape(from: s, preset: shapePreset)
              s.fillColor = fillShapes ? color : nil
            }
            if tool == .highlighter && straightHighlight, let first = s.samples.first,
              let last = s.samples.last
            {
              s.samples = [first, last]
            }
            let scribbled =
              tool == .pen && scratchToErase
              ? InkGestures.scratchErase(s.samples.map(\.point), strokes: p.strokes) : nil
            edit { package in
              if let scribbled, scribbled != p.strokes {
                package.notebook.pages[index].strokes = scribbled
              } else {
                package.notebook.pages[index].strokes.append(s)
              }
            }
          },
          onGesture: { points in
            activePage = index
            if tool == .eraser {
              edit { package in
                for point in points {
                  package.notebook.pages[index].strokes = Editing.erase(
                    strokes: package.notebook.pages[index].strokes, at: point,
                    radius: max(8, width), mode: eraserMode, highlighterOnly: highlighterOnly)
                }
              }
              if autoDeselect { tool = previousTool == .eraser ? .pen : previousTool }
            } else {
              selection =
                selectInk
                ? Editing.selection(
                  strokes: p.strokes, polygon: points,
                  bounds: boardHeight == nil
                    ? Rect(x: 0, y: 0, width: p.dimensions.x, height: p.dimensions.y)
                    : PageRenderer.contentBounds(p)) : []
              if selectImages {
                selection.formUnion(
                  p.images.filter { intersects($0.bounds, polygon: points) }.map(\.id))
              }
              if selectTexts {
                selection.formUnion(
                  p.texts.filter { intersects($0.bounds, polygon: points) }.map(\.id))
              }
            }
          },
          onTap: { point in
            activePage = index
            insertPoint = point
            if tool == .readOnly { followLink(at: point, on: p) }
            if tool == .text {
              if let box = p.texts.last(where: { $0.contains(point) }) {
                editingTextID = box.id
                insertPoint = box.origin
                text = box.text
                textSize = box.size
                textFont = box.fontName ?? "System"
                textAlignment = box.alignment ?? "left"
                textBorder = box.border ?? false
                textBackground = box.background != nil
                textWidth = box.boxWidth ?? 280
              } else {
                editingTextID = nil
                text = ""
              }
              textSheet = true
            }
            if tool == .image {
              if let image = p.images.last(where: { $0.contains(point) }) {
                imageSelection = image.id
              } else {
                importType = .image
                importer = true
              }
            }
            if tool == .elements { insertStar(point) }
          }, viewport: boardHeight == nil ? nil : boardViewport,
          onViewportChange: { boardViewport = $0 },
          onTranslateSelection: { delta in
            activePage = index
            edit { package in
              package.notebook.pages[index] = InkGestures.translate(
                package.notebook.pages[index], ids: selection, by: delta)
            }
          },
          onTransformSelection: { transform in
            activePage = index
            edit { package in
              package.notebook.pages[index] = InkGestures.transform(
                package.notebook.pages[index],
                ids: selection, by: transform)
            }
          },
          onSelectionMenu: { selectionMenuPresented = true },
          onPencilDetected: { pencilOnly = true },
          onToggleEraser: {
            if tool == .eraser {
              tool = previousTool
            } else {
              previousTool = tool
              tool = .eraser
            }
          },
          onAppendPage: boardHeight == nil && !horizontal && !infinite
            && index == notebook.pages.count - 1
            ? {
              let next = InkGestures.blankPage(matching: p)
              appendPage(next)
            } : nil,
          onPagePull: { pagePullProgress = $0 }, horizontalPages: horizontal,
          onScrollActivity: { showPageIndicator() }, holdToShape: holdToShape,
          eraserMode: eraserMode, highlighterOnly: highlighterOnly,
          searchHighlights: searchVisible
            ? documentSearch.results.first(where: { $0.pageID == p.id })?.highlights ?? [] : [])
      )
      .accessibilityElement()
      .accessibilityLabel("Drawing canvas")
      .accessibilityIdentifier("drawingCanvas")
      .accessibilityValue("\(p.strokes.count) strokes")
      .overlay(alignment: .topLeading) {
        if index == activePage, let id = imageSelection,
          let image = p.images.first(where: { $0.id == id }),
          let data = document.package.assets[image.filename]
        {
          ImageHandles(
            asset: image, data: data,
            viewScale: boardHeight == nil ? w / p.dimensions.x : boardViewport.scale,
            viewOffset: boardHeight == nil ? Point(0, 0) : boardViewport.offset
          ) { changed in
            edit { package in
              if let i = package.notebook.pages[index].images.firstIndex(where: {
                $0.id == changed.id
              }) {
                package.notebook.pages[index].images[i] = changed
              }
            }
          }
        }
      }
      .overlay(alignment: .topLeading) {
        if index == activePage, !selection.isEmpty,
          let b = InkGestures.selectionBounds(page: p, ids: selection)
        {
          let scale = boardHeight == nil ? w / p.dimensions.x : boardViewport.scale
          let offset = boardHeight == nil ? Point(0, 0) : boardViewport.offset
          HStack(spacing: 18) {
            Button {
              copySelection()
              deleteSelection()
            } label: {
              Image(systemName: "scissors")
            }
            .accessibilityLabel("Cut selection")
            Button {
              copySelection()
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Copy selection")
            Button {
              deleteSelection()
            } label: {
              Image(systemName: "trash")
            }
            .foregroundStyle(.red).accessibilityLabel("Delete selection")
            Button {
              selectionMenuPresented.toggle()
            } label: {
              Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Selection actions")
          }.font(.system(size: 18)).padding(.horizontal, 18).frame(height: 42)
            .buttonStyle(.plain).foregroundStyle(.white)
            .background(Color(red: 0.16, green: 0.17, blue: 0.18), in: Capsule())
            .position(
              x: min(w - 95, max(95, (b.x + b.width / 2) * scale + offset.x)),
              y: min(
                (boardHeight ?? w * p.dimensions.y / p.dimensions.x) - 26,
                max(26, (b.y + b.height) * scale + offset.y + 30))
            )
            .popover(isPresented: $selectionMenuPresented) {
              selectionActions.padding(16).frame(width: 240)
                .foregroundStyle(.primary).preferredColorScheme(.dark)
            }
        }
      }
      .dropDestination(for: URL.self) { urls, location in
        guard let url = urls.first else { return false }
        activePage = index
        insertPoint =
          boardHeight == nil
          ? Point(location.x * p.dimensions.x / w, location.y * p.dimensions.x / w)
          : boardViewport.documentPoint(Point(location.x, location.y))
        importType = .image
        importFile(.success(url))
        return true
      }
      .frame(width: w, height: boardHeight ?? (w * p.dimensions.y / p.dimensions.x)).background(
        .white
      ).shadow(
        color: Color.black.opacity(infinite ? 0 : 0.10), radius: infinite ? 0 : 6, y: 2)
    }.id(p.id)
  }
  private var lastPageHasContent: Bool {
    InkGestures.blankPageNeeded(after: notebook.pages) != nil
  }
  // Infinite mode keeps one blank page below the writing at all times. It is added outside the
  // undo history so undoing a stroke never leaves the user at a visible "page break".
  private func ensureBlankTrailingPage() {
    guard infinite, notebook.kind != .whiteboard,
      let next = InkGestures.blankPageNeeded(after: notebook.pages)
    else { return }
    document.package.notebook.pages.append(next)
    document.package.notebook.revision += 1
  }
  private func refreshTrailingPage() {
    guard horizontal, notebook.kind != .whiteboard, let last = notebook.pages.last else {
      trailingPage = nil
      return
    }
    trailingPage = InkGestures.blankPage(matching: last)
  }
  private func appendPage(_ next: Page) {
    pageZoom[next.id] = keepZoomOnNewPage ? (pageZoom[page.id] ?? zoom) : 1
    if !keepZoomOnNewPage {
      zoom = 1
      zoomBase = 1
    }
    edit { $0.notebook.pages.append(next) }
    activePage = notebook.pages.count - 1
  }
  private func displayPage(_ page: Page, index: Int) -> Page {
    var result = page
    if index == activePage, let id = imageSelection { result.images.removeAll { $0.id == id } }
    return result
  }
  private var selectionActions: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("\(selection.count) selected").font(.caption)
      Button("Cut") {
        copySelection()
        deleteSelection()
      }
      Button("Copy") { copySelection() }
      Button("Paste") { paste() }.disabled(
        clipboard.isEmpty && clipboardImages.isEmpty && clipboardTexts.isEmpty)
      Button("Delete", role: .destructive) { deleteSelection() }
      Button("Change color") {
        edit { p in
          for i in p.notebook.pages[activePage].strokes.indices
          where selection.contains(p.notebook.pages[activePage].strokes[i].id) {
            p.notebook.pages[activePage].strokes[i].color = color
          }
          for i in p.notebook.pages[activePage].texts.indices
          where selection.contains(p.notebook.pages[activePage].texts[i].id) {
            p.notebook.pages[activePage].texts[i].color = color
          }
        }
      }
      Text("Drag a corner to resize, or the top handle to rotate.").font(.caption).foregroundStyle(
        .secondary)
      Button("Save element") {
        elementName = "Element \(elements.clips.count + 1)"
        selectionMenuPresented = false
        saveElementSheet = true
      }
      Button("Screenshot") {
        do {
          exportData = try PageRenderer.screenshot(
            page, assets: document.package.assets, bounds: selectionBounds())
          exportType = .png
          exporter = true
        } catch { errorMessage = error.localizedDescription }
      }
      Button("Deselect") {
        selection = []
        selectionMenuPresented = false
      }
    }.buttonStyle(.plain)
      .onChange(of: selection) { if selection.isEmpty { selectionMenuPresented = false } }
  }
  private var searchBar: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: "magnifyingglass")
        TextField("Search PDF text and text boxes", text: $search)
          .accessibilityIdentifier("documentSearchField")
          .onChange(of: search) { documentSearch.update(document.package, query: search) }
        if documentSearch.isSearching { ProgressView().controlSize(.small) }
        Button("Done") {
          searchVisible = false
          search = ""
          documentSearch.update(document.package, query: "")
        }
      }
      if !search.isEmpty {
        if !documentSearch.isSearching && documentSearch.results.isEmpty {
          Text("No matches in searchable text").font(.caption).foregroundStyle(.secondary)
        }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 16) {
            ForEach(documentSearch.results) { result in
              Button {
                if let index = notebook.pages.firstIndex(where: { $0.id == result.pageID }) {
                  activePage = index
                }
              } label: {
                VStack(alignment: .leading, spacing: 3) {
                  Text("Page \(result.pageNumber)").font(.caption.bold())
                  Text(result.snippet).font(.caption).lineLimit(2)
                }.frame(width: 190, alignment: .leading)
              }.buttonStyle(.plain).accessibilityLabel("Search result page \(result.pageNumber)")
            }
          }
        }.frame(maxHeight: 48)
      }
    }.padding(12).background(accent.opacity(0.04))
      .onChange(of: notebook.revision) {
        if searchVisible && !search.isEmpty {
          documentSearch.update(document.package, query: search)
        }
      }
  }
  private func showPageIndicator() {
    let now = Date()
    guard !pageHUD || now.timeIntervalSince(lastHUDActivation) >= 0.5 else { return }
    lastHUDActivation = now
    pageHUDTask?.cancel()
    pageHUD = true
    pageHUDTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(1.5))
      if !Task.isCancelled { pageHUD = false }
    }
  }
  @ViewBuilder private func notebookPage(
    _ p: Page, index: Int, size: CGSize, vertical: Bool = false
  ) -> some View {
    let width = max(
      120,
      min(
        size.width - 40,
        vertical ? size.width - 40 : max(120, size.height * p.dimensions.x / p.dimensions.y)))
    let height = width * p.dimensions.y / p.dimensions.x
    #if os(iOS)
      ZoomableNotebookPage(
        contentSize: CGSize(width: width, height: height),
        viewportSize: CGSize(width: size.width, height: vertical ? height : size.height),
        pencilOnly: pencilOnly || tool == .readOnly, zoomEnabled: imageSelection == nil && !infinite,
        initialZoom: pageZoom[p.id] ?? 1,
        onZoomChange: {
          pageZoom[p.id] = $0
        }
      ) {
        pageView(p, index: index, availableWidth: width + 56, availableHeight: height + 80)
      }.frame(width: size.width, height: vertical ? height : size.height)
    #else
      pageView(
        p, index: index, availableWidth: size.width, availableHeight: vertical ? nil : size.height
      )
      .simultaneousGesture(
        MagnifyGesture().onChanged { value in
          zoom = min(5, max(1, zoomBase * value.magnification))
        }.onEnded { _ in zoomBase = zoom })
    #endif
  }
  private var textEditor: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(editingTextID == nil ? "Add text" : "Edit text").font(.title2.bold())
      TextEditor(text: $text).font(.system(size: textSize)).frame(height: 180).border(
        .gray.opacity(0.2))
      HStack {
        Text("Font size")
        Slider(value: $textSize, in: 10...60)
        Text("\(Int(textSize)) pt")
      }
      Picker("Font", selection: $textFont) {
        Text("System").tag("System")
        Text("Helvetica").tag("Helvetica")
        Text("Georgia").tag("Georgia")
        Text("Courier").tag("Courier")
      }
      Picker("Alignment", selection: $textAlignment) {
        Text("Left").tag("left")
        Text("Center").tag("center")
        Text("Right").tag("right")
      }.pickerStyle(.segmented)
      HStack {
        Toggle("Border", isOn: $textBorder)
        Toggle("Background", isOn: $textBackground)
      }
      HStack {
        Text("Box width")
        Slider(value: $textWidth, in: 80...500)
      }
      HStack {
        Button("Cancel") { textSheet = false }
        if let id = editingTextID {
          Button("Delete", role: .destructive) {
            edit { $0.notebook.pages[activePage].texts.removeAll { $0.id == id } }
            textSheet = false
          }
        }
        Spacer()
        Button(editingTextID == nil ? "Insert" : "Save") {
          var box = TextBox(origin: insertPoint, text: text)
          box.size = textSize
          box.color = color
          box.fontName = textFont == "System" ? nil : textFont
          box.alignment = textAlignment
          box.border = textBorder
          box.background = textBackground ? color : nil
          box.boxWidth = textWidth
          edit { p in
            if let id = editingTextID,
              let i = p.notebook.pages[activePage].texts.firstIndex(where: { $0.id == id })
            {
              box.id = id
              box.rotation = p.notebook.pages[activePage].texts[i].rotation
              p.notebook.pages[activePage].texts[i] = box
            } else {
              p.notebook.pages[activePage].texts.append(box)
            }
          }
          textSheet = false
        }.buttonStyle(.borderedProminent).disabled(text.isEmpty)
      }
    }.padding(28).frame(width: 440)
  }
  private func imageControls(_ id: UUID) -> some View {
    HStack {
      Text("Drag to move · Drag the corner to resize · Pinch or rotate with two fingers")
        .font(.caption).foregroundStyle(.secondary)
      Spacer()
      Button("Delete", role: .destructive) {
        edit { $0.notebook.pages[activePage].images.removeAll { $0.id == id } }
        imageSelection = nil
      }
      Spacer()
      Button("Done") { imageSelection = nil }
    }.padding(12).buttonStyle(.borderless)
  }
  private func edit(_ mutation: (inout NotebookPackage) -> Void) {
    undoStack.append(document.package)
    if undoStack.count > 60 { undoStack.removeFirst() }
    redoStack = []
    mutation(&document.package)
    document.package.notebook.revision += 1
  }
  private func undo() {
    guard let old = undoStack.popLast() else { return }
    redoStack.append(document.package)
    var restored = old
    restored.notebook.revision = document.package.notebook.revision + 1
    document.package = restored
    activePage = min(activePage, notebook.pages.count - 1)
    selection = []
  }
  private func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(document.package)
    var restored = next
    restored.notebook.revision = document.package.notebook.revision + 1
    document.package = restored
    activePage = min(activePage, notebook.pages.count - 1)
    selection = []
  }
  private func deleteSelection() {
    edit { p in
      p.notebook.pages[activePage].strokes.removeAll { selection.contains($0.id) }
      p.notebook.pages[activePage].images.removeAll { selection.contains($0.id) }
      p.notebook.pages[activePage].texts.removeAll { selection.contains($0.id) }
    }
    selection = []
  }
  private func copySelection() {
    clipboard = page.strokes.filter { selection.contains($0.id) }
    clipboardImages = page.images.filter { selection.contains($0.id) }
    // Images are only file names; the bytes must travel with them to survive a paste into
    // another notebook, whose package has never seen these assets.
    InkClipboard.shared.assets = Dictionary(
      uniqueKeysWithValues: clipboardImages.compactMap { image in
        document.package.assets[image.filename].map { (image.filename, $0) }
      })
    clipboardTexts = page.texts.filter { selection.contains($0.id) }
  }
  private func intersects(_ rect: Rect, polygon: [Point]) -> Bool {
    let outline = [
      Point(rect.x, rect.y), Point(rect.x + rect.width, rect.y),
      Point(rect.x + rect.width, rect.y + rect.height), Point(rect.x, rect.y + rect.height),
      Point(rect.x, rect.y),
    ]
    return Editing.strokeIntersects(
      Stroke(samples: outline.map { Sample(point: $0) }), polygon: polygon)
      || polygon.contains { rect.contains($0) }
  }
  private func selectionBounds() -> Rect {
    let bounds =
      page.strokes.filter { selection.contains($0.id) }.map(\.bounds)
      + page.images.filter { selection.contains($0.id) }.map(\.bounds)
      + page.texts.filter { selection.contains($0.id) }.map(\.bounds)
    let x = bounds.map(\.x).min() ?? 0
    let y = bounds.map(\.y).min() ?? 0
    return Rect(
      x: x - 8, y: y - 8, width: (bounds.map { $0.x + $0.width }.max() ?? x) - x + 16,
      height: (bounds.map { $0.y + $0.height }.max() ?? y) - y + 16)
  }
  private func paste() {
    edit { p in
      p.assets.merge(InkClipboard.shared.assets) { existing, _ in existing }
      p.notebook.pages[activePage].strokes += clipboard.map {
        var s = $0
        s.id = UUID()
        s.samples = s.samples.map {
          var sample = $0
          sample.point.x += 20
          sample.point.y += 20
          return sample
        }
        return s
      }
      p.notebook.pages[activePage].images += clipboardImages.map {
        var image = $0
        image.id = UUID()
        image.frame.x += 20
        image.frame.y += 20
        return image
      }
      p.notebook.pages[activePage].texts += clipboardTexts.map {
        var text = $0
        text.id = UUID()
        text.origin.x += 20
        text.origin.y += 20
        return text
      }
    }
  }
  private func insertStar(_ point: Point) {
    if let id = selectedElementID, let clip = elements.clips.first(where: { $0.id == id }) {
      do {
        var updated = document.package
        try clip.insert(into: &updated, pageIndex: activePage, at: point)
        edit { $0 = updated }
      } catch { errorMessage = error.localizedDescription }
      return
    }
    let points = (0...10).map { i in
      let angle = Double(i) * .pi / 5 - .pi / 2
      let r = i % 2 == 0 ? 30.0 : 13.0
      return Sample(point: Point(point.x + r * cos(angle), point.y + r * sin(angle)))
    }
    edit {
      $0.notebook.pages[activePage].strokes.append(
        Stroke(samples: points, color: color, width: width))
    }
  }
  private func followLink(at point: Point, on page: Page) {
    guard let name = page.backgroundPDF, let data = document.package.assets[name],
      let pdf = PDFDocument(data: data), let background = pdf.page(at: page.backgroundPage ?? 0)
    else { return }
    guard let provider = CGDataProvider(data: data as CFData), let cgPDF = CGPDFDocument(provider),
      let source = cgPDF.page(at: (page.backgroundPage ?? 0) + 1)
    else { return }
    let transform = source.getDrawingTransform(
      .mediaBox, rect: CGRect(x: 0, y: 0, width: page.dimensions.x, height: page.dimensions.y),
      rotate: 0, preserveAspectRatio: true)
    let location = CGPoint(x: point.x, y: page.dimensions.y - point.y).applying(
      transform.inverted())
    guard let annotation = background.annotations.first(where: { $0.bounds.contains(location) })
    else { return }
    if let action = annotation.action as? PDFActionURL, let url = action.url { openURL(url) }
    let destination = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination
    if let destination, let target = destination.page {
      let pageNumber = pdf.index(for: target)
      if let i = notebook.pages.firstIndex(where: {
        $0.backgroundPDF == name && $0.backgroundPage == pageNumber
      }) {
        activePage = i
      }
    }
  }
  private func importFile(_ result: Result<URL, Error>) {
    do {
      let url = try result.get()
      let isPDF = importType == .pdf
      importing = true
      Task {
        do {
          let engine = ImportEngine()
          if isPDF {
            let imported = try await engine.pdf(url)
            edit {
              $0.assets.merge(imported.assets) { _, new in new }
              $0.notebook.pages.append(contentsOf: imported.notebook.pages)
            }
            activePage = notebook.pages.count - imported.notebook.pages.count
          } else {
            let data = try await engine.read(url)
            try insertImage(data, name: UUID().uuidString + "." + url.pathExtension)
          }
        } catch { errorMessage = error.localizedDescription }
        importing = false
      }
    } catch { errorMessage = error.localizedDescription }
  }
  private func insertImage(_ data: Data, name: String) throws {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw PackageError.invalidAsset(name) }
    let board = notebook.kind == .whiteboard
    let x = board ? insertPoint.x : max(0, min(insertPoint.x, page.dimensions.x - 40))
    let y = board ? insertPoint.y : max(0, min(insertPoint.y, page.dimensions.y - 40))
    let ratio = Double(image.height) / Double(image.width)
    let w =
      board
      ? 260 : max(20, min(260, page.dimensions.x - x - 20, (page.dimensions.y - y - 20) / ratio))
    let asset = PageAsset(filename: name, frame: Rect(x: x, y: y, width: w, height: w * ratio))
    edit {
      $0.assets[name] = data
      $0.notebook.pages[activePage].images.append(asset)
    }
    tool = .image
    selection = []
    imageSelection = asset.id
  }
  private func insertScans(_ scans: [Data]) {
    edit { package in
      for data in scans {
        let name = UUID().uuidString + ".jpg"
        var page = Page(paper: Paper(pattern: .blank))
        page.images = [
          PageAsset(
            filename: name,
            frame: Rect(x: 0, y: 0, width: page.dimensions.x, height: page.dimensions.y))
        ]
        package.assets[name] = data
        package.notebook.pages.append(page)
      }
    }
    activePage = max(0, notebook.pages.count - scans.count)
  }
  private func swiftColor(_ c: InkColor) -> Color {
    Color(red: c.red, green: c.green, blue: c.blue)
  }
  private func convertColor(_ c: Color) -> InkColor {
    #if os(macOS)
      let rgb = NSColor(c).usingColorSpace(.deviceRGB) ?? .black
      return InkColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    #else
      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
      return InkColor(red: r, green: g, blue: b)
    #endif
  }
  private func icon(_ tool: InkTool) -> String {
    switch tool {
    case .pen: "pencil.tip"
    case .eraser: "eraser"
    case .highlighter: "highlighter"
    case .shapes: "square.on.circle"
    case .lasso: "lasso"
    case .elements: "star.square"
    case .image: "photo"
    case .text: "textformat"
    case .readOnly: "hand.draw"
    }
  }
  private func label(_ tool: InkTool) -> String {
    tool == .readOnly ? "Read only" : tool.rawValue.capitalized
  }
}

struct TemplatePicker: View {
  @Environment(\.dismiss) private var dismiss
  @State private var pattern: PaperPattern = .ruled
  @State private var size: PaperSize = .a4
  @State private var landscape = false
  let onCreate: (Paper) -> Void
  init(initialPaper: Paper = Paper(), onCreate: @escaping (Paper) -> Void) {
    _pattern = State(initialValue: initialPaper.pattern)
    _size = State(initialValue: initialPaper.size)
    _landscape = State(initialValue: initialPaper.landscape)
    self.onCreate = onCreate
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Text("New page").font(.title2.bold())
        Spacer()
        Button("Cancel") { dismiss() }
      }
      Picker("Paper size", selection: $size) {
        ForEach(PaperSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented)
      Toggle("Landscape", isOn: $landscape)
      PaperPatternPicker(pattern: $pattern)
      Button("Add page") {
        onCreate(Paper(size: size, pattern: pattern, landscape: landscape))
        dismiss()
      }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("confirmAddPage")
    }.padding(28).frame(width: 450)
  }
}

private struct NotebookPageBehavior: ScrollTargetBehavior {
  let horizontal: Bool
  func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
    if horizontal {
      target.rect.origin.x = NotebookPaging.target(
        origin: context.originalTarget.rect.minX, projected: target.rect.minX,
        velocity: context.velocity.dx, pageWidth: context.containerSize.width,
        contentWidth: context.contentSize.width)
      target.rect.size.width = context.containerSize.width
    }
  }
}

struct PaperPatternPicker: View {
  @Binding var pattern: PaperPattern
  var whiteboard = false
  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 14) {
      ForEach(PaperPattern.allCases.filter { !whiteboard || $0 != .planner }, id: \.self) {
        option in
        Button {
          pattern = option
        } label: {
          VStack(spacing: 6) {
            Canvas { context, size in
              context.withCGContext { c in
                c.scaleBy(x: size.width / 200, y: size.width / 200)
                PageRenderer.paper(
                  Paper(pattern: option), in: c,
                  bounds: option == .planner ? nil : CGRect(x: 0, y: 0, width: 200, height: 140))
              }
            }.frame(height: 68).background(.white).clipShape(RoundedRectangle(cornerRadius: 6))
              .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(
                  pattern == option ? Color.blue : Color.gray.opacity(0.35),
                  lineWidth: pattern == option ? 2 : 1))
            Text(option.title).font(.caption).foregroundStyle(.primary)
          }
        }.buttonStyle(.plain).accessibilityLabel(option.title)
          .accessibilityAddTraits(pattern == option ? .isSelected : [])
      }
    }
  }
}

private struct PaperBackgroundSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var pattern: PaperPattern
  @State private var allPages = false
  let whiteboard: Bool
  let onApply: (PaperPattern, Bool) -> Void
  init(
    initialPattern: PaperPattern, whiteboard: Bool, onApply: @escaping (PaperPattern, Bool) -> Void
  ) {
    _pattern = State(initialValue: initialPattern)
    self.whiteboard = whiteboard
    self.onApply = onApply
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Text("Paper background").font(.title2.bold())
      PaperPatternPicker(pattern: $pattern, whiteboard: whiteboard)
      if !whiteboard { Toggle("Apply to all non-PDF pages", isOn: $allPages) }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Apply") {
          onApply(pattern, allPages)
          dismiss()
        }.buttonStyle(.borderedProminent)
      }
    }.padding(28).frame(minWidth: 340, idealWidth: 440).preferredColorScheme(.light)
  }
}

@MainActor private final class NotebookZoomMemory {
  // Zoom gestures update this without rebuilding their SwiftUI hosting view mid-gesture.
  private var scales: [UUID: Double] = [:]
  subscript(id: UUID) -> Double? {
    get { scales[id] }
    set { scales[id] = newValue }
  }
}

@MainActor @Observable final class InkClipboard {
  static let shared = InkClipboard()
  var strokes: [Stroke] = []
  var images: [PageAsset] = []
  var texts: [TextBox] = []
  var assets: [String: Data] = [:]
}
