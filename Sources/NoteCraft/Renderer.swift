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

// NSCache is documented as thread safe; it is just not marked Sendable.
private final class DecodedImages: @unchecked Sendable {
  private let cache: NSCache<NSString, CGImage> = {
    let cache = NSCache<NSString, CGImage>()
    cache.totalCostLimit = 256 << 20
    return cache
  }()
  func image(for key: NSString) -> CGImage? { cache.object(forKey: key) }
  func store(_ image: CGImage, for key: NSString) {
    cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
  }
}

@MainActor enum PageRenderer {
  nonisolated static func color(_ ink: InkColor, alpha: Double = 1) -> CGColor {
    CGColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: alpha)
  }
  private static var pdfCache: [(Data, PDFDocument)] = []
  // The page cache asks for the background PDF on every rebuild; comparing a 50 MB document
  // byte by byte each time is wasted work when it is the very same buffer.
  private static func sameBytes(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    if a.isEmpty { return true }
    return a.withUnsafeBytes { x in
      b.withUnsafeBytes { y in
        x.baseAddress == y.baseAddress || memcmp(x.baseAddress!, y.baseAddress!, x.count) == 0
      }
    }
  }
  private static func document(_ data: Data) -> PDFDocument? {
    if let cached = pdfCache.first(where: { sameBytes($0.0, data) }) { return cached.1 }
    guard let document = PDFDocument(data: data) else { return nil }
    pdfCache.append((data, document))
    if pdfCache.count > 3 { pdfCache.removeFirst() }
    return document
  }
  static func render(
    _ page: Page, assets: [String: Data], in c: CGContext, includePDFAnnotations: Bool = true,
    includeBackground: Bool = true, paperBounds: CGRect? = nil, cull: CGRect? = nil
  ) {
    let pdf =
      includeBackground
      ? page.backgroundPDF.flatMap { assets[$0] }.flatMap { document($0) } : nil
    renderContent(
      page, assets: assets, in: c, backgroundDocument: pdf,
      includePDFAnnotations: includePDFAnnotations, includeBackground: includeBackground,
      paperBounds: paperBounds, cull: cull)
  }
  // Decoding a photo costs tens of milliseconds and the page cache is rebuilt on every undo,
  // zoom and page change, so decoded bitmaps are kept (bounded, and dropped under memory
  // pressure by NSCache). Anything larger than 4096 px is decoded downsampled: that is still
  // several times the resolution a page shows or a PDF export needs.
  private nonisolated static let decodedImages = DecodedImages()
  nonisolated static func decodedImage(_ name: String, _ data: Data) -> CGImage? {
    // The bytes' address and size plus a sample of their content identify the image without
    // hashing megabytes on every render.
    var hasher = Hasher()
    data.withUnsafeBytes { raw in
      hasher.combine(raw.baseAddress.map { Int(bitPattern: $0) })
      hasher.combine(raw.count)
    }
    hasher.combine(data.prefix(256))
    hasher.combine(data.suffix(256))
    let key = "\(name)|\(hasher.finalize())" as NSString
    if let cached = decodedImages.image(for: key) { return cached }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
    let image: CGImage?
    if max(width, height) > 4096 {
      image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 4096,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    } else {
      image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    if let image { decodedImages.store(image, for: key) }
    return image
  }
  nonisolated static func renderContent(
    _ page: Page, assets: [String: Data], in c: CGContext, backgroundDocument: PDFDocument?,
    includePDFAnnotations: Bool = true, includeBackground: Bool = true,
    paperBounds: CGRect? = nil, cull: CGRect? = nil
  ) {
    if includeBackground {
      let size = page.dimensions
      c.setFillColor(page.paper.color.map { color($0) } ?? CGColor(gray: 1, alpha: 1))
      // A whiteboard has no edge, so its sheet color fills the whole visible area.
      c.fill(paperBounds ?? CGRect(x: 0, y: 0, width: size.x, height: size.y))
      if let pdf = backgroundDocument, let p = pdf.page(at: page.backgroundPage ?? 0),
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
      if let cull, !cull.intersects(CGRect(x: image.frame.x - image.frame.width, y: image.frame.y - image.frame.height, width: image.frame.width * 3, height: image.frame.height * 3)) { continue }
      guard let data = assets[image.filename], let bitmap = decodedImage(image.filename, data)
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
    // Pencil strokes that follow each other are drawn together; anything else in between has to
    // land on top of them, so it ends the run.
    var pencilRun: [Stroke] = []
    for s in page.strokes.filter({ $0.tool == .highlighter })
      + page.strokes.filter({ $0.tool != .highlighter })
    {
      if let cull {
        let b = s.bounds
        let pad = s.width * 2 + 2
        guard cull.intersects(CGRect(x: b.x - pad, y: b.y - pad, width: b.width + 2 * pad, height: b.height + 2 * pad)) else { continue }
      }
      if s.isPencil {
        pencilRun.append(s)
        continue
      }
      if !pencilRun.isEmpty {
        pencilStrokes(pencilRun, in: c)
        pencilRun = []
      }
      stroke(s, in: c)
    }
    if !pencilRun.isEmpty { pencilStrokes(pencilRun, in: c) }
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

  nonisolated static func paper(_ paper: Paper, in c: CGContext, bounds: CGRect? = nil) {
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
  nonisolated static func stroke(_ s: Stroke, in c: CGContext) {
    guard let first = s.samples.first else { return }
    if s.isPencil {
      pencilStrokes([s], in: c)
      return
    }
    c.saveGState()
    c.setLineCap(.round)
    c.setLineJoin(.round)
    if let fill = s.fillColor, s.samples.count > 2 {
      c.setFillColor(color(fill, alpha: s.fillOpacity ?? 0.2))
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
      if s.tool == .shapes, s.samples.count > 1 {
        // Geometric outlines are one path so joins and caps stay clean and the cost is one stroke.
        c.setLineWidth(s.width)
        c.addLines(between: s.samples.map { CGPoint(x: $0.point.x, y: $0.point.y) })
        c.strokePath()
        c.restoreGState()
        return
      }
      if s.tool == .pen, s.style == .fountain, s.samples.count > 1,
        !s.samples.allSatisfy({ $0.point == first.point })
      {
        let widths = FountainInk.widths(
          for: s.samples, base: s.width, tip: s.tip ?? .standard, finished: true)
        fountainSegments(s.samples, widths: widths, range: 1..<s.samples.count, in: c, finish: true)
        c.restoreGState()
        return
      }
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
  // Fountain ink is a strip of quads along each smoothed midpoint segment. Adjacent segments share
  // position, tangent and width at their joins, so the strips meet without gaps; only the ends of a
  // range get a round cap. One fill per range keeps the cost near a plain stroke (disc stamping was
  // about ten times slower) and a segment still depends only on the samples around it, so
  // incremental live drawing matches a full redraw.
  nonisolated static func fountainSegments(
    _ samples: [Sample], widths: [Double], range: Range<Int>, in c: CGContext,
    finish: Bool = false
  ) {
    guard let path = ribbonPath(samples, widths: widths, range: range, finish: finish) else {
      return
    }
    c.addPath(path)
    c.fillPath()
  }
  nonisolated static func ribbonPath(
    _ samples: [Sample], widths: [Double], range: Range<Int>, finish: Bool = false
  ) -> CGPath? {
    guard samples.count > 1, widths.count == samples.count else { return nil }
    let path = CGMutablePath()
    var previousNormal = CGPoint(x: 0, y: 1)
    var rangeStart: (CGPoint, Double)?
    var rangeEnd: (CGPoint, Double)?
    for i in range where i > 0 && i < samples.count {
      let a = samples[i - 1].point
      let b = samples[i].point
      let isLast = finish && i == samples.count - 1
      let start =
        i == 1 ? a : Point((samples[i - 2].point.x + a.x) / 2, (samples[i - 2].point.y + a.y) / 2)
      let end = isLast ? b : Point((a.x + b.x) / 2, (a.y + b.y) / 2)
      let startWidth = i == 1 ? widths[0] : (widths[i - 2] + widths[i - 1]) / 2
      let endWidth = isLast ? widths[i] : (widths[i - 1] + widths[i]) / 2
      let length = start.distance(to: a) + a.distance(to: end)
      let steps = min(24, max(1, Int((length / 3).rounded(.up))))
      if rangeStart == nil { rangeStart = (CGPoint(x: start.x, y: start.y), startWidth) }
      rangeEnd = (CGPoint(x: end.x, y: end.y), endWidth)
      var last: (left: CGPoint, right: CGPoint)?
      for step in 0...steps {
        let t = Double(step) / Double(steps)
        let u = 1 - t
        let x = u * u * start.x + 2 * u * t * a.x + t * t * end.x
        let y = u * u * start.y + 2 * u * t * a.y + t * t * end.y
        var dx = 2 * u * (a.x - start.x) + 2 * t * (end.x - a.x)
        var dy = 2 * u * (a.y - start.y) + 2 * t * (end.y - a.y)
        let norm = hypot(dx, dy)
        if norm > 0.0001 {
          dx /= norm
          dy /= norm
          previousNormal = CGPoint(x: -dy, y: dx)
        }
        let half = (startWidth + (endWidth - startWidth) * t) / 2
        let left = CGPoint(x: x + previousNormal.x * half, y: y + previousNormal.y * half)
        let right = CGPoint(x: x - previousNormal.x * half, y: y - previousNormal.y * half)
        if let last {
          path.move(to: last.left)
          path.addLine(to: left)
          path.addLine(to: right)
          path.addLine(to: last.right)
          path.closeSubpath()
        }
        last = (left, right)
      }
    }
    // The quads run clockwise and CoreGraphics ellipses counter-clockwise; where a cap overlaps the
    // ribbon the two would cancel under the nonzero rule and leave a bite out of both ends. Mirroring
    // the ellipse turns it the same way as the quads.
    for cap in [rangeStart, rangeEnd] {
      guard let (center, width) = cap else { continue }
      let radius = width / 2
      path.addEllipse(
        in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
        transform: CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: 1, y: -1))
    }
    return path
  }
  // Pencil ink. The ribbons are filled as plain colour inside a transparency layer, and the paper
  // grain is multiplied in once over everything in it, which costs a tile blit per run instead of a
  // pattern fill per stroke (about 15 times slower on a page of handwriting). The grain is laid out
  // from the page origin, so it does not move with a stroke or a zoom level.
  private final class GrainImage: @unchecked Sendable {
    let image: CGImage
    init() {
      let size = PencilGrain.size
      // The page is y down, so the tile's top row has to end up at the top of the page; CoreGraphics
      // draws an image's first row at the top of a y-up space.
      var rows: [UInt8] = []
      rows.reserveCapacity(size * size * 4)
      for row in (0..<size).reversed() {
        for column in 0..<size {
          let value = PencilGrain.alpha[row * size + column]
          rows += [value, value, value, value]
        }
      }
      image = CGImage(
        width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(rows) as CFData)!, decode: nil,
        shouldInterpolate: false, intent: .defaultIntent)!
    }
  }
  private nonisolated static let grain = GrainImage()
  // How much of the colour a pencil line lays down before the grain takes its share.
  nonisolated static let pencilOpacity = 0.9

  nonisolated static func pencilRibbon(_ s: Stroke) -> CGPath? {
    guard let first = s.samples.first else { return nil }
    let widths = WidthModel.pencil.widths(for: s.samples, base: s.width, finished: true)
    if let path = ribbonPath(
      s.samples, widths: widths, range: 1..<max(1, s.samples.count), finish: true),
      !s.samples.allSatisfy({ $0.point == first.point })
    {
      return path
    }
    let radius = (widths.first ?? s.width) / 2
    return CGPath(
      ellipseIn: CGRect(
        x: first.point.x - radius, y: first.point.y - radius, width: radius * 2, height: radius * 2),
      transform: nil)
  }
  nonisolated static func pencilLayer(_ ribbons: [(path: CGPath, color: CGColor)], in c: CGContext)
  {
    var box = CGRect.null
    for ribbon in ribbons { box = box.union(ribbon.path.boundingBoxOfPath) }
    // A line reaches half its width past the path's box; the grain tile is anchored to the page, so
    // limiting the layer to what is visible does not move it.
    box = box.insetBy(dx: -2, dy: -2).intersection(c.boundingBoxOfClipPath)
    guard !box.isNull, box.width > 0, box.height > 0 else { return }
    c.saveGState()
    c.clip(to: box)
    c.beginTransparencyLayer(in: box, auxiliaryInfo: nil)
    for ribbon in ribbons {
      c.setFillColor(ribbon.color)
      c.addPath(ribbon.path)
      c.fillPath()
    }
    c.setBlendMode(.destinationIn)
    c.interpolationQuality = .none
    c.draw(
      grain.image, in: CGRect(x: 0, y: 0, width: PencilGrain.cell, height: PencilGrain.cell),
      byTiling: true)
    c.endTransparencyLayer()
    c.restoreGState()
  }
  nonisolated static func pencilStrokes(_ strokes: [Stroke], in c: CGContext) {
    pencilLayer(
      strokes.compactMap { s in
        pencilRibbon(s).map { ($0, color(s.color, alpha: pencilOpacity)) }
      }, in: c)
  }
  // Midpoint segments are final once their following sample arrives. Live ink can
  // rasterize that prefix once and redraw only the provisional/predicted tail.
  nonisolated static func smoothInkSegments(
    _ samples: [Sample], range: Range<Int>, color ink: InkColor, width: Double,
    style: PenStyle, in c: CGContext, finish: Bool = false, widths: [Double]? = nil
  ) {
    guard samples.count > 1 else { return }
    if style == .fountain, let widths, widths.count == samples.count {
      c.saveGState()
      c.setFillColor(color(ink))
      fountainSegments(samples, widths: widths, range: range, in: c, finish: finish)
      c.restoreGState()
      return
    }
    if style == .pencil, let widths, widths.count == samples.count {
      if let path = ribbonPath(samples, widths: widths, range: range, finish: finish) {
        pencilLayer([(path, color(ink, alpha: pencilOpacity))], in: c)
      }
      return
    }
    c.saveGState()
    c.setStrokeColor(color(ink))
    c.setLineCap(.round)
    c.setLineJoin(.round)
    for i in range where i > 0 && i < samples.count {
      let a = samples[i - 1]
      let b = samples[i]
      let start =
        i == 1
        ? a.point
        : Point(
          (samples[i - 2].point.x + a.point.x) / 2,
          (samples[i - 2].point.y + a.point.y) / 2)
      let end =
        finish && i == samples.count - 1
        ? b.point
        : Point(
          (a.point.x + b.point.x) / 2, (a.point.y + b.point.y) / 2)
      let pressure = style == .ballpoint ? 1 : max(0.2, (a.pressure + b.pressure) / 2)
      let tilt = style == .brush ? 1 + (1 - sin((a.altitude + b.altitude) / 2)) : 1
      c.setLineWidth(width * pressure * tilt * (style == .brush ? 1.7 : 1))
      c.move(to: CGPoint(x: start.x, y: start.y))
      c.addQuadCurve(to: CGPoint(x: end.x, y: end.y), control: CGPoint(x: a.point.x, y: a.point.y))
      c.strokePath()
    }
    c.restoreGState()
  }
  nonisolated static func export(_ package: NotebookPackage, includePDFAnnotations: Bool = true)
    throws -> Data
  {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data),
      let c = CGContext(consumer: consumer, mediaBox: nil, nil)
    else { throw PackageError.invalidPackage }
    var documents: [String: PDFDocument] = [:]
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
      if let name = page.backgroundPDF, documents[name] == nil, let bytes = package.assets[name] {
        documents[name] = PDFDocument(data: bytes)
      }
      renderContent(
        page, assets: package.assets, in: c,
        backgroundDocument: page.backgroundPDF.flatMap { documents[$0] },
        includePDFAnnotations: includePDFAnnotations,
        paperBounds: package.notebook.kind == .whiteboard
          ? CGRect(x: area.x, y: area.y, width: area.width, height: area.height) : nil)
      c.restoreGState()
      c.endPDFPage()
    }
    c.closePDF()
    return data as Data
  }
  nonisolated static func contentBounds(_ page: Page) -> Rect {
    let rectangles =
      page.strokes.map(\.bounds) + page.images.map(\.bounds) + page.texts.map(\.bounds)
    guard !rectangles.isEmpty else { return Rect(x: 0, y: 0, width: 800, height: 600) }
    let x = (rectangles.map(\.x).min() ?? 0) - 40
    let y = (rectangles.map(\.y).min() ?? 0) - 40
    return Rect(
      x: x, y: y, width: max(100, (rectangles.map { $0.x + $0.width }.max() ?? 0) - x + 40),
      height: max(100, (rectangles.map { $0.y + $0.height }.max() ?? 0) - y + 40))
  }
  nonisolated static func thumbnail(_ package: NotebookPackage) throws -> Data {
    guard let page = package.notebook.pages.first else { throw PackageError.invalidPackage }
    let area =
      package.notebook.kind == .whiteboard
      ? contentBounds(page) : Rect(x: 0, y: 0, width: page.dimensions.x, height: page.dimensions.y)
    let scale = 240 / max(area.width, area.height)
    return try bitmap(
      page, assets: package.assets, bounds: area, width: max(1, Int(area.width * scale)),
      height: max(1, Int(area.height * scale)), infinitePaper: package.notebook.kind == .whiteboard)
  }
  nonisolated static func screenshot(_ page: Page, assets: [String: Data], bounds: Rect) throws
    -> Data
  {
    let width = min(4096, max(1, Int(bounds.width * 2)))
    let height = min(4096, max(1, Int(bounds.height * 2)))
    return try bitmap(page, assets: assets, bounds: bounds, width: width, height: height)
  }
  private nonisolated static func bitmap(
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
    renderContent(
      page, assets: assets, in: c,
      backgroundDocument: page.backgroundPDF.flatMap { assets[$0] }.flatMap {
        PDFDocument(data: $0)
      },
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
  nonisolated static func importPDF(_ data: Data) throws -> [Page] {
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

// PDFKit objects and graphics contexts stay on this worker; only bytes cross to the UI.
// A finished bitmap crossing from a render thread to the main actor. CGImage is immutable.
struct RenderedPage: @unchecked Sendable {
  let image: CGImage
}

// Rebuilds a page's cached bitmap off the main thread: a page of handwriting takes 30 to 100 ms
// and a PDF background more, which would drop frames every time a page appears, is undone or
// is zoomed. One at a time, because PDFKit documents must not be drawn from two threads.
actor PageCacheWorker {
  static let shared = PageCacheWorker()
  private var pdfs: [(Data, PDFDocument)] = []

  func render(
    _ page: Page, assets: [String: Data], rect: CGRect, resolution: Double, infinitePaper: Bool
  ) -> RenderedPage? {
    autoreleasepool {
      guard !Task.isCancelled else { return nil }
      let width = Int((rect.width * resolution).rounded(.up))
      let height = Int((rect.height * resolution).rounded(.up))
      guard width > 0, height > 0, width <= 16384, height <= 16384,
        let c = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
      else { return nil }
      // Page space is y-down; the first bitmap row is the top of the page.
      c.translateBy(x: 0, y: Double(height))
      c.scaleBy(x: resolution, y: -resolution)
      c.translateBy(x: -rect.minX, y: -rect.minY)
      PageRenderer.renderContent(
        page, assets: assets, in: c,
        backgroundDocument: page.backgroundPDF.flatMap { assets[$0] }.flatMap { document($0) },
        paperBounds: infinitePaper ? rect : nil)
      return c.makeImage().map(RenderedPage.init)
    }
  }

  private func document(_ data: Data) -> PDFDocument? {
    if let cached = pdfs.first(where: { $0.0.count == data.count && $0.0 == data }) {
      return cached.1
    }
    guard let document = PDFDocument(data: data) else { return nil }
    pdfs.append((data, document))
    if pdfs.count > 2 { pdfs.removeFirst() }
    return document
  }
}

actor DocumentRenderWorker {
  static let shared = DocumentRenderWorker()
  private let files = VaultFiles()
  private let packages = PackageStore()
  private var covers: [String: (Date, Data)] = [:]
  private var coverOrder: [String] = []

  func exportPDF(_ package: NotebookPackage) throws -> Data {
    try autoreleasepool { try PDFEditor.export(package) }
  }

  func cover(_ entry: VaultEntry) async throws -> Data? {
    let key = entry.url.vaultPath
    if let cached = covers[key], cached.0 == entry.modified { return cached.1 }
    try Task.checkCancellation()
    let data: Data
    if entry.kind == .whiteboard {
      let package = try await packages.read(from: entry.url)
      try Task.checkCancellation()
      data = try autoreleasepool { try PageRenderer.thumbnail(package) }
    } else {
      let snapshot = try await files.read(entry.url)
      try Task.checkCancellation()
      data = try autoreleasepool {
        if entry.kind == .image {
          guard let source = CGImageSourceCreateWithData(snapshot.data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
              source, 0,
              [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 600,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
          else { throw PackageError.invalidPackage }
          let result = NSMutableData()
          guard
            let destination = CGImageDestinationCreateWithData(
              result, "public.png" as CFString, 1, nil)
          else { throw PackageError.invalidPackage }
          CGImageDestinationAddImage(destination, image, nil)
          guard CGImageDestinationFinalize(destination) else { throw PackageError.invalidPackage }
          return result as Data
        }
        guard let pdf = PDFDocument(data: snapshot.data), let source = pdf.page(at: 0) else {
          throw PackageError.invalidPackage
        }
        let bounds = source.bounds(for: .mediaBox)
        let rotated = abs(source.rotation) % 180 == 90
        var page = Page(paper: Paper(pattern: .blank))
        page.backgroundPDF = "cover.pdf"
        page.backgroundPage = 0
        page.backgroundSize =
          rotated ? Point(bounds.height, bounds.width) : Point(bounds.width, bounds.height)
        return try PageRenderer.thumbnail(
          NotebookPackage(
            notebook: Notebook(pages: [page]), assets: ["cover.pdf": snapshot.data]))
      }
    }
    try Task.checkCancellation()
    covers[key] = (entry.modified, data)
    coverOrder.removeAll { $0 == key }
    coverOrder.append(key)
    while coverOrder.count > 32 { covers.removeValue(forKey: coverOrder.removeFirst()) }
    return data
  }
}
