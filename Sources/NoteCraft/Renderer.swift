import NoteCraftCore
import PDFKit
import SwiftUI

#if os(macOS)
  import AppKit
  typealias PlatformImage = NSImage
#else
  import UIKit
  typealias PlatformImage = UIImage
#endif

@MainActor enum PageRenderer {
  static func color(_ ink: InkColor, alpha: Double = 1) -> CGColor {
    CGColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: alpha)
  }
  private static var pdfCache: [(Data, PDFDocument)] = []
  private static func document(_ data: Data) -> PDFDocument? {
    if let cached = pdfCache.first(where: { $0.0 == data }) { return cached.1 }
    guard let document = PDFDocument(data: data) else { return nil }
    pdfCache.append((data, document))
    if pdfCache.count > 3 { pdfCache.removeFirst() }
    return document
  }
  static func render(
    _ page: Page, assets: [String: Data], in c: CGContext, includePDFAnnotations: Bool = true,
    includeBackground: Bool = true, paperBounds: CGRect? = nil
  ) {
    if includeBackground {
      let size = page.dimensions
      c.setFillColor(CGColor(gray: 1, alpha: 1))
      c.fill(CGRect(x: 0, y: 0, width: size.x, height: size.y))
      if let name = page.backgroundPDF, let data = assets[name],
        let pdf = document(data), let p = pdf.page(at: page.backgroundPage ?? 0),
        let reference = p.pageRef
      {
        c.saveGState()
        c.translateBy(x: 0, y: size.y)
        c.scaleBy(x: 1, y: -1)
        c.concatenate(
          reference.getDrawingTransform(
            .mediaBox, rect: CGRect(x: 0, y: 0, width: size.x, height: size.y), rotate: 0,
            preserveAspectRatio: true))
        if includePDFAnnotations {
          p.draw(with: .mediaBox, to: c)
        } else {
          c.drawPDFPage(reference)
        }
        c.restoreGState()
      } else {
        paper(page.paper, in: c, bounds: paperBounds)
      }
    }
    for image in page.images {
      guard let data = assets[image.filename],
        let source = CGImageSourceCreateWithData(data as CFData, nil),
        let bitmap = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { continue }
      let r = image.frame
      c.saveGState()
      c.translateBy(x: r.x + r.width / 2, y: r.y + r.height / 2)
      c.rotate(by: image.rotation)
      c.scaleBy(x: 1, y: -1)
      c.draw(
        bitmap, in: CGRect(x: -r.width / 2, y: -r.height / 2, width: r.width, height: r.height))
      c.restoreGState()
    }
    for s in page.strokes.filter({ $0.tool == .highlighter })
      + page.strokes.filter({ $0.tool != .highlighter })
    { stroke(s, in: c) }
    for text in page.texts {
      let r = text.layoutBounds
      c.saveGState()
      c.translateBy(x: r.x + r.width / 2, y: r.y + r.height / 2)
      c.rotate(by: text.rotation ?? 0)
      c.translateBy(x: -r.x - r.width / 2, y: -r.y - r.height / 2)
      let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
      if let background = text.background {
        c.setFillColor(color(background, alpha: 0.2))
        c.fill(rect)
      }
      if text.border == true {
        c.setStrokeColor(color(text.color))
        c.setLineWidth(0.7)
        c.stroke(rect.insetBy(dx: -4, dy: -4))
      }
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment =
        text.alignment == "center" ? .center : text.alignment == "right" ? .right : .left
      #if os(macOS)
        let font =
          text.fontName.flatMap { NSFont(name: $0, size: text.size) }
          ?? NSFont.systemFont(ofSize: text.size)
        let attributes: [NSAttributedString.Key: Any] = [
          .font: font, .foregroundColor: NSColor(cgColor: color(text.color)) ?? .black,
          .paragraphStyle: paragraph,
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        (text.text as NSString).draw(in: rect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
      #else
        let font =
          text.fontName.flatMap { UIFont(name: $0, size: text.size) }
          ?? UIFont.systemFont(ofSize: text.size)
        UIGraphicsPushContext(c)
        (text.text as NSString).draw(
          in: rect,
          withAttributes: [
            .font: font, .foregroundColor: UIColor(cgColor: color(text.color)),
            .paragraphStyle: paragraph,
          ])
        UIGraphicsPopContext()
      #endif
      c.restoreGState()
    }
  }

  static func paper(_ paper: Paper, in c: CGContext, bounds: CGRect? = nil) {
    let size = paper.dimensions
    c.setStrokeColor(CGColor(red: 0.79, green: 0.83, blue: 0.88, alpha: 0.65))
    c.setLineWidth(0.5)
    if paper.pattern == .graph || paper.pattern == .fineGraph
      || (bounds != nil && paper.pattern != .planner)
    {
      let area = bounds ?? CGRect(x: 24, y: 28, width: size.x - 48, height: size.y - 48)
      c.saveGState()
      c.clip(to: area)
      defer { c.restoreGState() }
      let spacing: Double =
        paper.pattern == .fineGraph
        ? 72 / 25.4 * 2.5
        : paper.pattern == .graph ? 72 / 25.4 * 5 : paper.pattern == .dotted ? 20 : 24
      let startX = floor(area.minX / spacing) * spacing
      let startY = floor(area.minY / spacing) * spacing
      if paper.pattern == .dotted {
        c.setFillColor(CGColor(gray: 0.7, alpha: 0.65))
        for y in stride(from: startY, through: area.maxY, by: spacing) {
          for x in stride(from: startX, through: area.maxX, by: spacing) {
            c.fillEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
          }
        }
      } else if paper.pattern != .blank {
        for y in stride(from: startY, through: area.maxY, by: spacing) {
          c.move(to: CGPoint(x: area.minX, y: y))
          c.addLine(to: CGPoint(x: area.maxX, y: y))
        }
        if paper.pattern != .ruled {
          for x in stride(from: startX, through: area.maxX, by: spacing) {
            c.move(to: CGPoint(x: x, y: area.minY))
            c.addLine(to: CGPoint(x: x, y: area.maxY))
          }
        }
        c.strokePath()
      }
      return
    }
    switch paper.pattern {
    case .blank, .graph, .fineGraph: break
    case .ruled, .squared:
      for y in stride(from: 52.0, to: size.y - 20, by: 24) {
        c.move(to: CGPoint(x: 24, y: y))
        c.addLine(to: CGPoint(x: size.x - 24, y: y))
      }
      if paper.pattern == .squared {
        for x in stride(from: 24.0, to: size.x - 20, by: 24) {
          c.move(to: CGPoint(x: x, y: 28))
          c.addLine(to: CGPoint(x: x, y: size.y - 20))
        }
      }
      c.strokePath()
    case .dotted:
      c.setFillColor(CGColor(gray: 0.7, alpha: 0.65))
      for y in stride(from: 28.0, to: size.y - 20, by: 20) {
        for x in stride(from: 24.0, to: size.x - 20, by: 20) {
          c.fillEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
        }
      }
    case .planner:
      for i in 0..<7 {
        c.stroke(
          CGRect(
            x: 28, y: 60 + Double(i) * (size.y - 88) / 7, width: size.x - 56,
            height: (size.y - 88) / 7))
      }
    }
  }
  static func stroke(_ s: Stroke, in c: CGContext) {
    guard let first = s.samples.first else { return }
    c.saveGState()
    c.setLineCap(.round)
    c.setLineJoin(.round)
    if let fill = s.fillColor, s.samples.count > 2 {
      c.setFillColor(color(fill, alpha: 0.2))
      c.addLines(between: s.samples.map { CGPoint(x: $0.point.x, y: $0.point.y) })
      c.closePath()
      c.fillPath()
    }
    let alpha = s.tool == .highlighter ? 0.3 : 1.0
    if s.tool == .highlighter {
      c.setAlpha(alpha)
      c.beginTransparencyLayer(auxiliaryInfo: nil)
      c.setStrokeColor(color(s.color))
      c.setLineWidth(s.width)
      c.move(to: CGPoint(x: first.point.x, y: first.point.y))
      for sample in s.samples.dropFirst() {
        c.addLine(to: CGPoint(x: sample.point.x, y: sample.point.y))
      }
      c.strokePath()
      c.endTransparencyLayer()
    } else {
      c.setStrokeColor(color(s.color))
      c.setFillColor(color(s.color))
      if s.samples.allSatisfy({ $0.point == first.point }) {
        c.fillEllipse(
          in: CGRect(
            x: first.point.x - s.width / 2, y: first.point.y - s.width / 2, width: s.width,
            height: s.width))
      }
      let smooth = s.tool == .pen && s.samples.count > 5
      if smooth && s.style == .ballpoint {
        c.setLineWidth(s.width)
        c.move(to: CGPoint(x: first.point.x, y: first.point.y))
        for i in 1..<s.samples.count {
          let control = s.samples[i - 1].point
          let point = s.samples[i].point
          let end =
            i == s.samples.count - 1
            ? point
            : Point((control.x + point.x) / 2, (control.y + point.y) / 2)
          c.addQuadCurve(
            to: CGPoint(x: end.x, y: end.y),
            control: CGPoint(x: control.x, y: control.y))
        }
        c.strokePath()
      } else {
        var start = first.point
        for i in 1..<s.samples.count {
          let a = s.samples[i - 1]
          let b = s.samples[i]
          let pressure = s.style == .ballpoint ? 1 : max(0.2, (a.pressure + b.pressure) / 2)
          let tilt = s.style == .brush ? 1 + (1 - sin((a.altitude + b.altitude) / 2)) : 1
          c.setLineWidth(s.width * pressure * tilt * (s.style == .brush ? 1.7 : 1))
          c.move(to: CGPoint(x: start.x, y: start.y))
          let end =
            smooth && i < s.samples.count - 1
            ? Point((a.point.x + b.point.x) / 2, (a.point.y + b.point.y) / 2) : b.point
          if smooth {
            c.addQuadCurve(
              to: CGPoint(x: end.x, y: end.y),
              control: CGPoint(x: a.point.x, y: a.point.y))
          } else {
            c.addLine(to: CGPoint(x: end.x, y: end.y))
          }
          c.strokePath()
          start = end
        }
      }
    }
    c.restoreGState()
  }
  static func export(_ package: NotebookPackage, includePDFAnnotations: Bool = true) throws -> Data
  {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data),
      let c = CGContext(consumer: consumer, mediaBox: nil, nil)
    else { throw PackageError.invalidPackage }
    for page in package.notebook.pages {
      let area =
        package.notebook.kind == .whiteboard
        ? contentBounds(page)
        : Rect(x: 0, y: 0, width: page.dimensions.x, height: page.dimensions.y)
      let size = Point(area.width, area.height)
      var mediaBox = CGRect(x: 0, y: 0, width: size.x, height: size.y)
      let boxData = withUnsafeBytes(of: &mediaBox) { Data($0) }
      c.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
      c.setFillColor(CGColor(gray: 1, alpha: 1))
      c.fill(mediaBox)
      c.saveGState()
      c.translateBy(x: 0, y: size.y)
      c.scaleBy(x: 1, y: -1)
      c.translateBy(x: -area.x, y: -area.y)
      render(
        page, assets: package.assets, in: c, includePDFAnnotations: includePDFAnnotations,
        paperBounds: package.notebook.kind == .whiteboard
          ? CGRect(x: area.x, y: area.y, width: area.width, height: area.height) : nil)
      c.restoreGState()
      c.endPDFPage()
    }
    c.closePDF()
    return data as Data
  }
  static func contentBounds(_ page: Page) -> Rect {
    let rectangles =
      page.strokes.map(\.bounds) + page.images.map(\.bounds) + page.texts.map(\.bounds)
    guard !rectangles.isEmpty else { return Rect(x: 0, y: 0, width: 800, height: 600) }
    let x = (rectangles.map(\.x).min() ?? 0) - 40
    let y = (rectangles.map(\.y).min() ?? 0) - 40
    return Rect(
      x: x, y: y, width: max(100, (rectangles.map { $0.x + $0.width }.max() ?? 0) - x + 40),
      height: max(100, (rectangles.map { $0.y + $0.height }.max() ?? 0) - y + 40))
  }
  static func thumbnail(_ package: NotebookPackage) throws -> Data {
    guard let page = package.notebook.pages.first else { throw PackageError.invalidPackage }
    let area =
      package.notebook.kind == .whiteboard
      ? contentBounds(page) : Rect(x: 0, y: 0, width: page.dimensions.x, height: page.dimensions.y)
    let scale = 240 / max(area.width, area.height)
    return try bitmap(
      page, assets: package.assets, bounds: area, width: max(1, Int(area.width * scale)),
      height: max(1, Int(area.height * scale)), infinitePaper: package.notebook.kind == .whiteboard)
  }
  static func screenshot(_ page: Page, assets: [String: Data], bounds: Rect) throws -> Data {
    let width = min(4096, max(1, Int(bounds.width * 2)))
    let height = min(4096, max(1, Int(bounds.height * 2)))
    return try bitmap(page, assets: assets, bounds: bounds, width: width, height: height)
  }
  private static func bitmap(
    _ page: Page, assets: [String: Data], bounds: Rect, width: Int, height: Int,
    infinitePaper: Bool = false
  ) throws -> Data {
    guard
      let c = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw PackageError.invalidPackage }
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: width, height: height))
    c.translateBy(x: 0, y: Double(height))
    c.scaleBy(x: Double(width) / bounds.width, y: -Double(height) / bounds.height)
    c.translateBy(x: -bounds.x, y: -bounds.y)
    render(
      page, assets: assets, in: c,
      paperBounds: infinitePaper
        ? CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height) : nil)
    let data = NSMutableData()
    guard let image = c.makeImage(),
      let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
    else { throw PackageError.invalidPackage }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw PackageError.invalidPackage }
    return data as Data
  }
  static func importPDF(_ data: Data) throws -> [Page] {
    guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
      throw PackageError.invalidPackage
    }
    return (0..<pdf.pageCount).map { index in
      var page = Page(paper: Paper(pattern: .blank))
      page.backgroundPage = index
      if let bounds = pdf.page(at: index)?.bounds(for: .mediaBox) {
        let rotated = abs(pdf.page(at: index)?.rotation ?? 0) % 180 == 90
        page.backgroundSize =
          rotated ? Point(bounds.height, bounds.width) : Point(bounds.width, bounds.height)
      }
      return page
    }
  }
}
