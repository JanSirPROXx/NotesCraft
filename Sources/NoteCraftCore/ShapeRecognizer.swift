import Foundation

// Turns a hand-drawn stroke into an exact shape, or declines. Declining matters as much as
// recognizing: a wobbly stroke that is not clearly a line, rectangle, triangle, ellipse or right
// angle stays as the user drew it instead of being replaced by the wrong shape.
public enum ShapeRecognizer {
  public enum Result: Equatable, Sendable {
    case shape(ShapeSpec)
    // Straight-sided figure that has no ShapeKind, e.g. a general quadrilateral.
    case polygon([Point], closed: Bool)
  }

  public static func recognize(_ input: [Point]) -> Result? {
    let points = dedupe(input)
    guard points.count >= 3 else { return nil }
    let length = pathLength(points)
    guard length > 30, let first = points.first, let last = points.last else { return nil }
    let box = boundingBox(points)
    let diagonal = hypot(box.width, box.height)
    guard diagonal > 24 else { return nil }
    let gap = first.distance(to: last)
    let closed = gap < length * 0.2 && gap < diagonal * 0.6
    let count = min(200, max(48, Int(length / 4)))
    var path = resample(points, count: count)
    if closed, path.count > 3 { path.removeLast() }
    path = smoothed(path, closed: closed)
    let step = length / Double(count - 1)
    // Big windows ignore jitter; small ones still see the corners of a thin or tiny figure.
    for scale in [1.0, 0.55] {
      let window = max(2, Int((min(30, max(7, length * 0.04)) * scale / step).rounded()))
      if let result = attempt(
        path, raw: points, closed: closed, window: window, length: length, diagonal: diagonal)
      {
        return result
      }
    }
    return nil
  }

  private static func attempt(
    _ path: [Point], raw points: [Point], closed: Bool, window: Int, length: Double,
    diagonal: Double
  ) -> Result? {
    var corners = cornerIndices(path, closed: closed, window: window)
    corners = pruned(corners, path: path, closed: closed, length: length)
    let segments = segmentRanges(corners, count: path.count, closed: closed)
    var analysed: [Segment] = []
    for range in segments {
      guard let segment = analyse(path, range, closed: closed, window: window) else {
        // A piece that is neither straight nor a clean arc: only a full ellipse can still explain it.
        return closed ? roundShape(path, raw: points, diagonal: diagonal) : nil
      }
      analysed.append(segment)
    }
    if closed {
      if corners.count < 2 || corners.count > 8 || analysed.contains(where: { $0.kind != .line }) {
        if let shape = roundShape(path, raw: points, diagonal: diagonal) { return shape }
        if corners.count >= 2, corners.count <= 8, analysed.count == corners.count {
          return .polygon(composite(analysed, closed: true), closed: true)
        }
        if corners.count > 8, let rectangle = boxHugging(path, diagonal: diagonal) {
          return .shape(rectangle)
        }
        return nil
      }
      let vertices = refinedVertices(path, corners: corners, segments: analysed, closed: true)
      return closedPolygon(vertices, path: path)
    }
    // Open strokes.
    if corners.isEmpty, let only = analysed.first {
      switch only.kind {
      case .line:
        return lineResult(only.start, only.end)
      case .arc:
        return .polygon(only.arcPoints(), closed: false)
      }
    }
    guard corners.count <= 7 else { return nil }
    if analysed.allSatisfy({ $0.kind == .line }) {
      let vertices = refinedVertices(path, corners: corners, segments: analysed, closed: false)
      if vertices.count == 3, let angle = rightAngle(vertices[0], vertices[1], vertices[2]) {
        return angle
      }
      if vertices.count == 5, let arrow = arrow(vertices) { return arrow }
      return .polygon(regularized(vertices, closed: false), closed: false)
    }
    return .polygon(composite(analysed, closed: false), closed: false)
  }

  // MARK: Segments

  fileprivate struct Segment {
    enum Kind { case line, arc }
    var kind: Kind
    var points: [Point]
    var start: Point { points[0] }
    var end: Point { points[points.count - 1] }
    func arcPoints() -> [Point] { ShapeRecognizer.arc(points[0], points[points.count / 2], points[points.count - 1]) }
  }

