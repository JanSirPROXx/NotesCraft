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
  @State private var sticker: StickerChoice?
  @State private var saveElementSheet = false
  @State private var elementName = "Element"
  @State private var fillShapes = false
  // The shape the shapes tool inserts; nil keeps freehand drawing that snaps to exact shapes.
  @State private var shapeKind: ShapeKind?
  @State private var shapesPalette = false
  @State private var hexColor = "#1F2B3D"
  @AppStorage("penStyle") private var penStyle: PenStyle = .ballpoint
  @AppStorage("fountainSharpness") private var tipSharpness = 0.5
  @AppStorage("fountainPressure") private var tipPressure = 0.5
  @AppStorage("fountainFlatness") private var tipFlatness = 0.0
  @AppStorage("penStabilization") private var stabilization = 0.0
  @State private var eraserMode: EraserMode = .stroke
  @State private var highlighterOnly = false
  @State private var autoDeselect = false
  @State private var straightHighlight = false
  @AppStorage("pencilOnlyDrawing") private var pencilOnly = true
  @AppStorage("holdToShape") private var holdToShape = true
  @AppStorage("scratchToErase") private var scratchToErase = true
  @AppStorage("gpuInk") private var gpuInk = true
  @AppStorage("scribbleHint") private var scribbleHintMode = ScribbleHintMode.sometimes
  // Shown after a scribble took ink away, so a drawing that was mistaken for one can be kept.
  @State private var scribbleHint: ScribbleHint?
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
  @State private var selectionPalette = false
  // Where (page index, document point) a long finger press asked for the paste bar.
  @State private var pasteSpot: (index: Int, point: Point)?
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
  @State private var inlineText: InlineText?
  @State private var coalesce: (key: String, date: Date)?
  private var boardViewport: ViewTransform {
    get { notebook.viewport ?? ViewTransform(scale: 1, offset: Point(30, 30)) }
    nonmutating set {
      document.package.notebook.viewport = newValue
      document.package.notebook.revision += 1
    }
  }
  private let accent = Color(red: 0.17, green: 0.36, blue: 0.72)
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
  private var widthBinding: Binding<Double> { Binding(get: { width.tenths }, set: { width = $0.tenths }) }
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
            // The blank page that swiping creates sits in the same list as the real pages and
            // keeps its ID when it becomes one, so its view (and zoom surface) is never rebuilt.
            ForEach(
              Array((notebook.pages + (trailingPage.map { [$0] } ?? [])).enumerated()),
              id: \.element.id
            ) { index, p in
              notebookPage(p, index: index, size: geometry.size)
                .frame(width: geometry.size.width).id(p.id)
                .allowsHitTesting(index < notebook.pages.count)
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
      .overlay(alignment: .bottom) { scribbleHintBar }
      if importing { ProgressView("Importing…").padding(8) }
    }
    .background(Color.white).foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22)).tint(accent)
    .environment(\.colorScheme, .light).preferredColorScheme(.dark)
    .frame(minHeight: 500)
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
    .onChange(of: notebook.pages.last?.paper) { refreshTrailingPage() }
    .onChange(of: lastPageHasContent) { ensureBlankTrailingPage() }
    .onChange(of: infinite) { ensureBlankTrailingPage() }
    .onAppear {
      #if DEBUG
        // Screenshot tour (scripts/screenshots.sh): fill a new, empty document with a sample page.
        if notebook.pages.count == 1, page.strokes.isEmpty, page.texts.isEmpty,
          let scene = ScreenshotScenes.next()
        {
          ScreenshotScenes.fill(&document.package.notebook, scene: scene)
        }
      #endif
      refreshTrailingPage()
      ensureBlankTrailingPage()
    }
    .onChange(of: notebook.pages.first?.id) {
      // The tab switched to another notebook; this view's state is reused across tabs.
      selection = []
      inlineText = nil
      refreshTrailingPage()
    }
    .onDisappear { pageHUDTask?.cancel() }
    .focusedSceneValue(\.workspaceActions, workspaceActions)
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
        initialPattern: page.paper.pattern, initialColor: page.paper.color,
        isPDFPage: page.backgroundPDF != nil, whiteboard: notebook.kind == .whiteboard
      ) { pattern, color, allPages in
        let currentID = page.id
        edit { package in
          for index in package.notebook.pages.indices {
            if package.notebook.pages[index].backgroundPDF == nil,
              allPages || package.notebook.pages[index].id == currentID
            {
              package.notebook.pages[index].paper.pattern = pattern
              package.notebook.pages[index].paper.color = color
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
              sticker = .clip(clip.id)
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
      Toggle("Fast GPU ink", isOn: $gpuInk)
      Toggle("Scribble to erase", isOn: $scratchToErase)
      Picker("Scribble hint", selection: $scribbleHintMode) {
        ForEach(ScribbleHintMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }.disabled(!scratchToErase)
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
  private func switchTool(to item: InkTool) {
    previousTool = tool
    tool = item
    selection = []
    commitInlineText()
    if item == .elements || item == .image { settings = true }
  }
  private var workspaceActions: WorkspaceActions {
    WorkspaceActions(
      tools: InkTool.allCases.map { .init(tool: $0, title: label($0)) },
      selectTool: { item in if tool != item { switchTool(to: item) } },
      toggleEraser: {
        if tool == .eraser {
          tool = previousTool
        } else {
          previousTool = tool
          tool = .eraser
        }
      },
      previousPage: { activePage = max(0, activePage - 1) },
      nextPage: { activePage = min(notebook.pages.count - 1, activePage + 1) },
      addPage: { appendPage(InkGestures.blankPage(matching: page)) },
      canGoBack: activePage > 0,
      canGoForward: activePage < notebook.pages.count - 1)
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
                switchTool(to: item)
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
            ) {
              ScrollView { toolSettings.padding(22) }
                .frame(width: 320).frame(maxHeight: 640).preferredColorScheme(.dark)
            }
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
          Button {
            shapesPalette.toggle()
          } label: {
            Group {
              if let shapeKind {
                ShapeIcon(kind: shapeKind)
              } else {
                Image(systemName: "scribble").font(.system(size: 18))
              }
            }.frame(width: 26, height: 26).hitTarget(width: 46)
              .background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 7))
          }
          .accessibilityLabel("Shape: \(shapeKind?.title ?? "Freehand")")
          .popover(isPresented: $shapesPalette) {
            ShapePalette(selection: $shapeKind) { shapesPalette = false }
              .presentationCompactAdaptation(.popover)
          }
          Button {
            fillShapes.toggle()
          } label: {
            Image(systemName: fillShapes ? "square.fill" : "square").font(.system(size: 18))
              .hitTarget(width: 38)
          }.accessibilityLabel(fillShapes ? "Fill on" : "Fill off")
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
        if penStyle == .fountain {
          PenTipSettings(
            sharpness: $tipSharpness, pressure: $tipPressure, flatness: $tipFlatness,
            color: color, width: width)
        }
        DraftSlider(title: "Stroke stabilization", value: $stabilization)
        PointSlider(title: "Thickness", value: widthBinding, range: 0.5...12)
        ColorPicker("Custom color", selection: $customColor).onChange(of: customColor) {
          color = convertColor(customColor)
        }
        TextField("Hex color, e.g. #265DD4", text: $hexColor).onSubmit {
          if let parsed = InkColor(hex: hexColor) { color = parsed }
        }
        Stepper(
          "Preset 1: \(firstWidth.pointLabel) pt", value: $firstWidth, in: 0.5...12, step: 0.1)
        Stepper(
          "Preset 2: \(secondWidth.pointLabel) pt", value: $secondWidth, in: 0.5...12, step: 0.1)
        Stepper(
          "Preset 3: \(thirdWidth.pointLabel) pt", value: $thirdWidth, in: 0.5...12, step: 0.1)
      case .eraser:
        Picker("Mode", selection: $eraserMode) {
          ForEach(EraserMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        Toggle("Erase highlighter only", isOn: $highlighterOnly)
        Toggle("Auto-deselect", isOn: $autoDeselect)
        PointSlider(title: "Radius", value: widthBinding, range: 3...40)
      case .highlighter:
        Toggle("Draw straight lines", isOn: $straightHighlight)
        PointSlider(title: "Width", value: widthBinding, range: 6...40)
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
      case .text: Text("Tap the page to type a text box.")
      case .elements:
        ElementPicker(
          library: elements,
          onSelect: { choice in
            sticker = choice
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
  // Kept out of `pageView`: one expression holding every canvas callback is too big for the type checker.
  private func canvasConfiguration(
    _ p: Page, index: Int, boardHeight: Double?, viewScale: Double
  ) -> CanvasConfiguration {
      CanvasConfiguration(
        page: displayPage(p, index: index), assets: document.package.assets, tool: tool,
        color: color, width: width, style: penStyle,
        pencilOnly: pencilOnly, selection: index == activePage ? selection : [],
        onStroke: { stroke in
          activePage = index
          var s = stroke
          if tool == .shapes {
            // A new figure starts fresh; the previous one must not stay grabbable.
            selection = []
            if let kind = shapeKind, let first = s.samples.first, let last = s.samples.last {
              insertShape(kind, from: first.point, to: last.point)
              return
            }
            // Freehand: exact shape when the stroke clearly is one, otherwise ordinary ink.
            if let exact = InkGestures.recognizedShape(s) {
              s = exact
              s.fillColor = fillShapes && s.samples.count > 3 ? color : nil
            } else {
              s.tool = .pen
            }
          }
          if tool == .highlighter && straightHighlight, let first = s.samples.first,
            let last = s.samples.last
          {
            s.samples = [first, last]
          }
          let scribble = tool == .pen && scratchToErase ? s.samples.map(\.point) : nil
          var certainty: InkGestures.ScratchOutcome.Certainty?
          edit { package in
            // Judge the scribble against the page as it is now, not the snapshot this closure
            // captured: two quick scribbles would otherwise both start from the same old page
            // and the second would bring back what the first had erased.
            let current = package.notebook.pages[index].strokes
            if let scribble, let outcome = InkGestures.scratchOutcome(scribble, strokes: current) {
              package.notebook.pages[index].strokes = outcome.strokes
              certainty = outcome.certainty
            } else {
              package.notebook.pages[index].strokes.append(s)
            }
          }
          if let certainty, scribbleHintMode.shows(for: certainty) {
            scribbleHint = ScribbleHint(
              page: index, stroke: s, revision: document.package.notebook.revision)
          }
        },
        onGesture: { points in
          activePage = index
          if tool == .eraser {
            edit { package in
              package.notebook.pages[index].strokes = Editing.erase(
                strokes: package.notebook.pages[index].strokes, along: points,
                radius: max(8, width), mode: eraserMode, highlighterOnly: highlighterOnly)
            }
            if autoDeselect { tool = previousTool == .eraser ? .pen : previousTool }
          } else if let tapped = points.first, tapExtent(points) < 10 / viewScale {
            selectObject(at: tapped, on: p, viewScale: viewScale)
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
          if tool == .lasso { selectObject(at: point, on: p, viewScale: viewScale) }
          if tool == .text { beginInlineText(at: point, on: p) }
          if tool == .image {
            if let image = p.images.last(where: { $0.contains(point) }) {
              selection = [image.id]
            } else {
              selection = []
              importType = .image
              importer = true
            }
          }
          if tool == .elements { insertSticker(point) }
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
        onLongPress: { point in
          activePage = index
          pasteSpot = (index, point)
        },
        onTouchDown: {
          if pasteSpot != nil { pasteSpot = nil }
          if scribbleHint != nil { scribbleHint = nil }
        },
        onPencilDetected: { pencilOnly = true },
        onPencilAction: { action in
          switch action {
          case .switchEraser:
            if tool == .eraser {
              tool = previousTool
            } else {
              previousTool = tool
              tool = .eraser
            }
          case .switchPrevious:
            (tool, previousTool) = (previousTool, tool)
          case .showPalette:
            settings.toggle()
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
        scribblePreview: scratchToErase, gpuInk: gpuInk,
        eraserMode: eraserMode, highlighterOnly: highlighterOnly,
        searchHighlights: searchVisible
          ? documentSearch.results.first(where: { $0.pageID == p.id })?.highlights ?? [] : [],
        tip: PenTip(sharpness: tipSharpness, pressure: tipPressure, flatness: tipFlatness),
        stabilization: stabilization, shapeKind: tool == .shapes ? shapeKind : nil)
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
    let viewScale = boardHeight == nil ? w / p.dimensions.x : boardViewport.scale
    return VStack(spacing: 10) {
      NativeCanvas(
        configuration: canvasConfiguration(p, index: index, boardHeight: boardHeight, viewScale: viewScale))
      .accessibilityElement()
      .accessibilityLabel("Drawing canvas")
      .accessibilityIdentifier("drawingCanvas")
      .accessibilityValue("\(p.strokes.count) strokes")
      .overlay(alignment: .topLeading) {
        selectionBar(p, index: index, pageWidth: w, boardHeight: boardHeight, scale: viewScale)
      }
      .overlay(alignment: .topLeading) {
        pasteBar(index: index, pageWidth: w, boardHeight: boardHeight, scale: viewScale, page: p)
      }
      .overlay(alignment: .topLeading) {
        if index == activePage, inlineText != nil {
          InlineTextEditor(
            draft: Binding(
              get: { inlineText ?? InlineText(origin: Point(0, 0), size: 20, width: 220, color: .ink) },
              set: { inlineText = $0 }),
            scale: viewScale, offset: boardHeight == nil ? Point(0, 0) : boardViewport.offset,
            pageHeight: p.dimensions.y, onDone: { commitInlineText() },
            onDelete: { discardInlineText() }, onMore: { moreTextOptions() })
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
    let next = InkGestures.blankPage(matching: last)
    if keepZoomOnNewPage { pageZoom[next.id] = pageZoom[last.id] ?? 1 }
    trailingPage = next
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
    if index == activePage, let id = inlineText?.id { result.texts.removeAll { $0.id == id } }
    return result
  }
  private func menuRow(
    _ title: String, _ symbol: String, role: ButtonRole? = nil, disabled: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(role: role) {
      action()
    } label: {
      Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .contentShape(Rectangle())
    }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
  }
  private var selectedStrokes: [Stroke] { page.strokes.filter { selection.contains($0.id) } }
  private var selectionColor: InkColor {
    if let stroke = selectedStrokes.first {
      return stroke.fillOpacity == 1 ? (stroke.fillColor ?? stroke.color) : stroke.color
    }
    return page.texts.first { selection.contains($0.id) }?.color ?? color
  }
  private var selectionColorBinding: Binding<InkColor> {
    Binding(get: { selectionColor }, set: { recolorSelection($0) })
  }
  private var selectionWidthBinding: Binding<Double> {
    Binding(
      get: { selectedStrokes.first?.width ?? penWidth },
      set: { value in
        edit(coalescing: "selectionWidth") { p in
          for i in p.notebook.pages[activePage].strokes.indices
          where selection.contains(p.notebook.pages[activePage].strokes[i].id) {
            p.notebook.pages[activePage].strokes[i].width = value
          }
        }
      })
  }
  private var selectionFill: Int {
    guard let stroke = selectedStrokes.first(where: { $0.shape?.kind.isClosed == true }) else {
      return 0
    }
    return stroke.fillColor == nil ? 0 : stroke.fillOpacity == 1 ? 2 : 1
  }
  private var selectionActions: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
          .padding(.bottom, 4)
        if selectedStrokes.contains(where: { $0.shape != nil }) {
          PointSlider(title: "Line width", value: selectionWidthBinding, range: 0.5...20)
            .padding(.vertical, 4)
          if selectedStrokes.contains(where: { $0.shape?.kind.isClosed == true }) {
            Picker(
              "Fill",
              selection: Binding(get: { selectionFill }, set: { setSelectionFill($0) })
            ) {
              Text("No fill").tag(0)
              Text("Light").tag(1)
              Text("Solid").tag(2)
            }.pickerStyle(.segmented).padding(.vertical, 4)
          }
          Divider().padding(.vertical, 4)
        }
        menuRow("Cut", "scissors") {
          copySelection()
          deleteSelection()
          selectionMenuPresented = false
        }
        menuRow("Copy", "doc.on.doc") { copySelection() }
        menuRow(
          "Paste", "doc.on.clipboard",
          disabled: clipboard.isEmpty && clipboardImages.isEmpty && clipboardTexts.isEmpty
        ) {
          paste()
          selectionMenuPresented = false
        }
        menuRow("Duplicate", "plus.square.on.square") {
          copySelection()
          paste()
          selectionMenuPresented = false
        }
        Divider().padding(.vertical, 4)
        menuRow("Bring to front", "square.3.layers.3d.top.filled") { reorderSelection(toFront: true) }
        menuRow("Send to back", "square.3.layers.3d.bottom.filled") {
          reorderSelection(toFront: false)
        }
        Divider().padding(.vertical, 4)
        menuRow("Save as element", "star.square") {
          elementName = "Element \(elements.clips.count + 1)"
          selectionMenuPresented = false
          saveElementSheet = true
        }
        menuRow("Screenshot", "camera.viewfinder") {
          do {
            exportData = try PageRenderer.screenshot(
              page, assets: document.package.assets, bounds: selectionBounds())
            exportType = .png
            exporter = true
          } catch { errorMessage = error.localizedDescription }
        }
        menuRow("Deselect", "xmark.circle") {
          selection = []
          selectionMenuPresented = false
        }
        menuRow("Delete", "trash", role: .destructive) {
          deleteSelection()
          selectionMenuPresented = false
        }
      }
    }
    .padding(14).frame(width: 270).frame(maxHeight: 520)
    .foregroundStyle(.primary).preferredColorScheme(.dark)
    .onChange(of: selection) { if selection.isEmpty { selectionMenuPresented = false } }
  }
  @ViewBuilder private func selectionBar(
    _ p: Page, index: Int, pageWidth w: Double, boardHeight: Double?, scale: Double
  ) -> some View {
    if index == activePage, !selection.isEmpty,
      let b = InkGestures.selectionBounds(page: p, ids: selection)
    {
      let offset = boardHeight == nil ? Point(0, 0) : boardViewport.offset
      let height = boardHeight ?? w * p.dimensions.y / p.dimensions.x
      // The page sits in a zoom surface that magnifies everything on it, so the bar is shrunk
      // back to a constant on-screen size.
      let zoomed = boardHeight == nil ? max(1, pageZoom[p.id] ?? 1) : 1
      HStack(spacing: 0) {
        Button {
          copySelection()
          deleteSelection()
        } label: {
          Image(systemName: "scissors").hitTarget(width: 44, height: 44)
        }.accessibilityLabel("Cut selection")
        Button {
          copySelection()
        } label: {
          Image(systemName: "doc.on.doc").hitTarget(width: 44, height: 44)
        }.accessibilityLabel("Copy selection")
        Button {
          selectionPalette.toggle()
        } label: {
          Circle().fill(selectionColor.swiftUI).frame(width: 22, height: 22)
            .overlay(Circle().stroke(Color.white.opacity(0.7), lineWidth: 1.5))
            .hitTarget(width: 44, height: 44)
        }
        .accessibilityLabel("Change color")
        .popover(isPresented: $selectionPalette) {
          ColorPalette(color: selectionColorBinding).presentationCompactAdaptation(.popover)
        }
        Button {
          deleteSelection()
        } label: {
          Image(systemName: "trash").hitTarget(width: 44, height: 44)
        }.foregroundStyle(.red).accessibilityLabel("Delete selection")
        Button {
          selectionMenuPresented.toggle()
        } label: {
          Image(systemName: "ellipsis.circle").hitTarget(width: 44, height: 44)
        }
        .accessibilityLabel("Selection actions")
        .popover(isPresented: $selectionMenuPresented) {
          selectionActions.presentationCompactAdaptation(.popover)
        }
      }
      .font(.system(size: 18)).padding(.horizontal, 6)
      .buttonStyle(.plain).foregroundStyle(.white)
      .background(Color(red: 0.16, green: 0.17, blue: 0.18), in: Capsule())
      .fixedSize()
      .scaleEffect(1 / zoomed)
      .position(
        x: min(w - 150 / zoomed, max(150 / zoomed, (b.x + b.width / 2) * scale + offset.x)),
        y: min(
          height - 30 / zoomed, max(30 / zoomed, (b.y + b.height) * scale + offset.y + 48 / zoomed)
        ))
    }
  }
  @ViewBuilder private func pasteBar(
    index: Int, pageWidth w: Double, boardHeight: Double?, scale: Double, page p: Page
  ) -> some View {
    if let spot = pasteSpot, spot.index == index {
      let offset = boardHeight == nil ? Point(0, 0) : boardViewport.offset
      let height = boardHeight ?? w * p.dimensions.y / p.dimensions.x
      let zoomed = boardHeight == nil ? max(1, pageZoom[p.id] ?? 1) : 1
      let empty = clipboard.isEmpty && clipboardImages.isEmpty && clipboardTexts.isEmpty
      Button {
        paste(at: spot.point)
        pasteSpot = nil
      } label: {
        Label("Paste", systemImage: "doc.on.clipboard").font(.system(size: 17, weight: .medium))
          .padding(.horizontal, 16).frame(minHeight: 44).contentShape(Capsule())
      }
      .buttonStyle(.plain).foregroundStyle(empty ? Color.white.opacity(0.4) : .white)
      .disabled(empty)
      .background(Color(red: 0.16, green: 0.17, blue: 0.18), in: Capsule())
      .fixedSize().scaleEffect(1 / zoomed).accessibilityIdentifier("pasteBar")
      .position(
        x: min(w - 60 / zoomed, max(60 / zoomed, spot.point.x * scale + offset.x)),
        y: min(height - 30 / zoomed, max(30 / zoomed, spot.point.y * scale + offset.y - 40 / zoomed)))
    }
  }
  @ViewBuilder private var scribbleHintBar: some View {
    if let hint = scribbleHint, hint.revision == document.package.notebook.revision {
      Button {
        keepScribbleAsInk(hint)
      } label: {
        Label("Erased  ·  Keep as ink", systemImage: "arrow.uturn.backward")
          .font(.system(size: 15, weight: .medium))
          .padding(.horizontal, 16).frame(minHeight: 44).contentShape(Capsule())
      }
      .buttonStyle(.plain).foregroundStyle(.white)
      .background(Color(red: 0.16, green: 0.17, blue: 0.18), in: Capsule())
      .padding(18).accessibilityIdentifier("scribbleHint")
      .task(id: hint.id) {
        try? await Task.sleep(for: .seconds(3))
        if scribbleHint?.id == hint.id { scribbleHint = nil }
      }
    }
  }
  // Takes the scribble back and puts it on the page as the stroke it was drawn as.
  private func keepScribbleAsInk(_ hint: ScribbleHint) {
    scribbleHint = nil
    guard hint.revision == document.package.notebook.revision else { return }
    undo()
    guard notebook.pages.indices.contains(hint.page) else { return }
    edit { $0.notebook.pages[hint.page].strokes.append(hint.stroke) }
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
        pencilOnly: pencilOnly || tool == .readOnly, zoomEnabled: !infinite,
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
  // Edits that share a `coalescing` key within two seconds (dragging through colors, say) form a
  // single undo step instead of filling the history.
  private func edit(coalescing key: String? = nil, _ mutation: (inout NotebookPackage) -> Void) {
    let now = Date()
    if let key, let last = coalesce, last.key == key, now.timeIntervalSince(last.date) < 2 {
      coalesce = (key, now)
    } else {
      undoStack.append(document.package)
      if undoStack.count > 60 { undoStack.removeFirst() }
      coalesce = key.map { ($0, now) }
    }
    redoStack = []
    mutation(&document.package)
    document.package.notebook.revision += 1
  }
  private func undo() {
    guard let old = undoStack.popLast() else { return }
    coalesce = nil
    redoStack.append(document.package)
    var restored = old
    restored.notebook.revision = document.package.notebook.revision + 1
    document.package = restored
    activePage = min(activePage, notebook.pages.count - 1)
    selection = []
  }
  private func redo() {
    guard let next = redoStack.popLast() else { return }
    coalesce = nil
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
  // With a target the copy is centred there (long press); without one it lands slightly offset
  // from the original so a duplicate is visible.
  private func paste(at target: Point? = nil) {
    var pasted: Set<UUID> = []
    var dx = 20.0
    var dy = 20.0
    if let target {
      let bounds =
        clipboard.map(\.bounds) + clipboardImages.map(\.bounds) + clipboardTexts.map(\.bounds)
      if let minX = bounds.map(\.x).min(), let minY = bounds.map(\.y).min() {
        let maxX = bounds.map { $0.x + $0.width }.max() ?? minX
        let maxY = bounds.map { $0.y + $0.height }.max() ?? minY
        dx = target.x - (minX + maxX) / 2
        dy = target.y - (minY + maxY) / 2
      }
    }
    edit { p in
      p.assets.merge(InkClipboard.shared.assets) { existing, _ in existing }
      p.notebook.pages[activePage].strokes += clipboard.map {
        var s = $0
        s.id = UUID()
        s.samples = s.samples.map {
          var sample = $0
          sample.point.x += dx
          sample.point.y += dy
          return sample
        }
        s.shape?.center.x += dx
        s.shape?.center.y += dy
        pasted.insert(s.id)
        return s
      }
      p.notebook.pages[activePage].images += clipboardImages.map {
        var image = $0
        image.id = UUID()
        image.frame.x += dx
        image.frame.y += dy
        pasted.insert(image.id)
        return image
      }
      p.notebook.pages[activePage].texts += clipboardTexts.map {
        var text = $0
        text.id = UUID()
        text.origin.x += dx
        text.origin.y += dy
        pasted.insert(text.id)
        return text
      }
    }
    // The pasted copy is what the next drag should move.
    selection = pasted
  }
  private func tapExtent(_ points: [Point]) -> Double {
    guard let first = points.first else { return 0 }
    return points.reduce(0) { max($0, $1.distance(to: first)) }
  }
  // Tapping with the lasso (or a finger) selects the object under the tap, like GoodNotes.
  private func selectObject(at point: Point, on p: Page, viewScale: Double) {
    if let id = InkGestures.objectID(at: point, page: p, tolerance: 12 / viewScale) {
      selection = [id]
    } else {
      selection = []
    }
  }
  private func insertShape(_ kind: ShapeKind, from a: Point, to b: Point) {
    let spec = ShapeSpec.dragged(kind, from: a, to: b)
    let stroke: Stroke =
      kind.isSticker
      ? .sticker(spec)
      : .shape(spec, color: color, width: width, fill: fillShapes && kind.isClosed ? color : nil)
    edit { $0.notebook.pages[activePage].strokes.append(stroke) }
    selection = [stroke.id]
  }
  private func insertSticker(_ point: Point) {
    guard let choice = sticker else {
      settings = true
      return
    }
    switch choice {
    case .vector(let kind):
      let object = Stroke.sticker(kind, at: point)
      edit { $0.notebook.pages[activePage].strokes.append(object) }
      selection = [object.id]
    case .emoji(let symbol):
      var box = TextBox(origin: point, text: symbol)
      box.size = 56
      box.boxWidth = 80
      box.alignment = "center"
      let frame = box.layoutBounds
      box.origin = Point(point.x - frame.width / 2, point.y - frame.height / 2)
      edit { $0.notebook.pages[activePage].texts.append(box) }
      selection = [box.id]
    case .clip(let id):
      guard let clip = elements.clips.first(where: { $0.id == id }) else { return }
      do {
        let before = Set(page.strokes.map(\.id) + page.images.map(\.id) + page.texts.map(\.id))
        var updated = document.package
        try clip.insert(into: &updated, pageIndex: activePage, at: point)
        edit { $0 = updated }
        let inserted = page
        selection = Set(
          (inserted.strokes.map(\.id) + inserted.images.map(\.id) + inserted.texts.map(\.id))
            .filter { !before.contains($0) })
      } catch { errorMessage = error.localizedDescription }
    }
  }
  private func recolorSelection(_ ink: InkColor) {
    edit(coalescing: "selectionColor") { p in
      for i in p.notebook.pages[activePage].strokes.indices
      where selection.contains(p.notebook.pages[activePage].strokes[i].id) {
        p.notebook.pages[activePage].strokes[i].recolor(ink)
      }
      for i in p.notebook.pages[activePage].texts.indices
      where selection.contains(p.notebook.pages[activePage].texts[i].id) {
        p.notebook.pages[activePage].texts[i].color = ink
      }
    }
  }
  private func setSelectionFill(_ mode: Int) {
    edit { p in
      for i in p.notebook.pages[activePage].strokes.indices
      where selection.contains(p.notebook.pages[activePage].strokes[i].id)
        && p.notebook.pages[activePage].strokes[i].shape?.kind.isClosed == true
      {
        let stroke = p.notebook.pages[activePage].strokes[i]
        // A solid sticker keeps its fill as the main color; plain shapes fill with their line color.
        let base = stroke.fillOpacity == 1 ? (stroke.fillColor ?? stroke.color) : (stroke.fillColor ?? stroke.color)
        switch mode {
        case 0: p.notebook.pages[activePage].strokes[i].fillColor = nil
        case 1:
          p.notebook.pages[activePage].strokes[i].fillColor = base
          p.notebook.pages[activePage].strokes[i].fillOpacity = nil
        default:
          p.notebook.pages[activePage].strokes[i].fillColor = base
          p.notebook.pages[activePage].strokes[i].fillOpacity = 1
        }
      }
    }
  }
  private func reorderSelection(toFront: Bool) {
    edit { p in
      let strokes = p.notebook.pages[activePage].strokes
      let chosen = strokes.filter { selection.contains($0.id) }
      let others = strokes.filter { !selection.contains($0.id) }
      p.notebook.pages[activePage].strokes = toFront ? others + chosen : chosen + others
    }
  }
  private func beginInlineText(at point: Point, on p: Page) {
    commitInlineText()
    if let box = p.texts.last(where: { $0.contains(point) }) {
      inlineText = InlineText(
        id: box.id, origin: box.layoutBounds.originPoint, text: box.text, size: box.size,
        width: box.boxWidth ?? 280, color: box.color)
    } else {
      inlineText = InlineText(
        origin: point, size: textSize, width: 220, color: color)
    }
    selection = []
  }
  private func commitInlineText() {
    guard let draft = inlineText else { return }
    inlineText = nil
    textSize = draft.size
    let empty = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if let id = draft.id {
      edit { package in
        guard let i = package.notebook.pages[activePage].texts.firstIndex(where: { $0.id == id })
        else { return }
        if empty {
          package.notebook.pages[activePage].texts.remove(at: i)
        } else {
          package.notebook.pages[activePage].texts[i].text = draft.text
          package.notebook.pages[activePage].texts[i].size = draft.size
          package.notebook.pages[activePage].texts[i].color = draft.color
          package.notebook.pages[activePage].texts[i].boxWidth = draft.width
        }
      }
    } else if !empty {
      var box = TextBox(origin: draft.origin, text: draft.text)
      box.size = draft.size
      box.color = draft.color
      box.boxWidth = draft.width
      edit { $0.notebook.pages[activePage].texts.append(box) }
    }
  }
  private func discardInlineText() {
    guard let draft = inlineText else { return }
    inlineText = nil
    if let id = draft.id {
      edit { $0.notebook.pages[activePage].texts.removeAll { $0.id == id } }
    }
  }
  // Font, alignment, border and background live in the full editor; the box is committed first
  // so the editor always works on a real text box.
  private func moreTextOptions() {
    guard let draft = inlineText else { return }
    commitInlineText()
    let target = draft.id ?? page.texts.last?.id
    guard let id = target, let box = page.texts.first(where: { $0.id == id }) else { return }
    editingTextID = id
    insertPoint = box.origin
    text = box.text
    textSize = box.size
    textFont = box.fontName ?? "System"
    textAlignment = box.alignment ?? "left"
    textBorder = box.border ?? false
    textBackground = box.background != nil
    textWidth = box.boxWidth ?? 280
    textSheet = true
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
    selection = [asset.id]
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
  @State private var color: InkColor?
  let onCreate: (Paper) -> Void
  init(initialPaper: Paper = Paper(), onCreate: @escaping (Paper) -> Void) {
    _pattern = State(initialValue: initialPaper.pattern)
    _size = State(initialValue: initialPaper.size)
    _landscape = State(initialValue: initialPaper.landscape)
    _color = State(initialValue: initialPaper.color)
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
      PaperPatternPicker(pattern: $pattern, color: color)
      PaperColorRow(color: $color)
      Button("Add page") {
        onCreate(Paper(size: size, pattern: pattern, landscape: landscape, color: color))
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
  var color: InkColor?
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
            }.frame(height: 68).background(color?.swiftUI ?? .white)
              .clipShape(RoundedRectangle(cornerRadius: 6))
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

struct PaperColorRow: View {
  @Binding var color: InkColor?
  var body: some View {
    HStack(spacing: 12) {
      ForEach(Array(Paper.colors.enumerated()), id: \.offset) { _, option in
        let selected = option.color == color
        Button {
          color = option.color
        } label: {
          Circle().fill(option.color?.swiftUI ?? .white).frame(width: 30, height: 30)
            .overlay(Circle().stroke(Color.gray.opacity(0.5), lineWidth: 1))
            .padding(4)
            .overlay(Circle().stroke(selected ? Color.blue : .clear, lineWidth: 2.5))
            .hitTarget(width: 44, height: 44)
        }
        .buttonStyle(.plain).accessibilityLabel("\(option.name) paper")
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
  }
}

private struct PaperBackgroundSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var pattern: PaperPattern
  @State private var color: InkColor?
  @State private var allPages = false
  let isPDFPage: Bool
  let whiteboard: Bool
  let onApply: (PaperPattern, InkColor?, Bool) -> Void
  init(
    initialPattern: PaperPattern, initialColor: InkColor?, isPDFPage: Bool, whiteboard: Bool,
    onApply: @escaping (PaperPattern, InkColor?, Bool) -> Void
  ) {
    _pattern = State(initialValue: initialPattern)
    _color = State(initialValue: initialColor)
    self.isPDFPage = isPDFPage
    self.whiteboard = whiteboard
    self.onApply = onApply
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Text("Paper background").font(.title2.bold())
      if isPDFPage && !allPages {
        Text("This page is a PDF, so its own background stays. Turn on “Apply to all non-PDF pages” to change the others.")
          .font(.callout).foregroundStyle(.secondary)
      }
      PaperPatternPicker(pattern: $pattern, whiteboard: whiteboard, color: color)
      Text("Paper color").font(.headline)
      PaperColorRow(color: $color)
      if !whiteboard { Toggle("Apply to all non-PDF pages", isOn: $allPages) }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Apply") {
          onApply(pattern, color, allPages)
          dismiss()
        }.buttonStyle(.borderedProminent).disabled(isPDFPage && !allPages)
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

enum ScribbleHintMode: String, CaseIterable {
  case off, sometimes, always
  var title: String {
    switch self {
    case .off: "Off"
    case .sometimes: "When unsure"
    case .always: "Always"
    }
  }
  func shows(for certainty: InkGestures.ScratchOutcome.Certainty) -> Bool {
    switch self {
    case .off: false
    case .sometimes: certainty == .doubtful
    case .always: true
    }
  }
}
struct ScribbleHint: Equatable {
  let id = UUID()
  let page: Int
  let stroke: Stroke
  let revision: UInt64
}
