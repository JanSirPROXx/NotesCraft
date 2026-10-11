import CoreGraphics
import Foundation
import ImageIO
import NoteCraftCore
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import NoteCraft

@MainActor @Test func editedPDFBackgroundInvalidatesTheCanvasLayer() throws {
  var background = Page()
  background.strokes = [Stroke(samples: [Sample(point: Point(100, 100))], color: .red, width: 50)]
  let red = try PageRenderer.export(NotebookPackage(notebook: Notebook(pages: [background])))
  background.strokes[0].color = .blue
  let blue = try PageRenderer.export(NotebookPackage(notebook: Notebook(pages: [background])))
  var page = Page()
  page.backgroundPDF = "background.pdf"
  page.backgroundPage = 0
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  var configuration = CanvasConfiguration(
    page: page, assets: ["background.pdf": red], tool: .pen, color: .ink, width: 2,
    style: .ballpoint, pencilOnly: true, selection: [], onStroke: { _ in }, onGesture: { _ in },
    onTap: { _ in })
  view.configuration = configuration
  let context = try #require(
    CGContext(
      data: nil, width: 595, height: 842, bitsPerComponent: 8, bytesPerRow: 595 * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  )
  view.paint(configuration, context)
  let oldLayer = try #require(view.cachedPage)
  configuration.assets["background.pdf"] = blue
  view.configuration = configuration
  #expect(view.cachedPage == nil)
  view.paint(configuration, context)
  #expect(view.cachedPage !== oldLayer)
}

@MainActor @Test func PDFOutlinesAndInternalLinksFollowReorderedAndRemovedPages() throws {
  let original = try #require(
    PDFDocument(
      data: PageRenderer.export(NotebookPackage(notebook: Notebook(pages: [Page(), Page()])))))
  let first = try #require(original.page(at: 0))
  let second = try #require(original.page(at: 1))
  let root = PDFOutline()
  let chapter = PDFOutline()
  chapter.label = "Second chapter"
  chapter.destination = PDFDestination(page: second, at: CGPoint(x: 10, y: 200))
  root.insertChild(chapter, at: 0)
  original.outlineRoot = root
  let link = PDFAnnotation(
    bounds: CGRect(x: 20, y: 30, width: 40, height: 30), forType: .link, withProperties: nil)
  link.action = PDFActionGoTo(destination: PDFDestination(page: second, at: .zero))
  first.addAnnotation(link)
  let bytes = try #require(original.dataRepresentation())
  var pages = try PageRenderer.importPDF(bytes)
  for i in pages.indices { pages[i].backgroundPDF = "source.pdf" }
  let package = NotebookPackage(
    notebook: Notebook(pages: [pages[1], pages[0]]), assets: ["source.pdf": bytes])
  let output = try #require(PDFDocument(data: PDFEditor.export(package)))
  let target = try #require(output.outlineRoot?.child(at: 0)?.destination?.page)
  #expect(output.index(for: target) == 0)
  let outputLink = try #require(output.page(at: 1)?.annotations.first)
  let linkTarget = try #require((outputLink.action as? PDFActionGoTo)?.destination.page)
  #expect(output.index(for: linkTarget) == 0)
  let chapters = PDFNavigation.chapters(package)
  #expect(chapters.first?.pageID == pages[1].id)
  var removed = package
  removed.notebook.pages = [pages[0]]
  let single = try #require(PDFDocument(data: PDFEditor.export(removed)))
  #expect(single.outlineRoot?.numberOfChildren ?? 0 == 0)
  #expect(single.page(at: 0)?.annotations.first?.action == nil)
}