  private static func segmentRanges(_ corners: [Int], count: Int, closed: Bool) -> [(Int, Int)] {
    if closed {
      guard corners.count >= 2 else { return [(0, count - 1)] }
      return corners.indices.map { (corners[$0], corners[($0 + 1) % corners.count]) }
    }
    let bounds = [0] + corners + [count - 1]
    return (0..<(bounds.count - 1)).map { (bounds[$0], bounds[$0 + 1]) }
  }

  private static func slice(_ path: [Point], _ range: (Int, Int)) -> [Point] {
    range.0 <= range.1
      ? Array(path[range.0...range.1]) : Array(path[range.0...]) + Array(path[...range.1])
  }

  // A straight run, a clean circular arc, or nil. Points near a corner are ignored because a
  // hand-drawn corner is always a little round.
  private static func analyse(_ path: [Point], _ range: (Int, Int), closed: Bool, window: Int)
    -> Segment?
  {
    let points = slice(path, range)
    guard points.count >= 3, let a = points.first, let b = points.last else { return nil }
    let chord = a.distance(to: b)
    guard chord > 6 else { return nil }
    let skip = window
    let inner = points.count > 2 * skip + 3 ? Array(points[skip..<(points.count - skip)]) : points
    let deviation = inner.map { Editing.distance($0, toSegmentFrom: a, to: b) }.max() ?? 0
    if deviation <= max(2.5, 0.045 * chord) { return Segment(kind: .line, points: points) }
    guard let circle = circumcircle(a, points[points.count / 2], b) else { return nil }
    let residual = inner.map { abs($0.distance(to: circle.center) - circle.radius) }.max() ?? 0
    guard residual <= max(3, min(0.08 * circle.radius, 0.035 * chord)), circle.radius < chord * 6 else {
      return nil
    }
    return Segment(kind: .arc, points: points)
  }

  private static func composite(_ segments: [Segment], closed: Bool) -> [Point] {
    var result: [Point] = []
    for segment in segments {
      let piece = segment.kind == .line ? [segment.start, segment.end] : segment.arcPoints()
      result += result.isEmpty ? piece : Array(piece.dropFirst())
    }
    if closed, let first = result.first { result[result.count - 1] = first }
    return result
  }

