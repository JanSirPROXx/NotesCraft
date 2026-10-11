import Foundation

public struct SpatialIndex: Sendable {
  private indirect enum Node: Sendable {
    case leaf(Rect, [Stroke])
    case branch(Rect, [Stroke], [Node])
    var bounds: Rect {
      switch self {
      case .leaf(let r, _), .branch(let r, _, _): r
      }
    }
    func query(_ area: Rect) -> [Stroke] {
      guard bounds.intersects(area) else { return [] }
      switch self {
      case .leaf(_, let strokes): return strokes.filter { $0.bounds.intersects(area) }
      case .branch(_, let strokes, let children):
        return strokes.filter { $0.bounds.intersects(area) } + children.flatMap { $0.query(area) }
      }
    }
  }
  private let root: Node
  public init(strokes: [Stroke], bounds: Rect) { root = Self.build(strokes, bounds, depth: 0) }
  private static func build(_ strokes: [Stroke], _ r: Rect, depth: Int) -> Node {
    guard strokes.count > 12, depth < 8 else { return .leaf(r, strokes) }
    let w = r.width / 2
    let h = r.height / 2
    let regions = [
      Rect(x: r.x, y: r.y, width: w, height: h), Rect(x: r.x + w, y: r.y, width: w, height: h),
      Rect(x: r.x, y: r.y + h, width: w, height: h),
      Rect(x: r.x + w, y: r.y + h, width: w, height: h),
    ]
    var buckets = [[Stroke]](repeating: [], count: 4)
    var shared: [Stroke] = []
    for stroke in strokes {
      let b = stroke.bounds
      if let i = regions.firstIndex(where: {
        $0.contains(Point(b.x, b.y)) && $0.contains(Point(b.x + b.width, b.y + b.height))
      }) {
        buckets[i].append(stroke)
      } else {
        shared.append(stroke)
      }
    }
    return .branch(
      r, shared,
      regions.enumerated().map { build(buckets[$0.offset], $0.element, depth: depth + 1) })
  }
  public func query(_ area: Rect) -> [Stroke] { root.query(area) }
}
public enum Editing {
  public static func distance(_ point: Point, toSegmentFrom a: Point, to b: Point) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let length = dx * dx + dy * dy
    guard length > 0 else { return point.distance(to: a) }
    let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
    return point.distance(to: Point(a.x + t * dx, a.y + t * dy))
  }
  public static func segmentsIntersect(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
    func cross(_ p: Point, _ q: Point, _ r: Point) -> Double {
      (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
    }
    let abC = cross(a, b, c)
    let abD = cross(a, b, d)
    let cdA = cross(c, d, a)
    let cdB = cross(c, d, b)
    if abC * abD < 0 && cdA * cdB < 0 { return true }
    return (abs(abC) < 1e-9 && distance(c, toSegmentFrom: a, to: b) < 1e-9)
      || (abs(abD) < 1e-9 && distance(d, toSegmentFrom: a, to: b) < 1e-9)
      || (abs(cdA) < 1e-9 && distance(a, toSegmentFrom: c, to: d) < 1e-9)
      || (abs(cdB) < 1e-9 && distance(b, toSegmentFrom: c, to: d) < 1e-9)
  }
  public static func strokeIntersects(_ stroke: Stroke, polygon: [Point]) -> Bool {
    guard polygon.count >= 3 else { return false }
    if stroke.samples.contains(where: { contains($0.point, polygon: polygon) }) { return true }
    let edges = zip(polygon, Array(polygon.dropFirst()) + [polygon[0]])
    return zip(stroke.samples, stroke.samples.dropFirst()).contains { a, b in
      edges.contains { segmentsIntersect(a.point, b.point, $0.0, $0.1) }
    }
  }
  public static func contains(_ point: Point, polygon: [Point]) -> Bool {
    guard polygon.count >= 3 else { return false }
    var inside = false
    var j = polygon.count - 1
    for i in polygon.indices {
      let a = polygon[i]
      let b = polygon[j]
      if (a.y > point.y) != (b.y > point.y),
        point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
      {
        inside.toggle()
      }
      j = i
    }
    return inside
  }
  public static func selection(strokes: [Stroke], polygon: [Point], bounds: Rect) -> Set<UUID> {
    guard let p = polygon.first else { return [] }
    let minX = polygon.map(\.x).min() ?? p.x
    let maxX = polygon.map(\.x).max() ?? p.x
    let minY = polygon.map(\.y).min() ?? p.y
    let maxY = polygon.map(\.y).max() ?? p.y
    return Set(
      SpatialIndex(strokes: strokes, bounds: bounds).query(
        Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
      ).filter { strokeIntersects($0, polygon: polygon) }.map(\.id))
  }
  public static func erase(
    strokes: [Stroke], at point: Point, radius: Double, mode: EraserMode, highlighterOnly: Bool
  ) -> [Stroke] {
    strokes.flatMap { stroke -> [Stroke] in
      if highlighterOnly && stroke.tool != .highlighter { return [stroke] }
      let threshold = radius + stroke.width / 2
      let hit =
        stroke.samples.contains { $0.point.distance(to: point) <= threshold }
        || zip(stroke.samples, stroke.samples.dropFirst()).contains {
          distance(point, toSegmentFrom: $0.0.point, to: $0.1.point) <= threshold
        }
      guard hit else { return [stroke] }
      guard mode == .precision else { return [] }
      var segments: [[Sample]] = [[]]
      var dense: [Sample] = []
      for (a, b) in zip(stroke.samples, stroke.samples.dropFirst()) {
        let steps = Int(min(4096, max(1, ceil(a.point.distance(to: b.point) / max(1, radius / 2)))))
        for i in 0..<steps {
          let t = Double(i) / Double(steps)
          dense.append(
            Sample(
              point: Point(
                a.point.x + (b.point.x - a.point.x) * t, a.point.y + (b.point.y - a.point.y) * t),
              pressure: a.pressure + (b.pressure - a.pressure) * t,
              altitude: a.altitude + (b.altitude - a.altitude) * t))
        }
      }
      if let last = stroke.samples.last { dense.append(last) }
      for sample in dense {
        if sample.point.distance(to: point) <= radius + stroke.width / 2 {
          if !segments[segments.count - 1].isEmpty { segments.append([]) }
        } else {
          segments[segments.count - 1].append(sample)
        }
      }
      return segments.filter { !$0.isEmpty }.map {
        var copy = stroke
        copy.id = UUID()
        copy.samples = $0
        return copy
      }
    }
  }
  public static func shape(from stroke: Stroke, preset: ShapePreset = .automatic) -> Stroke {
    if preset != .automatic {
      guard let first = stroke.samples.first, let last = stroke.samples.last else { return stroke }
      var result = stroke
      let b = stroke.bounds
      let center = Point(b.x + b.width / 2, b.y + b.height / 2)
      let points: [Point]
      switch preset {
      case .automatic: return stroke
      case .line: points = [first.point, last.point]
      case .rectangle:
        points = [
          Point(b.x, b.y), Point(b.x + b.width, b.y), Point(b.x + b.width, b.y + b.height),
          Point(b.x, b.y + b.height), Point(b.x, b.y),
        ]
      case .ellipse:
        points = (0...64).map { i in
          let angle = Double(i % 64) / 64 * 2 * Double.pi
          return Point(center.x + b.width / 2 * cos(angle), center.y + b.height / 2 * sin(angle))
        }
      case .triangle:
        points = [
          Point(center.x, b.y), Point(b.x + b.width, b.y + b.height), Point(b.x, b.y + b.height),
          Point(center.x, b.y),
        ]
      case .diamond:
        points = [
          Point(center.x, b.y), Point(b.x + b.width, center.y), Point(center.x, b.y + b.height),
          Point(b.x, center.y), Point(center.x, b.y),
        ]
      }
      result.samples = points.map { Sample(point: $0) }
      return result
    }
    guard let first = stroke.samples.first, let last = stroke.samples.last, stroke.samples.count > 2
    else { return stroke }
    var result = stroke
    if first.point.distance(to: last.point) > 25 {
      result.samples = [first, last]
      return result
    }
    let b = stroke.bounds
    let center = Point(b.x + b.width / 2, b.y + b.height / 2)
    let corners = [
      Point(b.x, b.y), Point(b.x + b.width, b.y), Point(b.x + b.width, b.y + b.height),
      Point(b.x, b.y + b.height), Point(b.x, b.y),
    ]
    let cornerHits = corners.prefix(4).filter { c in
      stroke.samples.contains { $0.point.distance(to: c) < max(b.width, b.height) * 0.15 }
    }.count
    let closed = stroke.samples.map(\.point) + [first.point]
    let vertices = simplify(closed, tolerance: max(2, min(b.width, b.height) * 0.035))
    if cornerHits < 3, (4...9).contains(vertices.count) {
      result.samples = vertices.map { Sample(point: $0) }
      return result
    }
    result.samples =
      cornerHits >= 3
      ? corners.map { Sample(point: $0) }
      : (0...64).map { i in
        let t = Double(i) / 64 * 2 * .pi
        return Sample(
          point: Point(center.x + b.width / 2 * cos(t), center.y + b.height / 2 * sin(t)))
      }
    return result
  }
  private static func simplify(_ points: [Point], tolerance: Double) -> [Point] {
    guard points.count > 2, let first = points.first, let last = points.last else { return points }
    var largest = 0.0
    var split = 0
    for i in 1..<(points.count - 1) {
      let value = distance(points[i], toSegmentFrom: first, to: last)
      if value > largest {
        largest = value
        split = i
      }
    }
    guard largest > tolerance else { return [first, last] }
    return Array(simplify(Array(points[...split]), tolerance: tolerance).dropLast())
      + simplify(Array(points[split...]), tolerance: tolerance)
  }

}