@MainActor @Test func unlockedCopyAndFormEditsPreserveTheOriginal() throws {
  let original = try #require(PDFDocument(data: PageRenderer.export(NotebookPackage())))
  let page = try #require(original.page(at: 0))
  let field = PDFAnnotation(
    bounds: CGRect(x: 50, y: 50, width: 180, height: 30), forType: .widget, withProperties: nil)
  field.widgetFieldType = .text
  field.fieldName = "Name"
  field.widgetStringValue = "Original"
  page.addAnnotation(field)
  let checkbox = PDFAnnotation(
    bounds: CGRect(x: 50, y: 100, width: 20, height: 20), forType: .widget, withProperties: nil)
  checkbox.widgetFieldType = .button
  checkbox.widgetControlType = .checkBoxControl
  checkbox.fieldName = "Accepted"
  page.addAnnotation(checkbox)
  let outlineRoot = PDFOutline()
  let chapter = PDFOutline()
  chapter.label = "Form page"
  chapter.destination = PDFDestination(page: page, at: .zero)
  outlineRoot.insertChild(chapter, at: 0)
  original.outlineRoot = outlineRoot
  let encrypted = try #require(
    original.dataRepresentation(options: [
      PDFDocumentWriteOption.userPasswordOption: "secret",
      PDFDocumentWriteOption.ownerPasswordOption: "owner",
    ]))
  #expect(throws: (any Error).self) { try PDFEditor.unlock(encrypted, password: "wrong") }
  let unlocked = try PDFEditor.unlock(encrypted, password: "secret")
  #expect(PDFDocument(data: encrypted)?.isLocked == true)
  #expect(PDFDocument(data: unlocked)?.isLocked == false)
  #expect(PDFDocument(data: unlocked)?.outlineRoot?.child(at: 0)?.label == "Form page")
  let provider = try #require(CGDataProvider(data: unlocked as CFData))
  #expect(CGPDFDocument(provider)?.isUnlocked == true)
  var fields = PDFForms.fields(unlocked, pageIndex: 0)
  #expect(fields.count == 2)
  fields[0].value = "Updated"
  fields[1].checked = true
  let updated = try PDFForms.apply(fields, to: unlocked, pageIndex: 0)
  let roundTrip = PDFForms.fields(updated, pageIndex: 0)
  #expect(roundTrip[0].value == "Updated")
  #expect(roundTrip[1].checked)
  #expect(PDFForms.fields(unlocked, pageIndex: 0)[0].value == "Original")
}

@MainActor @Test func PDFExportKeepsDimensionsAndVectorText() throws {
  var page = Page(paper: Paper(size: .letter, pattern: .squared, landscape: true))
  page.texts = [TextBox(origin: Point(50, 70), text: "Vector text survives export")]
  page.strokes = [
    Stroke(
      samples: [Sample(point: Point(50, 110)), Sample(point: Point(300, 160))], color: .blue,
      width: 3)
  ]
  var second = Page()
  second.backgroundSize = Point(400, 900)
  let data = try PageRenderer.export(NotebookPackage(notebook: Notebook(pages: [page, second])))
  let pdf = try #require(PDFDocument(data: data))
  #expect(pdf.pageCount == 2)
  #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 792, height: 612))
  #expect(pdf.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 400, height: 900))
  #expect(
    pdf.string?.replacingOccurrences(of: "\n", with: " ").contains("Vector text survives export")
      == true)
  let imported = try PageRenderer.importPDF(data)
  #expect(imported.map(\.dimensions) == [Point(792, 612), Point(400, 900)])
}
@MainActor @Test func renderPaperAndInkPreview() throws {
  var page = Page()
  page.texts = [TextBox(origin: Point(48, 62), text: "NoteCraft\nA little space to think.")]
  page.strokes = [
    Stroke(
      samples: (0...100).map { i in
        Sample(
          point: Point(50 + Double(i) * 3, 200 + sin(Double(i) / 12) * 30),
          pressure: 0.4 + Double(i) / 200)
      }, color: .blue, width: 3, style: .fountain)
  ]
  guard
    let c = CGContext(
      data: nil, width: 595, height: 842, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  else {
    Issue.record("Unable to create rendering context")
    return
  }
  c.translateBy(x: 0, y: 842)
  c.scaleBy(x: 1, y: -1)
  PageRenderer.render(page, assets: [:], in: c)
  let image = try #require(c.makeImage())
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "NoteCraft-render-check.png")
  let destination = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
}

@MainActor @Test func croppedScreenshotAndBackgroundImport() async throws {
  var page = Page(paper: Paper(pattern: .dotted))
  page.texts = [TextBox(origin: Point(40, 40), text: "Imported background")]
  let package = NotebookPackage(notebook: Notebook(title: "PDF", pages: [page]))
  let pdf = try PageRenderer.export(package)
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".pdf")
  try pdf.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  let imported = try await ImportEngine().pdf(url)
  #expect(imported.notebook.pages.count == 1)
  #expect(imported.notebook.pages[0].backgroundPage == 0)
  #expect(imported.assets.count == 1)
  let png = try PageRenderer.screenshot(
    imported.notebook.pages[0], assets: imported.assets,
    bounds: Rect(x: 20, y: 20, width: 200, height: 100))
  let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  #expect(image.width == 400)
  #expect(image.height == 200)
}

