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
  let fileURL: URL?
  var onBack: (() -> Void)? = nil
  var tabs: [WorkspaceTab] = []
  var onSelectTab: ((UUID) -> Void)? = nil
  var saveStatus: String = "Saved"
  var history: EditHistory = EditHistory()
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(\.openWindow) private var openWindow
  @State private var tool: InkTool = .pen
  @State private var previousTool: InkTool = .pen
  @State private var color: InkColor = .ink
  @State private var width = 2.5
  @AppStorage("penWidth1") private var firstWidth = 1.0
  @AppStorage("penWidth2") private var secondWidth = 2.5
  @AppStorage("penWidth3") private var thirdWidth = 5.0
  @State private var elements = ElementLibrary.shared
  @State private var selectedElementID: UUID?
  @State private var saveElementSheet = false
  @State private var elementName = "Element"
  @State private var fillShapes = false
  @State private var hexColor = "#1F2B3D"
  @State private var penStyle: PenStyle = .ballpoint
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
  @State private var clipboardImages: [PageAsset] = []
  @State private var clipboardTexts: [TextBox] = []
  @State private var errorMessage: String?
  @State private var activePage = 0
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
  @State private var clipboard: [Stroke] = []
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
  @State private var horizontal = false
  @State private var horizontalPageID: UUID?
  @State private var zoom = 1.0
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
  private var notebook: Notebook { document.package.notebook }
  private var page: Page { notebook.pages[min(activePage, notebook.pages.count - 1)] }
  var body: some View {
    VStack(spacing: 0) {
      topBar
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
            ScrollViewReader { proxy in
              ScrollView(horizontal ? .horizontal : .vertical) {
                if horizontal {
                  HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, p in
                      pageView(
                        p, index: index, availableWidth: geometry.size.width,
                        availableHeight: geometry.size.height
                      )
                      .frame(width: geometry.size.width).id(p.id)
                    }
                  }.scrollTargetLayout().padding(.vertical, 28)
                } else {
                  VStack(spacing: 28) {
                    ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, p in
                      pageView(p, index: index, availableWidth: geometry.size.width)
                    }
                  }.frame(maxWidth: .infinity).padding(.vertical, 28)
                }
              }.frame(width: geometry.size.width, height: geometry.size.height)
                .scrollTargetBehavior(NotebookPageBehavior(horizontal: horizontal))
                .scrollPosition(id: $horizontalPageID)
                .accessibilityIdentifier("notebookScrollView")
                .background(Color(red: 0.90, green: 0.92, blue: 0.94)).onChange(of: activePage) {
                  if horizontal {
                    withAnimation { horizontalPageID = page.id }
                  } else {
                    withAnimation { proxy.scrollTo(page.id, anchor: .top) }
                  }
                }.onChange(of: horizontalPageID) {
                  if horizontal, let id = horizontalPageID,
                    let index = notebook.pages.firstIndex(where: { $0.id == id })
                  {
                    activePage = index
                  }
                }.onChange(of: horizontal) {
                  if horizontal { horizontalPageID = page.id } else { horizontalPageID = nil }
                }
            }
          }
        }
      }
      footer.overlay(alignment: .top) {
        if pagePullProgress > 0 {
          HStack(spacing: 10) {
            ProgressView(value: pagePullProgress).frame(width: 60)
            Text("Keep pulling to add a page").font(.system(size: 12))
          }.padding(10).background(.regularMaterial, in: Capsule()).offset(y: -44)
            .allowsHitTesting(false).accessibilityIdentifier("pagePullProgress")
        }
      }
      if importing { ProgressView("Importing…").padding(8) }
    }
    .background(Color.white).foregroundStyle(Color(red: 0.12, green: 0.16, blue: 0.22)).tint(accent)
    .environment(\.colorScheme, .light)
    .frame(minWidth: minimumWidth, minHeight: 500)
    .sheet(isPresented: $templateSheet) {
      TemplatePicker { paper in
        edit { $0.notebook.pages.append(Page(paper: paper)) }
        activePage = notebook.pages.count - 1
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
    .onChange(of: activePage) {
      let ids = Set(page.strokes.map(\.id) + page.images.map(\.id) + page.texts.map(\.id))
      selection.formIntersection(ids)
      if let imageSelection, !ids.contains(imageSelection) { self.imageSelection = nil }
    }
  }
  private var topBar: some View {
    HStack(spacing: 18) {
      Button {
        if let onBack { onBack() } else { dismiss() }
      } label: {
        Label("Documents", systemImage: "chevron.left")
      }
      Button {
        thumbnails.toggle()
      } label: {
        Image(systemName: "square.grid.2x2")
      }.help("Page thumbnails").accessibilityLabel("Pages")
      Spacer()
      TextField(
        "Notebook title",
        text: Binding(
          get: { notebook.title },
          set: { value in
            document.package.notebook.title = value
            document.package.notebook.revision += 1
          })
      ).font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center).frame(
        maxWidth: 280)
      Spacer()
      Button {
        searchVisible.toggle()
      } label: {
        Image(systemName: "magnifyingglass")
      }.help("Search text")
      Button {
        edit { $0.notebook.pages[activePage].bookmarked.toggle() }
      } label: {
        Image(systemName: page.bookmarked ? "bookmark.fill" : "bookmark")
      }.help("Bookmark page")
      Button {
        do {
          exportData = try PDFEditor.export(document.package)
          exportType = .pdf
          exporter = true
        } catch { errorMessage = error.localizedDescription }
      } label: {
        Image(systemName: "square.and.arrow.up")
      }.help("Export PDF")
      Menu {
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
        Button("Add page", systemImage: "plus") { templateSheet = true }
        Button("Paste ink", systemImage: "doc.on.clipboard") { paste() }.disabled(
          clipboard.isEmpty && clipboardImages.isEmpty && clipboardTexts.isEmpty)
        Toggle("Horizontal pages", isOn: $horizontal)
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
        Image(systemName: "ellipsis")
      }
    }.buttonStyle(.plain).padding(.horizontal, 22).frame(height: 55)
  }
  private var tabBar: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
          if tabs.isEmpty { Text(notebook.title).padding(.horizontal, 20).frame(height: 36) }
          ForEach(tabs) { tab in
            Button {
              onSelectTab?(tab.id)
            } label: {
              Label(tab.title, systemImage: "book.closed").lineLimit(1).padding(.horizontal, 18)
                .frame(height: 36)
                .background(tab.selected ? Color.white.opacity(0.2) : .clear)
            }.buttonStyle(.plain)
          }
        }
      }
      if notebook.kind != .whiteboard {
        Button {
          templateSheet = true
        } label: {
          Image(systemName: "plus").padding(14)
        }.buttonStyle(.plain).accessibilityLabel("Add page")
      }
    }.font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white).background(accent)
  }
  private var toolBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        Button {
          undo()
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }.disabled(undoStack.isEmpty).help("Undo").accessibilityLabel("Undo").keyboardShortcut(
          "z", modifiers: .command)
        Button {
          redo()
        } label: {
          Image(systemName: "arrow.uturn.forward")
        }.disabled(redoStack.isEmpty).help("Redo").accessibilityLabel("Redo").keyboardShortcut(
          "z", modifiers: [.command, .shift])
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
              if item == .elements { settings = true }
            }
          } label: {
            Image(systemName: icon(item)).font(.system(size: 20)).frame(width: 36, height: 38)
              .foregroundStyle(tool == item ? accent : Color(red: 0.12, green: 0.16, blue: 0.22))
              .background(
                tool == item ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
          }
          .help(label(item)).accessibilityLabel(label(item))
          .popover(isPresented: Binding(get: { settings && tool == item }, set: { settings = $0 }))
          { toolSettings.padding(22).frame(width: 290) }
        }
        Divider().frame(height: 24)
        ForEach([InkColor.ink, .blue, .red, .green, .yellow], id: \.self) { ink in
          Button {
            color = ink
          } label: {
            Circle().fill(swiftColor(ink)).frame(width: 20, height: 20).padding(4).overlay(
              Circle().stroke(color == ink ? accent : .clear, lineWidth: 1.5))
          }.accessibilityLabel("Ink color")
        }
        Spacer(minLength: 4)
        ForEach([firstWidth, secondWidth, thirdWidth], id: \.self) { value in
          Button {
            width = value
          } label: {
            Circle().fill(Color(red: 0.12, green: 0.16, blue: 0.22)).frame(
              width: value + 3, height: value + 3
            ).frame(
              width: 26, height: 32
            ).background(
              width == value ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
          }.help("\(value.formatted()) pt")
        }
      }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: 58)
    }.background(.white).overlay(alignment: .bottom) { Divider() }
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
        Slider(value: $width, in: 0.5...12)
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
        Slider(value: $width, in: 3...40)
      case .highlighter:
        Toggle("Draw straight lines", isOn: $straightHighlight)
        Text("Width \(width.formatted()) pt")
        Slider(value: $width, in: 8...30)
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
        Button("Import image") {
          settings = false
          importType = .image
          importer = true
        }
        Button("Photo library") {
          settings = false
          photoLibrary = true
        }
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
      VStack(spacing: 18) {
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
      ? max(120, min(availableWidth - 56, 780, fittedWidth)) * zoom : availableWidth
    return VStack(spacing: 10) {
      NativeCanvas(
        configuration: CanvasConfiguration(
          page: displayPage(p, index: index), assets: document.package.assets, tool: tool,
          color: color, width: tool == .highlighter ? max(12, width) : width, style: penStyle,
          pencilOnly: pencilOnly, selection: index == activePage ? selection : [],
          onStroke: { stroke in
            activePage = index
            var s = stroke
            if tool == .shapes {
              s = Editing.shape(from: s)
              s.fillColor = fillShapes ? color : nil
            }
            if tool == .highlighter && straightHighlight, let first = s.samples.first,
              let last = s.samples.last
            {
              s.samples = [first, last]
            }
            let targets =
              tool == .pen && scratchToErase
              ? InkGestures.scratchTargets(s.samples.map(\.point), strokes: p.strokes) : []
            edit { package in
              if targets.isEmpty {
                package.notebook.pages[index].strokes.append(s)
              } else {
                package.notebook.pages[index].strokes.removeAll { targets.contains($0.id) }
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
          onAppendPage: boardHeight == nil && !horizontal && index == notebook.pages.count - 1
            ? {
              let next = InkGestures.blankPage(matching: p)
              edit { $0.notebook.pages.append(next) }
              activePage = notebook.pages.count - 1
            } : nil,
          onPagePull: { pagePullProgress = $0 }, holdToShape: holdToShape,
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
          Button {
            selectionMenuPresented.toggle()
          } label: {
            Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold)).padding(10)
          }.buttonStyle(.plain).foregroundStyle(accent).background(.white, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
            .position(
              x: min(w - 26, max(26, (b.x + b.width) * scale + offset.x + 24)),
              y: min(
                (boardHeight ?? w * p.dimensions.y / p.dimensions.x) - 26,
                max(26, b.y * scale + offset.y - 25))
            )
            .accessibilityLabel("Selection actions")
            .popover(isPresented: $selectionMenuPresented) {
              selectionActions.padding(16).frame(width: 240)
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
        color: Color.black.opacity(0.10), radius: 6, y: 2)
      if boardHeight == nil {
        Text("\(index + 1) / \(notebook.pages.count)").font(.system(size: 11)).foregroundStyle(
          Color(white: 0.4))
      }
    }.id(p.id)
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
  private var footer: some View {
    HStack {
      Text(
        fileURL == nil
          ? "New notebook · Save to choose a location"
          : "\(fileURL!.lastPathComponent) · \(saveStatus)"
      ).lineLimit(1)
      Spacer()
      Text(
        notebook.kind == .whiteboard
          ? "Whiteboard" : "\(notebook.pages.count) \(notebook.pages.count == 1 ? "page" : "pages")"
      ).accessibilityIdentifier("pageCount")
      if notebook.kind != .whiteboard {
        Button {
          navigator = true
        } label: {
          Text("\(activePage + 1) / \(notebook.pages.count)")
        }.accessibilityElement(children: .ignore).accessibilityIdentifier("pageNavigator")
          .accessibilityLabel("Navigate document").accessibilityValue(
            "\(activePage + 1) / \(notebook.pages.count)")
      }
      Button {
        if notebook.kind == .whiteboard {
          boardViewport.scale = max(0.1, boardViewport.scale / 1.2)
        } else {
          zoom = max(0.5, zoom - 0.1)
        }
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      Text("\(Int((notebook.kind == .whiteboard ? boardViewport.scale : zoom) * 100))%")
        .monospacedDigit().frame(width: 42)
      Button {
        if notebook.kind == .whiteboard {
          boardViewport.scale = min(12, boardViewport.scale * 1.2)
        } else {
          zoom = min(2, zoom + 0.1)
        }
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
    }.font(.system(size: 11)).foregroundStyle(Color(red: 0.32, green: 0.37, blue: 0.43))
      .buttonStyle(.plain).padding(
        .horizontal, 18
      ).frame(height: 30)
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
      Text("Image").font(.caption)
      Button("Move right") {
        edit { p in
          if let i = p.notebook.pages[activePage].images.firstIndex(where: { $0.id == id }) {
            p.notebook.pages[activePage].images[i].frame.x += 20
          }
        }
      }
      Button("Enlarge") {
        edit { p in
          if let i = p.notebook.pages[activePage].images.firstIndex(where: { $0.id == id }) {
            p.notebook.pages[activePage].images[i].frame.width *= 1.1
            p.notebook.pages[activePage].images[i].frame.height *= 1.1
          }
        }
      }
      Button("Rotate") {
        edit { p in
          if let i = p.notebook.pages[activePage].images.firstIndex(where: { $0.id == id }) {
            p.notebook.pages[activePage].images[i].rotation += .pi / 12
          }
        }
      }
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
    edit {
      $0.assets[name] = data
      $0.notebook.pages[activePage].images.append(
        PageAsset(filename: name, frame: Rect(x: x, y: y, width: w, height: w * ratio)))
    }
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
      HStack(spacing: 12) {
        ForEach(PaperPattern.allCases, id: \.self) { p in
          Button {
            pattern = p
          } label: {
            VStack {
              Canvas { context, s in
                context.withCGContext { c in
                  c.scaleBy(x: s.width / 595, y: s.width / 595)
                  PageRenderer.paper(Paper(pattern: p), in: c)
                }
              }.frame(width: 68, height: 96).background(.white).overlay(
                Rectangle().stroke(
                  pattern == p ? Color.blue : .gray.opacity(0.25), lineWidth: pattern == p ? 2 : 1))
              Text(p.rawValue.capitalized).font(.caption)
            }
          }.buttonStyle(.plain)
        }
      }
      Button("Add page") {
        onCreate(Paper(size: size, pattern: pattern, landscape: landscape))
        dismiss()
      }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
    }.padding(28).frame(width: 450)
  }
}

private struct NotebookPageBehavior: ScrollTargetBehavior {
  let horizontal: Bool
  func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
    if horizontal { PagingScrollTargetBehavior().updateTarget(&target, context: context) }
  }
}