public enum InkGestures {
  public static func heldShape(_ stroke: Stroke) -> Stroke? {
    guard stroke.samples.count >= 8, let first = stroke.samples.first,
      let last = stroke.samples.last
    else { return nil }
    let b = stroke.bounds
    let diagonal = hypot(b.width, b.height)
    guard diagonal > 24 else { return nil }
    let closed = first.point.distance(to: last.point) < diagonal * 0.25
    if !closed {
      let length = first.point.distance(to: last.point)
      guard length > 24,
        stroke.samples.allSatisfy({
          Editing.distance($0.point, toSegmentFrom: first.point, to: last.point) < length * 0.12
        })
      else { return nil }
      var result = stroke
      result.samples = [first, last]
      return result
    }
    let center = Point(b.x + b.width / 2, b.y + b.height / 2)
    let rx = max(1, (b.width - stroke.width) / 2)
    let ry = max(1, (b.height - stroke.width) / 2)
    let error =
      stroke.samples.reduce(0.0) {
        $0 + abs(hypot(($1.point.x - center.x) / rx, ($1.point.y - center.y) / ry) - 1)
      } / Double(stroke.samples.count)
    if error < 0.16 {
      var result = stroke
      let circular = rx / ry > 0.8 && rx / ry < 1.25
      let xRadius = circular ? (rx + ry) / 2 : rx
      let yRadius = circular ? xRadius : ry
      result.samples = (0...64).map { i in
        let angle = Double(i % 64) / 64 * 2 * Double.pi
        return Sample(
          point: Point(center.x + xRadius * cos(angle), center.y + yRadius * sin(angle)))
      }
      return result
    }
    let result = Editing.shape(from: stroke)
    guard (4...9).contains(result.samples.count) else { return nil }
    return result
  }

