import CoreGraphics
import Foundation
import ImageIO
import NoteCraftCore
import PDFKit
import Testing
import UniformTypeIdentifiers

@testable import NoteCraft

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
}