@MainActor @Test func retainedCanvasMatchesDirectRenderingAtZoom() throws {
  var page = Page(paper: Paper(pattern: .blank))
  page.strokes = [
    Stroke(
      samples: [Sample(point: Point(50, 60)), Sample(point: Point(180, 60))], color: .blue, width: 3
    )
  ]
  func context() throws -> CGContext {
    let c = try #require(
      CGContext(
        data: nil, width: 1190, height: 1684, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.translateBy(x: 0, y: 1684)
    c.scaleBy(x: 1, y: -1)
    return c
  }
  let direct = try context()
  direct.scaleBy(x: 2, y: 2)
  PageRenderer.render(page, assets: [:], in: direct)
  let retained = try context()
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 1190, height: 1684))
  let configuration = CanvasConfiguration(
    page: page, assets: [:], tool: .pen, color: .blue, width: 3, style: .ballpoint,
    pencilOnly: false, selection: [], onStroke: { _ in }, onGesture: { _ in }, onTap: { _ in })
  view.configuration = configuration
  view.paint(configuration, retained)
  func inkBounds(_ c: CGContext) throws -> CGRect {
    let bytes = try #require(c.data).assumingMemoryBound(to: UInt8.self)
    var minX = c.width
    var minY = c.height
    var maxX = 0
    var maxY = 0
    for y in 0..<c.height {
      for x in 0..<c.width {
        let offset = y * c.bytesPerRow + x * 4
        if bytes[offset] < 150 && bytes[offset + 2] > 150 {
          minX = min(minX, x)
          maxX = max(maxX, x)
          minY = min(minY, y)
          maxY = max(maxY, y)
        }
      }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
  let directBounds = try inkBounds(direct)
  let retainedBounds = try inkBounds(retained)
  #expect(directBounds == retainedBounds)
  var movingConfiguration = configuration
  movingConfiguration.tool = .lasso
  movingConfiguration.selection = [page.strokes[0].id]
  view.configuration = movingConfiguration
  view.resetInput()
  view.accept(Sample(point: Point(120, 60)))
  view.accept(Sample(point: Point(120, 100)))
  view.paint(movingConfiguration, try context())
  let stationaryLayer = try #require(view.cachedPage)
  view.accept(Sample(point: Point(150, 120)))
  let moved = try context()
  view.paint(movingConfiguration, moved)
  #expect(view.cachedPage === stationaryLayer)
  let bytes = try #require(moved.data).assumingMemoryBound(to: UInt8.self)
  func isBlue(_ point: Point) -> Bool {
    let offset = Int(point.y * 2) * moved.bytesPerRow + Int(point.x * 2) * 4
    return bytes[offset] < 150 && bytes[offset + 2] > 150
  }
  #expect(!isBlue(Point(140, 60)))
  #expect(isBlue(Point(140, 120)))
}

@MainActor @Test func lockedPDFsAreRejectedWithoutChangingTheirBytes() async throws {
  let original = try #require(PDFDocument(data: PageRenderer.export(NotebookPackage())))
  let encrypted = try #require(
    original.dataRepresentation(options: [
      PDFDocumentWriteOption.userPasswordOption: "secret",
      PDFDocumentWriteOption.ownerPasswordOption: "owner",
    ]))
  #expect(PDFDocument(data: encrypted)?.isLocked == true)
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".pdf")
  try encrypted.write(to: url)
  defer { try? FileManager.default.removeItem(at: url) }
  await #expect(throws: PackageError.self) { try await ImportEngine().pdf(url) }
  var page = Page()
  page.backgroundPDF = "locked.pdf"
  let package = NotebookPackage(
    notebook: Notebook(pages: [page]), assets: ["locked.pdf": encrypted])
  #expect(throws: PackageError.self) { try PDFEditor.export(package) }
  #expect(try Data(contentsOf: url) == encrypted)
}

@MainActor @Test func nativeCanvasHoldAndLassoCommitOnlyOnRelease() async throws {
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  var committed: Stroke?
  var translation: Point?
  var page = Page()
  let selected = Stroke(samples: [Sample(point: Point(30, 30)), Sample(point: Point(70, 70))])
  page.strokes = [selected]
  view.configuration = CanvasConfiguration(
    page: page, assets: [:], tool: .pen, color: .ink,
    width: 2, style: .ballpoint, pencilOnly: false, selection: [],
    onStroke: { committed = $0 }, onGesture: { _ in }, onTap: { _ in },
    onTranslateSelection: { translation = $0 })
  for i in 0...48 {
    let angle = Double(i) / 48 * 2 * Double.pi
    view.accept(Sample(point: Point(100 + 40 * cos(angle), 100 + 40 * sin(angle))))
  }
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while view.input.held == nil && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(view.input.held != nil)
  #expect(committed == nil)
  view.accept(Sample(point: Point(180, 100)))
  view.finish()
  let shape = try #require(committed)
  #expect(abs(shape.bounds.width - 162) < 1)
  view.configuration?.tool = .lasso
  view.configuration?.selection = [selected.id]
  view.accept(Sample(point: Point(50, 50)))
  view.accept(Sample(point: Point(100, 120)))
  #expect(translation == nil)
  view.finish()
  #expect(translation == Point(50, 70))
  #expect(view.configuration?.page.strokes == [selected])
}