  public static func resizeHeldShape(_ stroke: Stroke, from start: Point, to end: Point) -> Stroke {
    var result = stroke
    guard let first = stroke.samples.first else { return result }
    if stroke.samples.count == 2 {
      result.samples[1].point = end
    } else {
      let b = stroke.bounds
      let center = Point(b.x + b.width / 2, b.y + b.height / 2)
      let factor = min(20, max(0.05, end.distance(to: center) / max(1, start.distance(to: center))))
      result.samples = stroke.samples.map {
        var sample = $0
        sample.point = Point(
          center.x + ($0.point.x - center.x) * factor,
          center.y + ($0.point.y - center.y) * factor)
        return sample
      }
    }
    result.samples[0].pressure = first.pressure
    return result
  }

  // Require several broad reversals; ordinary loops and short handwriting must remain ink.
  public static func isScratch(_ points: [Point]) -> Bool {
    guard let first = points.first, points.count >= 7 else { return false }
    var reduced = [first]
    for point in points.dropFirst() where point.distance(to: reduced.last!) >= 8 {
      reduced.append(point)
    }
    guard reduced.count >= 7 else { return false }
    var reversals = 0
    var length = 0.0
    for i in 1..<reduced.count {
      let a = reduced[i - 1]
      let b = reduced[i]
      length += a.distance(to: b)
      if i > 1 {
        let previous = reduced[i - 2]
        let ux = a.x - previous.x
        let uy = a.y - previous.y
        let vx = b.x - a.x
        let vy = b.y - a.y
        if (ux * vx + uy * vy) / max(1, hypot(ux, uy) * hypot(vx, vy)) < -0.65 {
          reversals += 1
        }
      }
    }
    let xs = reduced.map(\.x)
    let ys = reduced.map(\.y)
    let width = xs.max()! - xs.min()!
    let height = ys.max()! - ys.min()!
    return reversals >= 4 && min(width, height) >= 8 && length > 120
      && length / max(1, hypot(width, height)) > 3
  }

