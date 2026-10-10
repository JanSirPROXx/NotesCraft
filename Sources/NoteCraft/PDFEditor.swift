import NoteCraftCore
import PDFKit
import SwiftUI

@MainActor enum PDFEditor {
  static func unlock(_ data: Data, password: String) throws -> Data {
    guard let document = PDFDocument(data: data) else { throw PackageError.invalidPackage }
    guard document.unlock(withPassword: password) else { throw PDFOpenError.wrongPassword }
    // Copy pages into a new document rather than retaining the encrypted document container.
    let unlocked = PDFDocument()
    for i in 0..<document.pageCount {
      guard let page = document.page(at: i)?.copy() as? PDFPage else {
        throw PackageError.invalidPackage
      }
      unlocked.insert(page, at: i)
    }
    func destination(_ value: PDFDestination?) -> PDFDestination? {
      guard let value, let page = value.page,
        let target = unlocked.page(at: document.index(for: page))
      else { return nil }
      let result = PDFDestination(page: target, at: value.point)
      result.zoom = value.zoom
      return result
    }
    for i in 0..<document.pageCount {
      guard let source = document.page(at: i), let target = unlocked.page(at: i) else { continue }
      for (index, annotation) in source.annotations.enumerated() {
        let value = (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination
        if let mapped = destination(value), target.annotations.indices.contains(index) {
          target.annotations[index].action = PDFActionGoTo(destination: mapped)
        }
      }
    }
    func outline(_ original: PDFOutline, depth: Int) -> PDFOutline {
      let copied = PDFOutline()
      copied.label = original.label
      if let mapped = destination(original.destination) {
        copied.destination = mapped
      } else if let action = original.action as? PDFActionURL {
        copied.action = action.copy() as? PDFAction
      }
      if depth < 64 {
        for i in 0..<original.numberOfChildren {
          if let child = original.child(at: i) {
            copied.insertChild(outline(child, depth: depth + 1), at: copied.numberOfChildren)
          }
        }
      }
      copied.isOpen = original.isOpen
      return copied
    }
    if let root = document.outlineRoot { unlocked.outlineRoot = outline(root, depth: 0) }
    unlocked.documentAttributes = document.documentAttributes
    guard let bytes = unlocked.dataRepresentation(), let check = PDFDocument(data: bytes),
      !check.isLocked
    else { throw PackageError.lockedPDF }
    return bytes
  }

  static func export(_ package: NotebookPackage) throws -> Data {
    if package.notebook.kind == .whiteboard { return try PageRenderer.export(package) }
    let result = PDFDocument()
    var originals: [String: PDFDocument] = [:]
    var links:
      [(output: Int, annotation: Int, name: String, target: Int, point: CGPoint, zoom: CGFloat)] =
        []
    var pageMap: [String: [Int: Int]] = [:]
    for (index, page) in package.notebook.pages.enumerated() {
      if let name = page.backgroundPDF, let number = page.backgroundPage {
        if pageMap[name]?[number] == nil { pageMap[name, default: [:]][number] = index }
      }
    }
    for (index, page) in package.notebook.pages.enumerated() {
      let source: PDFPage
      if let name = page.backgroundPDF {
        if originals[name] == nil, let bytes = package.assets[name] {
          originals[name] = PDFDocument(data: bytes)
        }
        guard let original = originals[name] else {
          throw PackageError.invalidPackage
        }
        guard !original.isLocked else { throw PackageError.lockedPDF }
        guard let originalPage = original.page(at: page.backgroundPage ?? 0),
          let copy = originalPage.copy() as? PDFPage
        else { throw PackageError.invalidPackage }
        for (annotationIndex, annotation) in originalPage.annotations.enumerated() {
          let destination =
            (annotation.action as? PDFActionGoTo)?.destination ?? annotation.destination
          if let destination, let target = destination.page {
            links.append(
              (
                index, annotationIndex, name, original.index(for: target), destination.point,
                destination.zoom
              ))
          }
        }
        source = copy
      } else {
        var blankPage = Page(paper: page.paper)
        blankPage.backgroundSize = page.dimensions
        let blank = NotebookPackage(notebook: Notebook(pages: [blankPage]))
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
      for text in page.texts where abs(text.rotation ?? 0) < 0.0001 {
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
      // Arbitrarily rotated text, images and fills need a vector appearance; keep interactive source annotations.
      if !page.images.isEmpty || page.strokes.contains(where: { $0.fillColor != nil })
        || page.texts.contains(where: { abs($0.rotation ?? 0) >= 0.0001 })
      {
        var visual = page
        visual.strokes = page.strokes.filter { $0.fillColor != nil }
        visual.texts = page.texts.filter { abs($0.rotation ?? 0) >= 0.0001 }
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
    func remap(_ destination: PDFDestination?, source: PDFDocument, name: String) -> PDFDestination?
    {
      guard let destination, let page = destination.page,
        let index = pageMap[name]?[source.index(for: page)], let target = result.page(at: index)
      else { return nil }
      let updated = PDFDestination(page: target, at: destination.point)
      updated.zoom = destination.zoom
      return updated
    }
    for link in links {
      guard let page = result.page(at: link.output),
        page.annotations.indices.contains(link.annotation)
      else { continue }
      let annotation = page.annotations[link.annotation]
      if let index = pageMap[link.name]?[link.target], let target = result.page(at: index) {
        let destination = PDFDestination(page: target, at: link.point)
        destination.zoom = link.zoom
        annotation.action = PDFActionGoTo(destination: destination)
      } else {
        annotation.action = nil
        annotation.destination = nil
      }
    }
    let root = PDFOutline()
    func clone(_ outline: PDFOutline, source: PDFDocument, name: String, depth: Int) -> PDFOutline?
    {
      guard depth < 64 else { return nil }
      let node = PDFOutline()
      node.label = outline.label
      for i in 0..<outline.numberOfChildren {
        if let child = outline.child(at: i),
          let copied = clone(child, source: source, name: name, depth: depth + 1)
        {
          node.insertChild(copied, at: node.numberOfChildren)
        }
      }
      if let updated = remap(outline.destination, source: source, name: name) {
        node.destination = updated
      } else if let action = outline.action as? PDFActionURL {
        node.action = action.copy() as? PDFAction
      }
      node.isOpen = outline.isOpen
      return node.destination != nil || node.action != nil || node.numberOfChildren > 0 ? node : nil
    }
    var seen: Set<String> = []
    for page in package.notebook.pages {
      guard let name = page.backgroundPDF, seen.insert(name).inserted,
        let source = originals[name], let outline = source.outlineRoot
      else { continue }
      for i in 0..<outline.numberOfChildren {
        if let child = outline.child(at: i),
          let copied = clone(child, source: source, name: name, depth: 0)
        {
          root.insertChild(copied, at: root.numberOfChildren)
        }
      }
    }
    if root.numberOfChildren > 0 { result.outlineRoot = root }
    guard let data = result.dataRepresentation() else { throw PackageError.invalidPackage }
    return data
  }
}

private enum PDFOpenError: LocalizedError {
  case wrongPassword
  var errorDescription: String? { "The password is incorrect. Try again." }
}