@MainActor @Test func selectionHandlesPreviewThenCommitResizeAndRotation() throws {
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  var page = Page()
  let selected = Stroke(samples: [Sample(point: Point(100, 100)), Sample(point: Point(200, 200))])
  page.strokes = [selected]
  var committed: SelectionTransform?
  let configuration = CanvasConfiguration(
    page: page, assets: [:], tool: .lasso, color: .ink,
    width: 2, style: .ballpoint, pencilOnly: true, selection: [selected.id],
    onStroke: { _ in }, onGesture: { _ in }, onTap: { _ in },
    onTransformSelection: { committed = $0 })
  view.configuration = configuration
  view.accept(Sample(point: Point(201, 201)))
  view.accept(Sample(point: Point(252, 252)))
  #expect(committed == nil)
  #expect(view.input.selectionHandle == .resize)
  #expect(abs((view.input.selectionTransform?.scale ?? 0) - 2) < 0.001)
  view.finish()
  #expect(abs((committed?.scale ?? 0) - 2) < 0.001)
  committed = nil
  view.accept(Sample(point: Point(150, 69)))
  view.accept(Sample(point: Point(231, 150)))
  #expect(view.input.selectionHandle == .rotate)
  #expect(committed == nil)
  view.finish()
  #expect(abs((committed?.angle ?? 0) - .pi / 2) < 0.001)
}

@MainActor @Test func rotatedTextRemainsSearchableInPDFAndBlankContinuationKeepsItsSize() throws {
  var page = Page(paper: Paper(pattern: .blank))
  page.backgroundSize = Point(900, 1200)
  var text = TextBox(origin: Point(150, 180), text: "Rotated searchable text")
  text.rotation = .pi / 4
  text.boxWidth = 250
  page.texts = [text]
  let package = NotebookPackage(
    notebook: Notebook(pages: [page, InkGestures.blankPage(matching: page)]))
  let data = try PDFEditor.export(package)
  let pdf = try #require(PDFDocument(data: data))
  #expect(pdf.pageCount == 2)
  #expect(pdf.string?.contains("Rotated searchable text") == true)
  #expect(pdf.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 900, height: 1200))
}

@MainActor @Test func searchFindsTypedAndPDFTextAfterPageReordering() throws {
  var background = Page(paper: Paper(pattern: .blank))
  background.texts = [TextBox(origin: Point(80, 100), text: "Searchable background nebula")]
  let data = try PageRenderer.export(NotebookPackage(notebook: Notebook(pages: [background])))
  var imported = Page(paper: Paper(pattern: .blank))
  imported.backgroundPDF = "source.pdf"
  var typed = Page()
  typed.texts = [TextBox(origin: Point(30, 50), text: "Typed nebula")]
  let package = NotebookPackage(
    notebook: Notebook(pages: [typed, imported]), assets: ["source.pdf": data])
  let result = DocumentSearch.find(package, query: "NEBULA")
  #expect(result.count == 2)
  #expect(result[0].pageID == typed.id && result[1].pageID == imported.id)
  #expect(result[1].pageNumber == 2 && !result[1].highlights.isEmpty)
  let highlight = try #require(result[1].highlights.first)
  #expect(highlight.x >= 80 && highlight.y >= 90 && highlight.y < 160)
  #expect(DocumentSearch.find(package, query: "not present").isEmpty)
}

@MainActor @Test func whiteboardGridContinuesBeyondThePageAndAtNegativeCoordinates() throws {
  for pattern in [PaperPattern.graph, .fineGraph, .squared, .dotted, .ruled] {
    let c = try #require(
      CGContext(
        data: nil, width: 200, height: 200,
        bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    c.translateBy(x: 3000, y: -4000)
    PageRenderer.render(
      Page(paper: Paper(pattern: pattern)), assets: [:], in: c,
      paperBounds: CGRect(x: -3000, y: 4000, width: 200, height: 200))
    let pixels = try #require(c.data).assumingMemoryBound(to: UInt8.self)
    let markedPixels = (0..<40000).filter { pixels[$0 * 4] < 250 }.count
    #expect(markedPixels > 20, "Background must cover distant whiteboard regions: \(pattern)")
  }
}
