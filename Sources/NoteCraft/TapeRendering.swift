import CoreGraphics
import NoteCraftCore

// How a strip of tape (`Stroke.tape`) is drawn: a band along the stroke's path with ends cut like
// washi tape, a pattern that runs along the strip, and a shade along both edges. A strip that is
// peeled back is a faint tint with dashed edges, so what it hid can be read and the strip is still
// there to tap. Everything is plain fills and clips: it has to come out the same in a tile, in the
// page cache and in an exported PDF, which knows no Porter-Duff blending.
extension PageRenderer {
  nonisolated static func tape(_ s: Stroke, in c: CGContext) {
    guard let tape = s.tape, s.samples.count > 1 else { return }
    let points = s.samples.map { CGPoint(x: $0.point.x, y: $0.point.y) }
    guard let start = tapeEnd(points), let end = tapeEnd(points.reversed()) else { return }
    let width = s.width
    let centre = CGMutablePath()
    centre.addLines(between: points)
    var box = CGRect.null
    for point in points { box = box.union(CGRect(origin: point, size: .zero)) }
    box = box.insetBy(dx: -width, dy: -width)

    c.saveGState()
    defer { c.restoreGState() }
    // Everything but the notches at both ends, then the band itself: the two clips intersect.
    c.addRect(box)
    for cut in [start, end] { addNotches(at: cut.point, towards: cut.outward, width: width, to: c) }
    c.clip(using: .evenOdd)
    c.setLineCap(.butt)
    c.setLineJoin(.round)
    c.setLineWidth(width)
    c.addPath(centre)
    c.replacePathWithStrokedPath()
    c.clip()

    let sides = tapeSides(points, half: width / 2)
    if tape.revealed {
      c.setFillColor(color(s.color, alpha: 0.14))
      c.fill(box)
      c.setLineDash(phase: 0, lengths: [5, 4])
      strokeSides(sides, color: color(s.color.darkened(0.3), alpha: 0.8), in: c)
      return
    }
    c.setFillColor(color(s.color))
    c.fill(box)
    if tape.pattern != .plain {
      c.saveGState()
      // The pattern runs along the strip, from where it starts, so a strip looks the same whichever
      // way it lies on the page.
      let along = CGAffineTransform(translationX: points[0].x, y: points[0].y)
        .rotated(by: atan2(points[points.count - 1].y - points[0].y, points[points.count - 1].x - points[0].x))
      c.concatenate(along)
      let inverse = along.inverted()
      var reach = CGRect.null
      for point in points {
        reach = reach.union(CGRect(origin: point.applying(inverse), size: .zero))
      }
      // Only the part of the strip this context shows: a tile at 6x zoom sees a few points of it.
      reach = reach.insetBy(dx: -width, dy: -width).intersection(c.boundingBoxOfClipPath)
      if !reach.isNull, !reach.isEmpty { pattern(tape.pattern, over: reach, in: c) }
      c.restoreGState()
    }
    strokeSides(sides, color: color(s.color.darkened(0.3), alpha: 0.45), in: c)
  }

  // The point a strip ends at and the direction it leaves in, from its last two distinct points.
  private nonisolated static func tapeEnd(_ points: [CGPoint]) -> (point: CGPoint, outward: CGPoint)? {
    guard let tip = points.first else { return nil }
    for other in points.dropFirst() {
      let length = hypot(tip.x - other.x, tip.y - other.y)
      if length > 0.0001 {
        return (tip, CGPoint(x: (tip.x - other.x) / length, y: (tip.y - other.y) / length))
      }
    }
    return nil
  }

  // Small triangles along the end of a strip, pointing into it: what is left between them is the
  // zigzag of a strip torn off a roll.
  private nonisolated static func addNotches(
    at tip: CGPoint, towards outward: CGPoint, width: Double, to c: CGContext
  ) {
    let across = CGPoint(x: -outward.y, y: outward.x)
    let count = max(3, Int((width / 4).rounded()))
    let tooth = width / Double(count)
    let depth = min(3, tooth * 0.6)
    func point(_ offset: Double, _ back: Double) -> CGPoint {
      CGPoint(
        x: tip.x + across.x * offset - outward.x * back,
        y: tip.y + across.y * offset - outward.y * back)
    }
    for i in 0..<count {
      let from = -width / 2 + Double(i) * tooth
      // The base sits a little past the end so no sliver of the band is left along it.
      c.move(to: point(from, -0.5))
      c.addLine(to: point(from + tooth, -0.5))
      c.addLine(to: point(from + tooth / 2, depth))
      c.closePath()
    }
  }

