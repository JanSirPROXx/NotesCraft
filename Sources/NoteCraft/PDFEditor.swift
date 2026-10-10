import NoteCraftCore
import PDFKit
import SwiftUI

@MainActor enum PDFEditor {
  static func export(_ package: NotebookPackage) throws -> Data {
    let result = PDFDocument()
    for (index, page) in package.notebook.pages.enumerated() {
      let source: PDFPage
      if let name = page.backgroundPDF {
        guard let bytes = package.assets[name], let original = PDFDocument(data: bytes) else {
          throw PackageError.invalidPackage
        }
        guard !original.isLocked else { throw PackageError.lockedPDF }
        guard let originalPage = original.page(at: page.backgroundPage ?? 0),
          let copy = originalPage.copy() as? PDFPage
        else { throw PackageError.invalidPackage }
        source = copy
      } else {
        let blank = NotebookPackage(notebook: Notebook(pages: [Page(paper: page.paper)]))
        guard let generated = PDFDocument(data: try PageRenderer.export(blank)),
          let copy = generated.page(at: 0)?.copy() as? PDFPage
        else { throw PackageError.invalidPackage }
        source = copy
      }
      if index == 0, let name = page.backgroundPDF, let data = package.assets[name],
        let original = PDFDocument(data: data)
      {
        result.documentAttributes = original.documentAttributes
      }
      let bounds = source.bounds(for: .mediaBox)
      let rotation = source.rotation
      let cgPage = source.pageRef
      let transform =
        cgPage?.getDrawingTransform(
          .mediaBox, rect: CGRect(x: 0, y: 0, width: page.dimensions.x, height: page.dimensions.y),
          rotate: 0, preserveAspectRatio: true
        ).inverted() ?? .identity
      func point(_ p: Point) -> CGPoint {
        CGPoint(x: p.x, y: page.dimensions.y - p.y).applying(transform)
      }
      for stroke in page.strokes.filter({ $0.tool == .highlighter })
        + page.strokes.filter({ $0.tool != .highlighter })
      {
        guard let first = stroke.samples.first else { continue }
        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = stroke.width
        annotation.border = border
        #if os(macOS)
          let path = NSBezierPath()
          path.move(to: point(first.point))
          for sample in stroke.samples.dropFirst() { path.line(to: point(sample.point)) }
          if stroke.samples.allSatisfy({ $0.point == first.point }) {
            path.line(to: point(Point(first.point.x + 0.01, first.point.y)))
          }
          annotation.color =
            NSColor(
              cgColor: PageRenderer.color(
                stroke.color, alpha: stroke.tool == .highlighter ? 0.3 : 1)) ?? .black
        #else
          let path = UIBezierPath()
          path.move(to: point(first.point))
          for sample in stroke.samples.dropFirst() { path.addLine(to: point(sample.point)) }
          if stroke.samples.allSatisfy({ $0.point == first.point }) {
            path.addLine(to: point(Point(first.point.x + 0.01, first.point.y)))
          }
          annotation.color = UIColor(
            cgColor: PageRenderer.color(stroke.color, alpha: stroke.tool == .highlighter ? 0.3 : 1))
        #endif
        annotation.add(path)
        source.addAnnotation(annotation)
      }
      for text in page.texts {
        let box = text.bounds
        let corners = [
          point(Point(box.x, box.y)), point(Point(box.x + box.width, box.y + box.height)),
        ]
        let rect = CGRect(
          x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
          width: abs(corners[1].x - corners[0].x), height: abs(corners[1].y - corners[0].y))
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.contents = text.text
        #if os(macOS)
          annotation.font =
            text.fontName.flatMap { NSFont(name: $0, size: text.size) }
            ?? NSFont.systemFont(ofSize: text.size)
          annotation.fontColor = NSColor(cgColor: PageRenderer.color(text.color))
          annotation.color =
            text.background.flatMap { NSColor(cgColor: PageRenderer.color($0, alpha: 0.2)) }
            ?? .clear
        #else
          annotation.font =
            text.fontName.flatMap { UIFont(name: $0, size: text.size) }
            ?? UIFont.systemFont(ofSize: text.size)
          annotation.fontColor = UIColor(cgColor: PageRenderer.color(text.color))
          annotation.color =
            text.background.map { UIColor(cgColor: PageRenderer.color($0, alpha: 0.2)) } ?? .clear
        #endif
        annotation.alignment =
          text.alignment == "center" ? .center : text.alignment == "right" ? .right : .left
        let border = PDFBorder()
        border.lineWidth = text.border == true ? 1 : 0
        annotation.border = border
        source.addAnnotation(annotation)
      }
      // Images and filled shapes need an appearance stream. Preserve the source's interactive annotations on that page.
      if !page.images.isEmpty || page.strokes.contains(where: { $0.fillColor != nil }) {
        var visual = page
        visual.strokes = page.strokes.filter { $0.fillColor != nil }
        visual.texts = []
        let layer = NotebookPackage(notebook: Notebook(pages: [visual]), assets: package.assets)
        if let rendered = PDFDocument(
          data: try PageRenderer.export(layer, includePDFAnnotations: false))?.page(at: 0)
        {
          for annotation in source.annotations { rendered.addAnnotation(annotation) }
          result.insert(rendered, at: index)
        } else {
          throw PackageError.invalidPackage
        }
      } else {
        source.rotation = rotation
        result.insert(source, at: index)
      }
    }
    guard let data = result.dataRepresentation() else { throw PackageError.invalidPackage }
    return data
  }
}