  private static func circumcircle(_ a: Point, _ b: Point, _ c: Point) -> (center: Point, radius: Double)? {
    let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
    guard abs(d) > 1e-6 else { return nil }
    let a2 = a.x * a.x + a.y * a.y
    let b2 = b.x * b.x + b.y * b.y
    let c2 = c.x * c.x + c.y * c.y
    let center = Point(
      (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
      (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
    return (center, center.distance(to: a))
  }

  // Points along the circle through a, m and b from a to b. A near half circle snaps to exactly
  // half so its ends form a diameter.
  static func arc(_ a: Point, _ m: Point, _ b: Point) -> [Point] {
    guard var circle = circumcircle(a, m, b) else { return [a, b] }
    let orientation: Double = (m.x - a.x) * (b.y - m.y) - (m.y - a.y) * (b.x - m.x) >= 0 ? 1 : -1
    let start = atan2(a.y - circle.center.y, a.x - circle.center.x)
    let end = atan2(b.y - circle.center.y, b.x - circle.center.x)
    var travel = ((end - start) * orientation).truncatingRemainder(dividingBy: 2 * .pi)
    if travel < 0 { travel += 2 * .pi }
    var sweep = travel * orientation
    var from = start
    if abs(travel - .pi) < 0.3 {
      circle.center = Point((a.x + b.x) / 2, (a.y + b.y) / 2)
      circle.radius = a.distance(to: b) / 2
      from = atan2(a.y - circle.center.y, a.x - circle.center.x)
      sweep = .pi * orientation
    }
    let steps = max(10, Int(abs(sweep) / 0.09))
    var result = (0...steps).map { i -> Point in
      let angle = from + sweep * Double(i) / Double(steps)
      return Point(
        circle.center.x + circle.radius * cos(angle), circle.center.y + circle.radius * sin(angle))
    }
    result[0] = a
    result[result.count - 1] = abs(travel - .pi) < 0.3 ? result[result.count - 1] : b
    return result
  }

  // MARK: Corners

  private static func smoothed(_ path: [Point], closed: Bool) -> [Point] {
    let n = path.count
    guard n > 4 else { return path }
    return path.indices.map { i in
      if !closed, i == 0 || i == n - 1 { return path[i] }
      let a = path[(i + n - 1) % n]
      let c = path[(i + 1) % n]
      return Point((a.x + 2 * path[i].x + c.x) / 4, (a.y + 2 * path[i].y + c.y) / 4)
    }
  }

  // Sharp turns of the path, measured between chords of a fixed length on both sides so hand
  // jitter does not register and a gentle curve never reaches the threshold.
  private static func cornerIndices(_ path: [Point], closed: Bool, window: Int) -> [Int] {
    let n = path.count
    guard n > 2 * window + 2 else { return [] }
    func wrap(_ i: Int) -> Int { ((i % n) + n) % n }
    var turn = [Double](repeating: 0, count: n)
    let range = closed ? 0..<n : window..<(n - window)
    for i in range {
      let a = path[wrap(i - window)]
      let b = path[i]
      let c = path[wrap(i + window)]
      let ux = b.x - a.x
      let uy = b.y - a.y
      let vx = c.x - b.x
      let vy = c.y - b.y
      let lu = hypot(ux, uy)
      let lv = hypot(vx, vy)
      guard lu > 0.01, lv > 0.01 else { continue }
      turn[i] = acos(max(-1, min(1, (ux * vx + uy * vy) / (lu * lv))))
    }
    var result: [Int] = []
    for i in range where turn[i] >= 0.6 {
      var isPeak = true
      for offset in 1...window {
        let before = closed ? wrap(i - offset) : i - offset
        let after = closed ? wrap(i + offset) : i + offset
        if before >= 0, turn[before] >= turn[i] { isPeak = false }
        if after < n, turn[after] > turn[i] { isPeak = false }
      }
      if isPeak { result.append(i) }
    }
    return result
  }

  // Drops corners that sit almost on the line between their neighbours, and corners that would
  // leave a stub shorter than a few percent of the stroke.
  private static func pruned(_ input: [Int], path: [Point], closed: Bool, length: Double) -> [Int] {
    var corners = input
    let minimum = max(8, length * 0.025)
    var changed = true
    while changed {
      changed = false
      let k = corners.count
      var weakest: (index: Int, score: Double)?
      for (j, c) in corners.enumerated() {
        let previous: Point
        let next: Point
        if closed {
          guard k >= 3 else { break }
          previous = path[corners[(j + k - 1) % k]]
          next = path[corners[(j + 1) % k]]
        } else {
          previous = j == 0 ? path[0] : path[corners[j - 1]]
          next = j == k - 1 ? path[path.count - 1] : path[corners[j + 1]]
        }
        let here = path[c]
        let stub = min(here.distance(to: previous), here.distance(to: next))
        let offLine = Editing.distance(here, toSegmentFrom: previous, to: next)
        let score = stub < minimum ? stub : offLine + minimum
        if (stub < minimum || offLine < max(3, length * 0.03)) && score < (weakest?.score ?? .infinity) {
          weakest = (j, score)
        }
      }
      if let weakest {
        corners.remove(at: weakest.index)
        changed = true
      }
    }
    return corners
  }

  // MARK: Vertices

  private static func fitLine(_ points: [Point]) -> (point: Point, direction: Point)? {
    guard points.count >= 2 else { return nil }
    let cx = points.reduce(0) { $0 + $1.x } / Double(points.count)
    let cy = points.reduce(0) { $0 + $1.y } / Double(points.count)
    var sxx = 0.0
    var syy = 0.0
    var sxy = 0.0
    for p in points {
      sxx += (p.x - cx) * (p.x - cx)
      syy += (p.y - cy) * (p.y - cy)
      sxy += (p.x - cx) * (p.y - cy)
    }
    let angle = 0.5 * atan2(2 * sxy, sxx - syy)
    return (Point(cx, cy), Point(cos(angle), sin(angle)))
  }

  private static func intersection(
    _ a: (point: Point, direction: Point), _ b: (point: Point, direction: Point)
  ) -> Point? {
    let cross = a.direction.x * b.direction.y - a.direction.y * b.direction.x
    guard abs(cross) > 0.15 else { return nil }
    let dx = b.point.x - a.point.x
    let dy = b.point.y - a.point.y
    let t = (dx * b.direction.y - dy * b.direction.x) / cross
    return Point(a.point.x + a.direction.x * t, a.point.y + a.direction.y * t)
  }

  // Corner positions from the intersection of the straight runs on both sides: exact even when
  // the pen rounded the corner.
  private static func refinedVertices(
    _ path: [Point], corners: [Int], segments: [Segment], closed: Bool
  ) -> [Point] {
    let lines = segments.map { segment -> (point: Point, direction: Point)? in
      let pts = segment.points
      let trim = max(1, pts.count / 6)
      guard pts.count > 2 * trim + 2 else { return fitLine(pts) }
      return fitLine(Array(pts[trim..<(pts.count - trim)]))
    }
    var vertices: [Point] = []
    let reach = max(12.0, pathLength(path) * 0.06)
    for (j, c) in corners.enumerated() {
      let before = closed ? (j + segments.count - 1) % segments.count : j
      let after = closed ? j : j + 1
      let raw = path[c]
      if let a = lines[before], let b = lines[after], let hit = intersection(a, b),
        hit.distance(to: raw) < reach
      {
        vertices.append(hit)
      } else {
        vertices.append(raw)
      }
    }
    if !closed {
      func project(_ p: Point, _ line: (point: Point, direction: Point)?) -> Point {
        guard let line else { return p }
        let t = (p.x - line.point.x) * line.direction.x + (p.y - line.point.y) * line.direction.y
        return Point(line.point.x + line.direction.x * t, line.point.y + line.direction.y * t)
      }
      vertices.insert(project(path[0], lines.first ?? nil), at: 0)
      vertices.append(project(path[path.count - 1], lines.last ?? nil))
    }
    return vertices
  }

  // MARK: Results

  private static func lineResult(_ a: Point, _ b: Point) -> Result? {
    let chord = a.distance(to: b)
    guard chord > 24 else { return nil }
    let center = Point((a.x + b.x) / 2, (a.y + b.y) / 2)
    let raw = atan2(b.y - a.y, b.x - a.x)
    return .shape(
      ShapeSpec(kind: .line, center: center, width: chord, height: 0, rotation: snapAngle(raw)))
  }

  private static func rightAngle(_ a: Point, _ b: Point, _ c: Point) -> Result? {
    let u = Point(a.x - b.x, a.y - b.y)
    let v = Point(c.x - b.x, c.y - b.y)
    let lu = hypot(u.x, u.y)
    let lv = hypot(v.x, v.y)
    guard lu > 24, lv > 24 else { return nil }
    let angle = acos(max(-1, min(1, (u.x * v.x + u.y * v.y) / (lu * lv))))
    guard abs(angle - .pi / 2) < 0.26 else { return nil }
    // The built-in right angle has its vertical arm up and horizontal arm to the right of the
    // corner (the horizontal arm is the vertical one turned 90° clockwise). Find which stroke arm
    // plays which role, then rotate the shape onto it.
    let arm1 = atan2(a.y - b.y, a.x - b.x)
    let arm2 = atan2(c.y - b.y, c.x - b.x)
    var quarter = arm2 - arm1
    while quarter > .pi { quarter -= 2 * .pi }
    while quarter < -.pi { quarter += 2 * .pi }
    let verticalIsFirst = quarter > 0
    let vertical = verticalIsFirst ? arm1 : arm2
    let vLength = verticalIsFirst ? lu : lv
    let hLength = verticalIsFirst ? lv : lu
    let turn = snapAngle(vertical + .pi / 2)
    let local = Point(hLength / 2, -vLength / 2)
    let center = Point(
      b.x + local.x * cos(turn) - local.y * sin(turn),
      b.y + local.x * sin(turn) + local.y * cos(turn))
    return .shape(
      ShapeSpec(kind: .rightAngle, center: center, width: hLength, height: vLength, rotation: turn))
  }

  // One stroke that runs along the shaft, out along one barb, back, and out along the other:
  // A→tip, tip→C, C→tip, tip→D.
  private static func arrow(_ v: [Point]) -> Result? {
    let a = v[0]
    let tip = Point((v[1].x + v[3].x) / 2, (v[1].y + v[3].y) / 2)
    let shaft = a.distance(to: tip)
    guard shaft > 30, v[1].distance(to: v[3]) < shaft * 0.35 else { return nil }
    let ux = (tip.x - a.x) / shaft
    let uy = (tip.y - a.y) / shaft
    let c = Point(v[2].x - tip.x, v[2].y - tip.y)
    let d = Point(v[4].x - tip.x, v[4].y - tip.y)
    let lc = hypot(c.x, c.y)
    let ld = hypot(d.x, d.y)
    guard lc > shaft * 0.1, ld > shaft * 0.1, lc < shaft * 0.75, ld < shaft * 0.75,
      min(lc, ld) / max(lc, ld) > 0.5
    else { return nil }
    guard (ux * c.y - uy * c.x) * (ux * d.y - uy * d.x) < 0 else { return nil }
    for barb in [c, d] {
      let back = acos(max(-1, min(1, -(barb.x * ux + barb.y * uy) / hypot(barb.x, barb.y))))
      guard back > 0.2, back < 1.25 else { return nil }
    }
    return .shape(
      ShapeSpec(
        kind: .arrow, center: Point((a.x + tip.x) / 2, (a.y + tip.y) / 2), width: shaft, height: 0,
        rotation: snapAngle(atan2(tip.y - a.y, tip.x - a.x))))
  }

  // Snaps edges that are nearly level or plumb, and keeps right angles square, then rebuilds the
  // corners from the corrected edge lines.
  private static func regularized(_ v: [Point], closed: Bool) -> [Point] {
    let n = v.count
    let edgeCount = closed ? n : n - 1
    guard edgeCount >= 2 else { return v }
    var directions = (0..<edgeCount).map { i -> Double in
      let a = v[i]
      let b = v[(i + 1) % n]
      return atan2(b.y - a.y, b.x - a.x)
    }
    let turnCount = closed ? edgeCount : edgeCount - 1
    var square = true
    for i in 0..<turnCount {
      let turn = angleDistance(directions[i], directions[(i + 1) % edgeCount])
      if abs(turn - .pi / 2) > 0.26 { square = false }
    }
    if square {
      var sx = 0.0
      var sy = 0.0
      for (i, direction) in directions.enumerated() {
        let weight = v[i].distance(to: v[(i + 1) % n])
        sx += cos(direction * 4) * weight
        sy += sin(direction * 4) * weight
      }
      var base = atan2(sy, sx) / 4
      if angleDistance(base, 0) < 0.14 || angleDistance(base, .pi / 2) < 0.14 { base = 0 }
      directions = directions.map { base + (($0 - base) / (.pi / 2)).rounded() * (.pi / 2) }
    } else {
      directions = directions.map {
        let axis = ($0 / (.pi / 2)).rounded() * (.pi / 2)
        return angleDistance($0, axis) < 0.1 ? axis : $0
      }
    }
    let lines = (0..<edgeCount).map { i -> (point: Point, direction: Point) in
      let a = v[i]
      let b = v[(i + 1) % n]
      return (Point((a.x + b.x) / 2, (a.y + b.y) / 2), Point(cos(directions[i]), sin(directions[i])))
    }
    var result: [Point] = []
    for i in 0..<n {
      if !closed, i == 0 || i == n - 1 {
        let line = lines[i == 0 ? 0 : edgeCount - 1]
        let t = (v[i].x - line.point.x) * line.direction.x + (v[i].y - line.point.y) * line.direction.y
        result.append(
          Point(line.point.x + line.direction.x * t, line.point.y + line.direction.y * t))
        continue
      }
      let before = lines[(i + edgeCount - 1) % edgeCount]
      let after = lines[i % edgeCount]
      if let hit = intersection(before, after), hit.distance(to: v[i]) < 40 {
        result.append(hit)
      } else {
        result.append(v[i])
      }
    }
    return result
  }

  private static func closedPolygon(_ vertices: [Point], path: [Point]) -> Result? {
    switch vertices.count {
    case 3:
      if let triangle = isoscelesTriangle(vertices) { return .shape(triangle) }
      if let triangle = matched(.rightTriangle, vertices) { return .shape(triangle) }
    case 4:
      if let diamond = diamond(vertices) { return .shape(diamond) }
      if let rectangle = rectangle(vertices, path: path) { return .shape(rectangle) }
    case 5:
      if let pentagon = matched(.pentagon, vertices) { return .shape(pentagon) }
    case 6:
      if let hexagon = matched(.hexagon, vertices) { return .shape(hexagon) }
    default:
      break
    }
    let clean = regularized(vertices, closed: true)
    return .polygon(clean + [clean[0]], closed: true)
  }

  // A built-in shape whose own corners all coincide with the stroke's corners.
  private static func matched(_ kind: ShapeKind, _ v: [Point]) -> ShapeSpec? {
    let box = boundingBox(v)
    let spec = ShapeSpec(
      kind: kind, center: Point(box.x + box.width / 2, box.y + box.height / 2),
      width: box.width, height: box.height)
    var outline = spec.outline
    if outline.count > 1, outline.first == outline.last { outline.removeLast() }
    guard outline.count == v.count else { return nil }
    let tolerance = hypot(box.width, box.height) * 0.12
    let covered = v.allSatisfy { p in outline.contains { $0.distance(to: p) < tolerance } }
    let used = outline.allSatisfy { q in v.contains { $0.distance(to: q) < tolerance } }
    return covered && used ? spec : nil
  }

  // Four corners whose diagonals run level and plumb and cross near their middles.
  private static func diamond(_ v: [Point]) -> ShapeSpec? {
    let d1 = Point(v[2].x - v[0].x, v[2].y - v[0].y)
    let d2 = Point(v[3].x - v[1].x, v[3].y - v[1].y)
    func level(_ d: Point) -> Bool { angleDistance(atan2(d.y, d.x), 0) < 0.3 || angleDistance(atan2(d.y, d.x), .pi) < 0.3 }
    func plumb(_ d: Point) -> Bool { angleDistance(atan2(d.y, d.x), .pi / 2) < 0.3 || angleDistance(atan2(d.y, d.x), -.pi / 2) < 0.3 }
    let horizontal: Point
    let vertical: Point
    if level(d1), plumb(d2) {
      horizontal = d1
      vertical = d2
    } else if level(d2), plumb(d1) {
      horizontal = d2
      vertical = d1
    } else {
      return nil
    }
    let m1 = Point((v[0].x + v[2].x) / 2, (v[0].y + v[2].y) / 2)
    let m2 = Point((v[1].x + v[3].x) / 2, (v[1].y + v[3].y) / 2)
    let width = hypot(horizontal.x, horizontal.y)
    let height = hypot(vertical.x, vertical.y)
    guard m1.distance(to: m2) < max(width, height) * 0.2, min(width, height) > 16 else { return nil }
    return ShapeSpec(
      kind: .diamond, center: Point((m1.x + m2.x) / 2, (m1.y + m2.y) / 2), width: width,
      height: height)
  }

  private static func rectangle(_ v: [Point], path: [Point]) -> ShapeSpec? {
    var edges: [Point] = []
    for i in 0..<4 {
      let a = v[i]
      let b = v[(i + 1) % 4]
      edges.append(Point(b.x - a.x, b.y - a.y))
    }
    let lengths = edges.map { hypot($0.x, $0.y) }
    guard lengths.allSatisfy({ $0 > 10 }) else { return nil }
    // Every corner near 90° and opposite sides about equal.
    for i in 0..<4 {
      let e = edges[i]
      let f = edges[(i + 1) % 4]
      let cosine = (e.x * f.x + e.y * f.y) / (lengths[i] * lengths[(i + 1) % 4])
      guard abs(cosine) < 0.36 else { return nil }
    }
    guard
      min(lengths[0], lengths[2]) / max(lengths[0], lengths[2]) > 0.5,
      min(lengths[1], lengths[3]) / max(lengths[1], lengths[3]) > 0.5
    else { return nil }
    // Orientation: weighted mean of the edge directions folded into a quarter turn.
    var sx = 0.0
    var sy = 0.0
    for (edge, length) in zip(edges, lengths) {
      let angle = atan2(edge.y, edge.x) * 4
      sx += cos(angle) * length
      sy += sin(angle) * length
    }
    var rotation = atan2(sy, sx) / 4
    if abs(rotation) < 0.14 { rotation = 0 }
    return fittedBox(v, rotation: rotation, kind: .rectangle)
  }

  // An ellipse, unless a box hugs the points more tightly (a rounded square also fits an ellipse).
  private static func roundShape(_ path: [Point], raw: [Point], diagonal: Double) -> Result? {
    guard let shape = ellipse(path, raw: raw) else { return nil }
    if let box = boxHugging(path, diagonal: diagonal), hugError(path, box) < hugError(path, shape) {
      return .shape(box)
    }
    return .shape(shape)
  }

  // Mean distance of the points from a shape's outline, relative to the shape's smaller radius.
  private static func hugError(_ path: [Point], _ spec: ShapeSpec) -> Double {
    let outline = spec.outline
    guard outline.count > 1 else { return .infinity }
    var total = 0.0
    for p in path {
      var nearest = Double.infinity
      for i in 1..<outline.count {
        nearest = min(nearest, Editing.distance(p, toSegmentFrom: outline[i - 1], to: outline[i]))
      }
      total += nearest
    }
    return total / Double(path.count) / max(1, min(spec.width, spec.height) / 2)
  }

  private static func boxHugging(_ path: [Point], diagonal: Double) -> ShapeSpec? {
    let box = boundingBox(path)
    let rect = ShapeSpec(
      kind: .rectangle, center: Point(box.x + box.width / 2, box.y + box.height / 2),
      width: box.width, height: box.height)
    let outline = rect.outline
    var worst = 0.0
    var total = 0.0
    for p in path {
      var nearest = Double.infinity
      for i in 1..<outline.count {
        nearest = min(nearest, Editing.distance(p, toSegmentFrom: outline[i - 1], to: outline[i]))
      }
      worst = max(worst, nearest)
      total += nearest
    }
    return total / Double(path.count) < diagonal * 0.025 && worst < diagonal * 0.08 ? rect : nil
  }

  private static func isoscelesTriangle(_ v: [Point]) -> ShapeSpec? {
    // Base is the lowest, most horizontal edge; the apex must sit near its middle, above it.
    let ordered = v.sorted { $0.y > $1.y }
    let base = [ordered[0], ordered[1]].sorted { $0.x < $1.x }
    let apex = ordered[2]
    let width = base[1].x - base[0].x
    guard width > 20, abs(base[1].y - base[0].y) < width * 0.12 else { return nil }
    let height = (base[0].y + base[1].y) / 2 - apex.y
    guard height > 15, abs(apex.x - (base[0].x + base[1].x) / 2) < width * 0.18 else { return nil }
    let baseY = (base[0].y + base[1].y) / 2
    return ShapeSpec(
      kind: .triangle, center: Point((base[0].x + base[1].x) / 2, baseY - height / 2),
      width: width, height: height)
  }

  private static func ellipse(_ path: [Point], raw: [Point]) -> ShapeSpec? {
    let cx = path.reduce(0) { $0 + $1.x } / Double(path.count)
    let cy = path.reduce(0) { $0 + $1.y } / Double(path.count)
    // Principal axes of the point cloud.
    var sxx = 0.0
    var syy = 0.0
    var sxy = 0.0
    for p in path {
      sxx += (p.x - cx) * (p.x - cx)
      syy += (p.y - cy) * (p.y - cy)
      sxy += (p.x - cx) * (p.y - cy)
    }
    var rotation = 0.5 * atan2(2 * sxy, sxx - syy)
    let c = cos(rotation)
    let s = sin(rotation)
    var minU = Double.infinity
    var maxU = -Double.infinity
    var minV = Double.infinity
    var maxV = -Double.infinity
    for p in raw {
      let u = (p.x - cx) * c + (p.y - cy) * s
      let v = -(p.x - cx) * s + (p.y - cy) * c
      minU = min(minU, u)
      maxU = max(maxU, u)
      minV = min(minV, v)
      maxV = max(maxV, v)
    }
    let rx = (maxU - minU) / 2
    let ry = (maxV - minV) / 2
    guard rx > 8, ry > 8 else { return nil }
    let mu = (maxU + minU) / 2
    let mv = (maxV + minV) / 2
    var total = 0.0
    var worst = 0.0
    for p in path {
      let u = (p.x - cx) * c + (p.y - cy) * s - mu
      let v = -(p.x - cx) * s + (p.y - cy) * c - mv
      let error = abs(hypot(u / rx, v / ry) - 1)
      total += error
      worst = max(worst, error)
    }
    // A rectangle's corners sit about 40% outside the ellipse that fits it; hand-drawn circles
    // wobble far less, so the maximum error separates the two.
    guard total / Double(path.count) < 0.085, worst < 0.22 else { return nil }
    var width = 2 * rx
    var height = 2 * ry
    if min(width, height) / max(width, height) > 0.86 {
      width = (width + height) / 2
      height = width
      rotation = 0
    } else if abs(rotation) < 0.14 {
      rotation = 0
    } else if abs(abs(rotation) - .pi / 2) < 0.14 {
      swap(&width, &height)
      rotation = 0
    }
    let center = Point(cx + mu * c - mv * s, cy + mu * s + mv * c)
    return ShapeSpec(kind: .ellipse, center: center, width: width, height: height, rotation: rotation)
  }

  private static func fittedBox(_ path: [Point], rotation: Double, kind: ShapeKind) -> ShapeSpec {
    let c = cos(rotation)
    let s = sin(rotation)
    var minU = Double.infinity
    var maxU = -Double.infinity
    var minV = Double.infinity
    var maxV = -Double.infinity
    for p in path {
      let u = p.x * c + p.y * s
      let v = -p.x * s + p.y * c
      minU = min(minU, u)
      maxU = max(maxU, u)
      minV = min(minV, v)
      maxV = max(maxV, v)
    }
    let mu = (minU + maxU) / 2
    let mv = (minV + maxV) / 2
    return ShapeSpec(
      kind: kind, center: Point(mu * c - mv * s, mu * s + mv * c), width: maxU - minU,
      height: maxV - minV, rotation: rotation)
  }

  // MARK: Geometry helpers

  // Snap to the nearest multiple of 15° when within 5°; handwriting is rarely exactly level.
  static func snapAngle(_ angle: Double) -> Double {
    let step = Double.pi / 12
    let nearest = (angle / step).rounded() * step
    return abs(angle - nearest) < 0.09 ? nearest : angle
  }
  private static func angleDistance(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
    if d > .pi { d -= 2 * .pi }
    if d < -.pi { d += 2 * .pi }
    return abs(d)
  }
  private static func dedupe(_ points: [Point]) -> [Point] {
    var result: [Point] = []
    for p in points where result.last.map({ $0.distance(to: p) > 0.5 }) ?? true {
      result.append(p)
    }
    return result
  }
  private static func pathLength(_ points: [Point]) -> Double {
    zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
  }
  private static func boundingBox(_ points: [Point]) -> Rect {
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    let minX = xs.min() ?? 0
    let minY = ys.min() ?? 0
    return Rect(
      x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
  }
  private static func resample(_ points: [Point], count: Int) -> [Point] {
    let total = pathLength(points)
    guard total > 0 else { return points }
    let step = total / Double(count - 1)
    var result = [points[0]]
    var carried = 0.0
    var previous = points[0]
    for point in points.dropFirst() {
      var segment = previous.distance(to: point)
      var start = previous
      while carried + segment >= step, segment > 0 {
        let t = (step - carried) / segment
        let next = Point(start.x + (point.x - start.x) * t, start.y + (point.y - start.y) * t)
        result.append(next)
        start = next
        segment = start.distance(to: point)
        carried = 0
      }
      carried += segment
      previous = point
    }
    if result.count < count, let last = points.last { result.append(last) }
    return result
  }
}
