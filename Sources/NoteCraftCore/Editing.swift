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
  // One pass with a bounding-box reject: most strokes on a page are nowhere near the eraser.
  private static func strokeIsNear(_ stroke: Stroke, _ point: Point, _ threshold: Double) -> Bool {
    guard var previous = stroke.samples.first?.point else { return false }
    var minX = previous.x
    var maxX = minX
    var minY = previous.y
    var maxY = minY
    for sample in stroke.samples.dropFirst() {
      let p = sample.point
      minX = min(minX, p.x)
      maxX = max(maxX, p.x)
      minY = min(minY, p.y)
      maxY = max(maxY, p.y)
    }
    guard point.x >= minX - threshold, point.x <= maxX + threshold,
      point.y >= minY - threshold, point.y <= maxY + threshold
    else { return false }
    if previous.distance(to: point) <= threshold { return true }
    for sample in stroke.samples.dropFirst() {
      if distance(point, toSegmentFrom: previous, to: sample.point) <= threshold { return true }
      previous = sample.point
    }
    return false
  }
  // In-place erase that reports the page area whose pixels changed (nil when nothing was hit),
  // so a canvas can repaint just that area.
  public static func eraseTracking(
    _ strokes: inout [Stroke], at point: Point, radius: Double, mode: EraserMode,
    highlighterOnly: Bool
  ) -> Rect? {
    var dirty: Rect?
    var result: [Stroke] = []
    result.reserveCapacity(strokes.count)
    for stroke in strokes {
      let threshold = radius + stroke.width / 2
      if (highlighterOnly && stroke.tool != .highlighter)
        || !strokeIsNear(stroke, point, threshold)
      {
        result.append(stroke)
        continue
      }
      let box = stroke.bounds
      let pad = stroke.width * 2 + 2
      let area = Rect(x: box.x - pad, y: box.y - pad, width: box.width + 2 * pad, height: box.height + 2 * pad)
      if let current = dirty {
        let minX = min(current.x, area.x)
        let minY = min(current.y, area.y)
        dirty = Rect(
          x: minX, y: minY, width: max(current.x + current.width, area.x + area.width) - minX,
          height: max(current.y + current.height, area.y + area.height) - minY)
      } else {
        dirty = area
      }
      result += erase(
        strokes: [stroke], at: point, radius: radius, mode: mode, highlighterOnly: highlighterOnly)
    }
    if dirty != nil { strokes = result }
    return dirty
  }
  // Points along the eraser's path no further apart than `spacing`, so a fast swipe cannot skip
  // over ink between two samples.
  public static func sweep(_ points: [Point], spacing: Double) -> [Point] {
    guard var previous = points.first else { return [] }
    var result = [previous]
    for point in points.dropFirst() {
      let gap = previous.distance(to: point)
      if gap > spacing {
        let steps = Int(min(512, (gap / spacing).rounded(.up)))
        for i in 1..<steps {
          let t = Double(i) / Double(steps)
          result.append(Point(previous.x + (point.x - previous.x) * t, previous.y + (point.y - previous.y) * t))
        }
      }
      result.append(point)
      previous = point
    }
    return result
  }
  public static func erase(
    strokes: [Stroke], along points: [Point], radius: Double, mode: EraserMode,
    highlighterOnly: Bool
  ) -> [Stroke] {
    let path = sweep(points, spacing: max(2, radius / 2))
    return strokes.flatMap { stroke -> [Stroke] in
      if highlighterOnly && stroke.tool != .highlighter { return [stroke] }
      let box = stroke.bounds
      let reach = radius + stroke.width / 2
      let relevant = path.filter {
        $0.x >= box.x - reach && $0.x <= box.x + box.width + reach
          && $0.y >= box.y - reach && $0.y <= box.y + box.height + reach
      }
      return relevant.reduce([stroke]) {
        erase(strokes: $0, at: $1, radius: radius, mode: mode, highlighterOnly: highlighterOnly)
      }
    }
  }
  public static func erase(
    strokes: [Stroke], at point: Point, radius: Double, mode: EraserMode, highlighterOnly: Bool
  ) -> [Stroke] {
    strokes.flatMap { stroke -> [Stroke] in
      if highlighterOnly && stroke.tool != .highlighter { return [stroke] }
      let threshold = radius + stroke.width / 2
      guard strokeIsNear(stroke, point, threshold) else { return [stroke] }
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
    return InkGestures.recognizedShape(stroke) ?? stroke
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
  // The exact shape for a stroke, or nil when it is not clearly one. Shapes with a ShapeKind keep
  // their spec so they stay editable; other straight-sided figures become plain polylines.
  public static func recognizedShape(_ stroke: Stroke) -> Stroke? {
    guard let result = ShapeRecognizer.recognize(stroke.samples.map(\.point)) else { return nil }
    var shaped = stroke
    if stroke.tool != .highlighter { shaped.tool = .shapes }
    switch result {
    case .shape(let spec): shaped.reshape(spec)
    case .polygon(let points, let closed):
      shaped.shape = nil
      shaped.samples = (closed ? points + [points[0]] : points).map { Sample(point: $0) }
    }
    return shaped
  }

  public static func heldShape(_ stroke: Stroke) -> Stroke? {
    guard stroke.samples.count >= 8 else { return nil }
    return recognizedShape(stroke)
  }

  public static func resizeHeldShape(_ stroke: Stroke, from start: Point, to end: Point) -> Stroke {
    var result = stroke
    guard let first = stroke.samples.first else { return result }
    if stroke.samples.count == 2 {
      result.samples[1].point = end
      if var spec = stroke.shape, spec.kind == .line {
        let a = first.point
        spec.center = Point((a.x + end.x) / 2, (a.y + end.y) / 2)
        spec.width = a.distance(to: end)
        spec.rotation = atan2(end.y - a.y, end.x - a.x)
        result.shape = spec
      }
    } else {
      let b = stroke.bounds
      let center = Point(b.x + b.width / 2, b.y + b.height / 2)
      let factor = min(20, max(0.05, end.distance(to: center) / max(1, start.distance(to: center))))
      if var spec = stroke.shape {
        spec.width *= factor
        spec.height *= factor
        result.reshape(spec)
        return result
      }
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
      result.strokes[i].shape?.center.x += delta.x
      result.strokes[i].shape?.center.y += delta.y
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

  // Infinite scrolling keeps a blank page below the writing: once the last page holds ink,
  // media, text or a PDF background, the caller should append the page returned here.
  public static func blankPageNeeded(after pages: [Page]) -> Page? {
    guard let last = pages.last,
      !(last.strokes.isEmpty && last.images.isEmpty && last.texts.isEmpty)
        || last.backgroundPDF != nil
    else { return nil }
    return blankPage(matching: last)
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
  // Extra scaling along the selected object's own axes (rotated by `axis`), used by the edge
  // handles that stretch a shape, image or text box in one direction.
  public var stretch: Point
  public var axis: Double
  public init(
    center: Point, scale: Double = 1, angle: Double = 0, translation: Point = Point(0, 0),
    stretch: Point = Point(1, 1), axis: Double = 0
  ) {
    self.center = center
    self.scale = scale
    self.angle = angle
    self.translation = translation
    self.stretch = stretch
    self.axis = axis
  }
  public var isStretched: Bool { stretch != Point(1, 1) }
  public func apply(_ point: Point) -> Point {
    let dx = point.x - center.x
    let dy = point.y - center.y
    let ca = cos(axis)
    let sa = sin(axis)
    // Into the object's axes, stretch, and back out.
    let lx = (dx * ca + dy * sa) * scale * stretch.x
    let ly = (-dx * sa + dy * ca) * scale * stretch.y
    let x = lx * ca - ly * sa
    let y = lx * sa + ly * ca
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
      transform.translation.x.isFinite, transform.translation.y.isFinite,
      transform.stretch.x.isFinite, transform.stretch.x > 0, transform.stretch.y.isFinite,
      transform.stretch.y > 0
    else { return page }
    var result = page
    let sx = transform.scale * transform.stretch.x
    let sy = transform.scale * transform.stretch.y
    for i in result.strokes.indices where ids.contains(result.strokes[i].id) {
      if var spec = result.strokes[i].shape {
        // Shape objects are rebuilt from their spec so edges stay exact; line weight is kept.
        spec.center = transform.apply(spec.center)
        spec.width *= sx
        spec.height *= sy
        spec.rotation += transform.angle
        result.strokes[i].reshape(spec)
        continue
      }
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
      let width = original.frame.width * sx
      let height = original.frame.height * sy
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
      result.texts[i].boxWidth = max(20, (original.boxWidth ?? 280) * sx)
      let size = result.texts[i].layoutBounds
      result.texts[i].origin = Point(center.x - size.width / 2, center.y - size.height / 2)
      result.texts[i].rotation = (original.rotation ?? 0) + transform.angle
    }
    return result
  }

  // The oriented frame of a single selected object, which gets edge handles that stretch it.
  public struct ObjectFrame: Equatable, Sendable {
    public var center: Point
    public var width: Double
    public var height: Double
    public var rotation: Double
    // Lines and text boxes only stretch along their own length.
    public var stretchesVertically: Bool
  }
  public static func objectFrame(page: Page, ids: Set<UUID>) -> ObjectFrame? {
    guard ids.count == 1, let id = ids.first else { return nil }
    if let stroke = page.strokes.first(where: { $0.id == id }), let spec = stroke.shape {
      return ObjectFrame(
        center: spec.center, width: spec.width, height: spec.height, rotation: spec.rotation,
        stretchesVertically: !spec.kind.isLinear)
    }
    if let image = page.images.first(where: { $0.id == id }) {
      return ObjectFrame(
        center: Point(image.frame.x + image.frame.width / 2, image.frame.y + image.frame.height / 2),
        width: image.frame.width, height: image.frame.height, rotation: image.rotation,
        stretchesVertically: true)
    }
    if let text = page.texts.first(where: { $0.id == id }) {
      let r = text.layoutBounds
      return ObjectFrame(
        center: Point(r.x + r.width / 2, r.y + r.height / 2), width: r.width, height: r.height,
        rotation: text.rotation ?? 0, stretchesVertically: false)
    }
    return nil
  }

  // Top-most object under a tap: text, then ink (outline or filled interior), then images.
  public static func objectID(at point: Point, page: Page, tolerance: Double) -> UUID? {
    if let text = page.texts.last(where: { $0.contains(point) }) { return text.id }
    for stroke in page.strokes.reversed() {
      let reach = stroke.width / 2 + tolerance
      let box = stroke.bounds
      guard
        box.intersects(
          Rect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2))
      else { continue }
      if stroke.samples.count == 1, let only = stroke.samples.first {
        if only.point.distance(to: point) <= reach { return stroke.id }
        continue
      }
      for i in 1..<stroke.samples.count
      where Editing.distance(point, toSegmentFrom: stroke.samples[i - 1].point, to: stroke.samples[i].point)
        <= reach
      {
        return stroke.id
      }
      if stroke.fillColor != nil, stroke.samples.count > 2,
        Editing.contains(point, polygon: stroke.samples.map(\.point))
      {
        return stroke.id
      }
    }
    if let image = page.images.last(where: { $0.contains(point) }) { return image.id }
    return nil
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
      abs(velocity) > 420
      ? (velocity > 0 ? 1.0 : -1.0)
      : abs(delta) > pageWidth * 0.3 ? (delta > 0 ? 1.0 : -1.0) : 0
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