  // The two long edges of a strip: each point of its path moved half the width to either side.
  private nonisolated static func tapeSides(_ points: [CGPoint], half: Double) -> [[CGPoint]] {
    var left: [CGPoint] = []
    var right: [CGPoint] = []
    var normal = CGPoint(x: 0, y: 1)
    for i in points.indices {
      let a = points[max(0, i - 1)]
      let b = points[min(points.count - 1, i + 1)]
      let length = hypot(b.x - a.x, b.y - a.y)
      if length > 0.0001 { normal = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length) }
      left.append(CGPoint(x: points[i].x + normal.x * half, y: points[i].y + normal.y * half))
      right.append(CGPoint(x: points[i].x - normal.x * half, y: points[i].y - normal.y * half))
    }
    return [left, right]
  }

  // The band is the clip, so half of each line falls away and the edge stays crisp.
  private nonisolated static func strokeSides(_ sides: [[CGPoint]], color: CGColor, in c: CGContext) {
    c.setStrokeColor(color)
    c.setLineWidth(1.6)
    for side in sides { c.addLines(between: side) }
    c.strokePath()
  }

  // In the strip's own axes: x along it from its start, y across it from its middle.
  private nonisolated static func pattern(_ pattern: TapePattern, over area: CGRect, in c: CGContext) {
    switch pattern {
    case .plain: break
    case .stripes:
      let step = 7.0
      c.setStrokeColor(CGColor(gray: 1, alpha: 0.42))
      c.setLineWidth(2.4)
      c.setLineCap(.butt)
      c.setLineDash(phase: 0, lengths: [])
      let from = Int(((area.minX - area.maxY) / step).rounded(.down))
      let to = Int(((area.maxX - area.minY) / step).rounded(.up))
      for k in from...max(from, to) {
        c.move(to: CGPoint(x: Double(k) * step + area.minY, y: area.minY))
        c.addLine(to: CGPoint(x: Double(k) * step + area.maxY, y: area.maxY))
      }
      c.strokePath()
    case .dots:
      let step = 8.0
      let row = step / 2
      let radius = 1.25
      c.setFillColor(CGColor(gray: 1, alpha: 0.6))
      let firstRow = Int((area.minY / row).rounded(.down))
      let lastRow = Int((area.maxY / row).rounded(.up))
      for j in firstRow...max(firstRow, lastRow) {
        // Every other row sits half a step along, like polka dots.
        let shift = j.isMultiple(of: 2) ? 0 : step / 2
        let first = Int(((area.minX - shift) / step).rounded(.down))
        let last = Int(((area.maxX - shift) / step).rounded(.up))
        for i in first...max(first, last) {
          c.addEllipse(
            in: CGRect(
              x: Double(i) * step + shift - radius, y: Double(j) * row - radius, width: radius * 2,
              height: radius * 2))
        }
      }
      c.fillPath()
    case .checks:
      // Bands along and bands across; where they cross the cloth is lighter still, as in gingham.
      let band = 5.0
      c.setFillColor(CGColor(gray: 1, alpha: 0.3))
      func bands(from low: Double, to high: Double, _ rect: (Double) -> CGRect) {
        let first = Int(((low + band / 2) / (2 * band)).rounded(.down))
        let last = Int(((high + band / 2) / (2 * band)).rounded(.up))
        for k in first...max(first, last) { c.addRect(rect(Double(k) * 2 * band - band / 2)) }
        c.fillPath()
      }
      bands(from: area.minY, to: area.maxY) {
        CGRect(x: area.minX, y: $0, width: area.width, height: band)
      }
      bands(from: area.minX, to: area.maxX) {
        CGRect(x: $0, y: area.minY, width: band, height: area.height)
      }
    }
  }
}