  public static func scratchTargets(_ points: [Point], strokes: [Stroke]) -> Set<UUID> {
    guard isScratch(points) else { return [] }
    return Set(
      strokes.filter { stroke in
        let strokeSegments = zip(stroke.samples, stroke.samples.dropFirst())
        let scratchSegments = Array(zip(points, points.dropFirst()))
        let radius = max(8, stroke.width * 2)
        return stroke.samples.contains { sample in
          scratchSegments.contains { a, b in
            Editing.distance(sample.point, toSegmentFrom: a, to: b) < radius
          }
        }
          || strokeSegments.contains { a, b in
            scratchSegments.contains { c, d in
              segmentsIntersect(a.point, b.point, c, d)
                || Editing.distance(c, toSegmentFrom: a.point, to: b.point) < radius
                || Editing.distance(d, toSegmentFrom: a.point, to: b.point) < radius
            }
          }
      }.map(\.id))
  }
  private static func segmentsIntersect(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
    let rx = b.x - a.x
    let ry = b.y - a.y
    let sx = d.x - c.x
    let sy = d.y - c.y
    let cross = rx * sy - ry * sx
    guard abs(cross) > 0.00001 else { return false }
    let qx = c.x - a.x
    let qy = c.y - a.y
    let t = (qx * sy - qy * sx) / cross
    let u = (qx * ry - qy * rx) / cross
    return (0...1).contains(t) && (0...1).contains(u)
  }

  public static func selectionContains(_ point: Point, page: Page, ids: Set<UUID>) -> Bool {
    let bounds =
      page.strokes.filter { ids.contains($0.id) }.map(\.bounds)
      + page.images.filter { ids.contains($0.id) }.map(\.bounds)
      + page.texts.filter { ids.contains($0.id) }.map(\.bounds)
    guard let first = bounds.first else { return false }
    let minX = bounds.reduce(first.x) { min($0, $1.x) } - 8
    let minY = bounds.reduce(first.y) { min($0, $1.y) } - 8
    let maxX = bounds.reduce(first.x + first.width) { max($0, $1.x + $1.width) } + 8
    let maxY = bounds.reduce(first.y + first.height) { max($0, $1.y + $1.height) } + 8
    return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).contains(point)
  }

  public static func translate(_ page: Page, ids: Set<UUID>, by delta: Point) -> Page {
    var result = page
    for i in result.strokes.indices where ids.contains(result.strokes[i].id) {
      result.strokes[i].samples = result.strokes[i].samples.map {
        var sample = $0
        sample.point.x += delta.x
        sample.point.y += delta.y
        return sample
      }
    }
    for i in result.images.indices where ids.contains(result.images[i].id) {
      result.images[i].frame.x += delta.x
      result.images[i].frame.y += delta.y
    }
    for i in result.texts.indices where ids.contains(result.texts[i].id) {
      result.texts[i].origin.x += delta.x
      result.texts[i].origin.y += delta.y
    }
    return result
  }

  public static func blankPage(matching previous: Page) -> Page {
    var page = Page(paper: previous.paper)
    page.backgroundSize = previous.dimensions
    return page
  }
}

