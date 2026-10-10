import SwiftUI
import UniformTypeIdentifiers
import NoteCraftCore

struct PDFExport: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct Workspace: View {
    @Binding var document: NoteDocument
    let fileURL: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var tool: InkTool = .pen
    @State private var previousTool: InkTool = .pen
    @State private var color: InkColor = .ink
    @State private var width = 2.5
    @State private var penStyle: PenStyle = .ballpoint
    @State private var eraserMode: EraserMode = .stroke
    @State private var highlighterOnly = false
    @State private var autoDeselect = false
    @State private var straightHighlight = false
    @State private var pencilOnly = false
    @State private var settings = false
    @State private var thumbnails = false
    @State private var templateSheet = false
    @State private var importer = false
    @State private var importType: UTType = .pdf
    @State private var exporter = false
    @State private var exportData = Data()
    @State private var errorMessage: String?
    @State private var activePage = 0
    @State private var selection: Set<UUID> = []
    @State private var undoStack: [NotebookPackage] = []
    @State private var redoStack: [NotebookPackage] = []
    @State private var clipboard: [Stroke] = []
    @State private var textSheet = false
    @State private var text = ""
    @State private var textSize = 20.0
    @State private var insertPoint = Point(60, 80)
    @State private var searchVisible = false
    @State private var search = ""
    @State private var horizontal = false
    @State private var zoom = 1.0
    @State private var customColor = Color.black
    @State private var imageSelection: UUID?
    @State private var imageScale = 1.0
    @State private var imageRotation = 0.0
    private let accent = Color(red: 0.17, green: 0.36, blue: 0.72)
    private var notebook: Notebook { document.package.notebook }
    private var page: Page { notebook.pages[min(activePage, notebook.pages.count - 1)] }
    var body: some View {
        VStack(spacing: 0) {
            topBar
            tabBar
            toolBar
            if searchVisible { searchBar }
            if !selection.isEmpty { selectionBar }
            if let imageSelection { imageControls(imageSelection) }
            HStack(spacing: 0) {
                if thumbnails { pageSidebar }
                GeometryReader { geometry in
                    ScrollViewReader { proxy in ScrollView(horizontal ? .horizontal : .vertical) {
                        if horizontal {
                            HStack(alignment: .top, spacing: 28) { ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, p in pageView(p, index: index, availableWidth: geometry.size.width) } }.padding(28)
                        } else {
                            VStack(spacing: 28) { ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, p in pageView(p, index: index, availableWidth: geometry.size.width) } }.frame(maxWidth: .infinity).padding(.vertical, 28)
                        }
                    }.background(Color(red: 0.90, green: 0.92, blue: 0.94)).onChange(of: activePage) { withAnimation { proxy.scrollTo(page.id, anchor: .top) } } }
                }
            }
            footer
        }
        .background(Color.white).tint(accent)
        .frame(minWidth: 600, minHeight: 500)
        .sheet(isPresented: $templateSheet) { TemplatePicker { paper in edit { $0.notebook.pages.append(Page(paper: paper)) }; activePage = notebook.pages.count - 1 } }
        .sheet(isPresented: $textSheet) { textEditor }
        .fileImporter(isPresented: $importer, allowedContentTypes: [importType]) { result in importFile(result) }
        .fileExporter(isPresented: $exporter, document: PDFExport(data: exportData), contentType: .pdf, defaultFilename: notebook.title) { result in if case .failure(let error) = result { errorMessage = error.localizedDescription } }
        .alert("Unable to complete the operation", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") { errorMessage = nil } } message: { Text(errorMessage ?? "") }
        .onChange(of: activePage) { selection = []; imageSelection = nil }
    }
    private var topBar: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: { Label("Documents", systemImage: "chevron.left") }
            Button { thumbnails.toggle() } label: { Image(systemName: "square.grid.2x2") }.help("Page thumbnails")
            Spacer()
            TextField("Notebook title", text: Binding(get: { notebook.title }, set: { value in document.package.notebook.title = value; document.package.notebook.revision += 1 })).font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center).frame(maxWidth: 280)
            Spacer()
            Button { searchVisible.toggle() } label: { Image(systemName: "magnifyingglass") }.help("Search text")
            Button { edit { $0.notebook.pages[activePage].bookmarked.toggle() } } label: { Image(systemName: page.bookmarked ? "bookmark.fill" : "bookmark") }.help("Bookmark page")
            Button { do { exportData = try PageRenderer.export(document.package); exporter = true } catch { errorMessage = error.localizedDescription } } label: { Image(systemName: "square.and.arrow.up") }.help("Export PDF")
            Menu {
                Button("Import PDF", systemImage: "doc") { importType = .pdf; importer = true }
                Button("Add page", systemImage: "plus") { templateSheet = true }
                Button("Paste ink", systemImage: "doc.on.clipboard") { paste() }.disabled(clipboard.isEmpty)
                Toggle("Horizontal pages", isOn: $horizontal)
                Toggle("Apple Pencil only", isOn: $pencilOnly)
                Button("Delete current page", role: .destructive) { if notebook.pages.count > 1 { edit { $0.notebook.pages.remove(at: activePage) }; activePage = min(activePage, notebook.pages.count - 1) } }.disabled(notebook.pages.count == 1)
            } label: { Image(systemName: "ellipsis") }
        }.buttonStyle(.plain).padding(.horizontal, 22).frame(height: 55)
    }
    private var tabBar: some View {
        HStack(spacing: 0) {
            HStack { Image(systemName: "book.closed"); Text(notebook.title).lineLimit(1); Spacer(); Image(systemName: "chevron.down").font(.caption) }.padding(.horizontal, 18).frame(width: 260, height: 36).background(Color.white.opacity(0.16))
            Spacer()
            Button { templateSheet = true } label: { Image(systemName: "plus") }.padding(.horizontal, 20).help("Add page")
        }.font(.system(size: 12, weight: .medium)).foregroundStyle(.white).background(accent)
    }
    private var toolBar: some View {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) {
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(undoStack.isEmpty).help("Undo").keyboardShortcut("z", modifiers: .command)
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(redoStack.isEmpty).help("Redo").keyboardShortcut("z", modifiers: [.command, .shift])
            Divider().frame(height: 24)
            ForEach(InkTool.allCases, id: \.self) { item in
                Button {
                    if tool == item { settings.toggle() } else { previousTool = tool; tool = item; selection = []; imageSelection = nil }
                } label: { Image(systemName: icon(item)).font(.system(size: 20)).frame(width: 36, height: 38).foregroundStyle(tool == item ? accent : Color.primary).background(tool == item ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7)) }
                .help(label(item)).accessibilityLabel(label(item))
                .popover(isPresented: Binding(get: { settings && tool == item }, set: { settings = $0 })) { toolSettings.padding(22).frame(width: 290) }
            }
            Divider().frame(height: 24)
            ForEach([InkColor.ink, .blue, .red, .green, .yellow], id: \.self) { ink in
                Button { color = ink } label: { Circle().fill(swiftColor(ink)).frame(width: 20, height: 20).padding(4).overlay(Circle().stroke(color == ink ? accent : .clear, lineWidth: 1.5)) }.accessibilityLabel("Ink color")
            }
            Spacer(minLength: 4)
            ForEach([1.0, 2.5, 5.0], id: \.self) { value in
                Button { width = value } label: { Circle().fill(Color.primary).frame(width: value + 3, height: value + 3).frame(width: 26, height: 32).background(width == value ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5)) }.help("\(value.formatted()) pt")
            }
        }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: 58) }.background(.white).overlay(alignment: .bottom) { Divider() }
    }
    @ViewBuilder private var toolSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(label(tool)).font(.headline)
            switch tool {
            case .pen:
                Picker("Pen style", selection: $penStyle) { ForEach(PenStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented)
                Text("Thickness \(width.formatted()) pt"); Slider(value: $width, in: 0.5...12)
                ColorPicker("Custom color", selection: $customColor).onChange(of: customColor) { color = convertColor(customColor) }
            case .eraser:
                Picker("Mode", selection: $eraserMode) { ForEach(EraserMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Toggle("Erase highlighter only", isOn: $highlighterOnly); Toggle("Auto-deselect", isOn: $autoDeselect)
                Text("Radius \(width.formatted()) pt"); Slider(value: $width, in: 3...40)
            case .highlighter:
                Toggle("Draw straight lines", isOn: $straightHighlight)
                Text("Width \(width.formatted()) pt"); Slider(value: $width, in: 8...30)
            case .shapes: Text("Draw a line, rectangle or circle. Closed strokes snap to geometric shapes.").font(.callout)
            case .lasso: Text("Circle ink to select it, then cut, copy, recolor, move or resize it.").font(.callout)
            case .image: Button("Import image") { settings = false; importType = .image; importer = true }
            case .text: Text("Tap the page to add a text box.")
            case .elements: Text("Tap the page to insert a reusable star stamp.")
            case .readOnly: Text("Drawing is locked. Use the scroll view to read your pages.")
            }
        }
    }
    private var pageSidebar: some View {
        ScrollView { VStack(spacing: 18) { ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, p in
            Button { activePage = index } label: {
                VStack(spacing: 8) {
                    Canvas { context, size in context.withCGContext { c in c.scaleBy(x: size.width / p.dimensions.x, y: size.width / p.dimensions.x); PageRenderer.render(p, assets: document.package.assets, in: c) } }.frame(width: 112, height: 112 * p.dimensions.y / p.dimensions.x).background(.white).overlay(Rectangle().stroke(index == activePage ? accent : Color.gray.opacity(0.25), lineWidth: index == activePage ? 2 : 1))
                    HStack { Text("\(index + 1)"); if p.bookmarked { Image(systemName: "bookmark.fill") } }.font(.caption)
                }
            }.buttonStyle(.plain)
        } }.padding(20) }.frame(width: 160).background(Color(red: 0.96, green: 0.97, blue: 0.98))
    }
    private func pageView(_ p: Page, index: Int, availableWidth: Double) -> some View {
        let w = max(300, min(availableWidth - 56, 780)) * zoom
        return VStack(spacing: 10) {
            NativeCanvas(configuration: CanvasConfiguration(page: p, assets: document.package.assets, tool: tool, color: color, width: tool == .highlighter ? max(12, width) : width, style: penStyle, pencilOnly: pencilOnly, selection: index == activePage ? selection : [], onStroke: { stroke in
                activePage = index
                var s = stroke
                if tool == .shapes { s = Editing.shape(from: s) }
                if tool == .highlighter && straightHighlight, let first = s.samples.first, let last = s.samples.last { s.samples = [first, last] }
                edit { $0.notebook.pages[index].strokes.append(s) }
            }, onGesture: { points in
                activePage = index
                if tool == .eraser {
                    edit { package in for point in points { package.notebook.pages[index].strokes = Editing.erase(strokes: package.notebook.pages[index].strokes, at: point, radius: max(8, width), mode: eraserMode, highlighterOnly: highlighterOnly) } }
                    if autoDeselect { tool = previousTool == .eraser ? .pen : previousTool }
                } else { selection = Editing.selection(strokes: p.strokes, polygon: points, bounds: Rect(x: 0, y: 0, width: p.dimensions.x, height: p.dimensions.y)) }
            }, onTap: { point in
                activePage = index; insertPoint = point
                if tool == .text { text = ""; textSheet = true }
                if tool == .image {
                    if let image = p.images.last(where: { $0.frame.contains(point) }) { imageSelection = image.id; imageScale = 1; imageRotation = image.rotation }
                    else { importType = .image; importer = true }
                }
                if tool == .elements { insertStar(point) }
            })).frame(width: w, height: w * p.dimensions.y / p.dimensions.x).background(.white).shadow(color: Color.black.opacity(0.10), radius: 6, y: 2)
            Text("\(index + 1) / \(notebook.pages.count)").font(.system(size: 11)).foregroundStyle(.secondary)
        }.id(p.id)
    }
    private var selectionBar: some View {
        HStack {
            Text("\(selection.count) selected").font(.caption)
            Button("Cut") { clipboard = page.strokes.filter { selection.contains($0.id) }; deleteSelection() }
            Button("Copy") { clipboard = page.strokes.filter { selection.contains($0.id) } }
            Button("Paste") { paste() }.disabled(clipboard.isEmpty)
            Button("Delete", role: .destructive) { deleteSelection() }
            Button("Change color") { edit { p in for i in p.notebook.pages[activePage].strokes.indices where selection.contains(p.notebook.pages[activePage].strokes[i].id) { p.notebook.pages[activePage].strokes[i].color = color } } }
            Button("Move right") { transformSelection(scale: 1, angle: 0, dx: 20) }
            Button("Enlarge") { transformSelection(scale: 1.15, angle: 0, dx: 0) }
            Button("Rotate") { transformSelection(scale: 1, angle: .pi / 12, dx: 0) }
            Spacer(); Button("Done") { selection = [] }
        }.buttonStyle(.borderless).padding(12).background(accent.opacity(0.05))
    }
    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass"); TextField("Search text boxes", text: $search)
            ForEach(Array(notebook.pages.enumerated()).filter { !search.isEmpty && $0.element.texts.contains { $0.text.localizedCaseInsensitiveContains(search) } }, id: \.element.id) { i, _ in Button("Page \(i + 1)") { activePage = i; thumbnails = true } }
            Button("Done") { searchVisible = false; search = "" }
        }.padding(12)
    }
    private var footer: some View {
        HStack {
            Text(fileURL == nil ? "New notebook · Save to choose a location" : "\(fileURL!.lastPathComponent) · System autosave").lineLimit(1)
            Spacer(); Text("\(notebook.pages.count) pages")
            Button { zoom = max(0.5, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int(zoom * 100))%").monospacedDigit().frame(width: 42)
            Button { zoom = min(2, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
        }.font(.system(size: 11)).foregroundStyle(.secondary).buttonStyle(.plain).padding(.horizontal, 18).frame(height: 30)
    }
    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add text").font(.title2.bold())
            TextEditor(text: $text).font(.system(size: textSize)).frame(height: 180).border(.gray.opacity(0.2))
            HStack { Text("Font size"); Slider(value: $textSize, in: 10...60); Text("\(Int(textSize)) pt") }
            HStack { Button("Cancel") { textSheet = false }; Spacer(); Button("Insert") { var box = TextBox(origin: insertPoint, text: text); box.size = textSize; box.color = color; edit { $0.notebook.pages[activePage].texts.append(box) }; textSheet = false }.buttonStyle(.borderedProminent).disabled(text.isEmpty) }
        }.padding(28).frame(width: 440)
    }
    private func imageControls(_ id: UUID) -> some View {
        HStack {
            Text("Image").font(.caption)
            Button("Move right") { edit { p in if let i = p.notebook.pages[activePage].images.firstIndex(where: { $0.id == id }) { p.notebook.pages[activePage].images[i].frame.x += 20 } } }
            Button("Enlarge") { edit { p in if let i = p.notebook.pages[activePage].images.firstIndex(where: { $0.id == id }) { p.notebook.pages[activePage].images[i].frame.width *= 1.1; p.notebook.pages[activePage].images[i].frame.height *= 1.1 } } }
            Button("Rotate") { edit { p in if let i = p.notebook.pages[activePage].images.firstIndex(where: { $0.id == id }) { p.notebook.pages[activePage].images[i].rotation += .pi / 12 } } }
            Button("Delete", role: .destructive) { edit { $0.notebook.pages[activePage].images.removeAll { $0.id == id } }; imageSelection = nil }
            Spacer(); Button("Done") { imageSelection = nil }
        }.padding(12).buttonStyle(.borderless)
    }
    private func edit(_ mutation: (inout NotebookPackage) -> Void) {
        undoStack.append(document.package); if undoStack.count > 60 { undoStack.removeFirst() }; redoStack = []
        mutation(&document.package); document.package.notebook.revision += 1
    }
    private func undo() { guard let old = undoStack.popLast() else { return }; redoStack.append(document.package); document.package = old; activePage = min(activePage, notebook.pages.count - 1); selection = [] }
    private func redo() { guard let next = redoStack.popLast() else { return }; undoStack.append(document.package); document.package = next; activePage = min(activePage, notebook.pages.count - 1); selection = [] }
    private func deleteSelection() { edit { $0.notebook.pages[activePage].strokes.removeAll { selection.contains($0.id) } }; selection = [] }
    private func paste() { edit { p in p.notebook.pages[activePage].strokes += clipboard.map { var s = $0; s.id = UUID(); s.samples = s.samples.map { var sample = $0; sample.point.x += 20; sample.point.y += 20; return sample }; return s } } }
    private func transformSelection(scale: Double, angle: Double, dx: Double) {
        let points = page.strokes.filter { selection.contains($0.id) }.flatMap { $0.samples.map(\.point) }
        guard !points.isEmpty else { return }
        let center = Point(points.map(\.x).reduce(0, +) / Double(points.count), points.map(\.y).reduce(0, +) / Double(points.count))
        edit { p in for i in p.notebook.pages[activePage].strokes.indices where selection.contains(p.notebook.pages[activePage].strokes[i].id) {
            p.notebook.pages[activePage].strokes[i].samples = p.notebook.pages[activePage].strokes[i].samples.map { var s = $0; let x = (s.point.x - center.x) * scale, y = (s.point.y - center.y) * scale; s.point = Point(center.x + x * cos(angle) - y * sin(angle) + dx, center.y + x * sin(angle) + y * cos(angle)); return s }
        } }
    }
    private func insertStar(_ point: Point) {
        let points = (0...10).map { i in let angle = Double(i) * .pi / 5 - .pi / 2, r = i % 2 == 0 ? 30.0 : 13.0; return Sample(point: Point(point.x + r * cos(angle), point.y + r * sin(angle))) }
        edit { $0.notebook.pages[activePage].strokes.append(Stroke(samples: points, color: color, width: width)) }
    }
    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url), name = UUID().uuidString + "." + url.pathExtension
            if importType == .pdf {
                var pages = try PageRenderer.importPDF(data)
                for i in pages.indices { pages[i].backgroundPDF = name }
                edit { $0.assets[name] = data; $0.notebook.pages.append(contentsOf: pages) }; activePage = notebook.pages.count - pages.count
            } else {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PackageError.invalidAsset(name) }
                let w = min(260.0, page.dimensions.x - insertPoint.x - 20), h = w * Double(image.height) / Double(image.width)
                edit { $0.assets[name] = data; $0.notebook.pages[activePage].images.append(PageAsset(filename: name, frame: Rect(x: insertPoint.x, y: insertPoint.y, width: max(20, w), height: h))) }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func swiftColor(_ c: InkColor) -> Color { Color(red: c.red, green: c.green, blue: c.blue) }
    private func convertColor(_ c: Color) -> InkColor {
        #if os(macOS)
        let rgb = NSColor(c).usingColorSpace(.deviceRGB) ?? .black
        return InkColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; UIColor(c).getRed(&r, green: &g, blue: &b, alpha: &a)
        return InkColor(red: r, green: g, blue: b)
        #endif
    }
    private func icon(_ tool: InkTool) -> String { switch tool { case .pen: "pencil.tip"; case .eraser: "eraser"; case .highlighter: "highlighter"; case .shapes: "square.on.circle"; case .lasso: "lasso"; case .elements: "star.square"; case .image: "photo"; case .text: "textformat"; case .readOnly: "hand.draw" } }
    private func label(_ tool: InkTool) -> String { tool == .readOnly ? "Read only" : tool.rawValue.capitalized }
}

struct TemplatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var pattern: PaperPattern = .ruled
    @State private var size: PaperSize = .a4
    @State private var landscape = false
    let onCreate: (Paper) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { Text("New page").font(.title2.bold()); Spacer(); Button("Cancel") { dismiss() } }
            Picker("Paper size", selection: $size) { ForEach(PaperSize.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Toggle("Landscape", isOn: $landscape)
            HStack(spacing: 12) { ForEach(PaperPattern.allCases, id: \.self) { p in
                Button { pattern = p } label: { VStack {
                    Canvas { context, s in context.withCGContext { c in c.scaleBy(x: s.width / 595, y: s.width / 595); PageRenderer.paper(Paper(pattern: p), in: c) } }.frame(width: 68, height: 96).background(.white).overlay(Rectangle().stroke(pattern == p ? Color.blue : .gray.opacity(0.25), lineWidth: pattern == p ? 2 : 1))
                    Text(p.rawValue.capitalized).font(.caption)
                } }.buttonStyle(.plain)
            } }
            Button("Add page") { onCreate(Paper(size: size, pattern: pattern, landscape: landscape)); dismiss() }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(28).frame(width: 450)
    }
}