public struct SelectionTransform: Equatable, Sendable {
  public var center: Point
  public var scale: Double
  public var angle: Double
  public var translation: Point
  public init(center: Point, scale: Double = 1, angle: Double = 0, translation: Point = Point(0, 0))
  {
    self.center = center
    self.scale = scale
    self.angle = angle
    self.translation = translation
  }
  public func apply(_ point: Point) -> Point {
    let x = (point.x - center.x) * scale
    let y = (point.y - center.y) * scale
    return Point(
      center.x + x * cos(angle) - y * sin(angle) + translation.x,
      center.y + x * sin(angle) + y * cos(angle) + translation.y)
  }
}

extension InkGestures {
  public static func selectionBounds(page: Page, ids: Set<UUID>) -> Rect? {
    let bounds =
      page.strokes.filter { ids.contains($0.id) }.map(\.bounds)
      + page.images.filter { ids.contains($0.id) }.map(\.bounds)
      + page.texts.filter { ids.contains($0.id) }.map(\.bounds)
    guard let first = bounds.first else { return nil }
    let x = bounds.reduce(first.x) { min($0, $1.x) }
    let y = bounds.reduce(first.y) { min($0, $1.y) }
    let maxX = bounds.reduce(first.x + first.width) { max($0, $1.x + $1.width) }
    let maxY = bounds.reduce(first.y + first.height) { max($0, $1.y + $1.height) }
    return Rect(x: x, y: y, width: maxX - x, height: maxY - y)
  }
  public static func transform(_ page: Page, ids: Set<UUID>, by transform: SelectionTransform)
    -> Page
  {
    guard transform.scale.isFinite, transform.scale > 0, transform.angle.isFinite,
      transform.translation.x.isFinite, transform.translation.y.isFinite
    else { return page }
    var result = page
    for i in result.strokes.indices where ids.contains(result.strokes[i].id) {
      result.strokes[i].samples = result.strokes[i].samples.map {
        var sample = $0
        sample.point = transform.apply(sample.point)
        return sample
      }
      result.strokes[i].width = min(10000, result.strokes[i].width * transform.scale)
    }
    for i in result.images.indices where ids.contains(result.images[i].id) {
      let original = result.images[i]
      let center = transform.apply(
        Point(
          original.frame.x + original.frame.width / 2,
          original.frame.y + original.frame.height / 2))
      let width = original.frame.width * transform.scale
      let height = original.frame.height * transform.scale
      result.images[i].frame = Rect(
        x: center.x - width / 2, y: center.y - height / 2,
        width: width, height: height)
      result.images[i].rotation += transform.angle
    }
    for i in result.texts.indices where ids.contains(result.texts[i].id) {
      let original = result.texts[i]
      let r = original.layoutBounds
      let center = transform.apply(Point(r.x + r.width / 2, r.y + r.height / 2))
      result.texts[i].size = min(1000, original.size * transform.scale)
      result.texts[i].boxWidth = (original.boxWidth ?? 280) * transform.scale
      let size = result.texts[i].layoutBounds
      result.texts[i].origin = Point(center.x - size.width / 2, center.y - size.height / 2)
      result.texts[i].rotation = (original.rotation ?? 0) + transform.angle
    }
    return result
  }
}

public enum NotebookPaging {
  public static func target(
    origin: Double, projected: Double, velocity: Double,
    pageWidth: Double, contentWidth: Double
  ) -> Double {
    guard pageWidth > 0 else { return 0 }
    let current = (origin / pageWidth).rounded()
    let last = max(0, (contentWidth / pageWidth).rounded() - 1)
    // Programmatic navigation has no gesture velocity and may jump across several pages.
    if abs(velocity) < 1 && abs(projected - origin) > pageWidth * 1.01 {
      return min(last, max(0, (projected / pageWidth).rounded())) * pageWidth
    }
    let delta = projected - origin
    let direction =
      abs(velocity) > 80
      ? (velocity > 0 ? 1.0 : -1.0)
      : abs(delta) > pageWidth * 0.15 ? (delta > 0 ? 1.0 : -1.0) : 0
    return min(last, max(0, current + direction)) * pageWidth
  }
}

public enum ShapePreset: String, CaseIterable, Sendable {
  case automatic, line, rectangle, ellipse, triangle, diamond
  public var symbol: String {
    switch self {
    case .automatic: "scribble"
    case .line: "line.diagonal"
    case .rectangle: "rectangle"
    case .ellipse: "circle"
    case .triangle: "triangle"
    case .diamond: "diamond"
    }
  }
}
