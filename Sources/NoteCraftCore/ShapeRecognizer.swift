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
    let closed = gap < length * 0.22 && gap < diagonal * 0.6
    let path = resample(points, count: 120)
    return closed ? recognizeClosed(path, raw: points, length: length, diagonal: diagonal)
      : recognizeOpen(path, length: length)
  }

  // MARK: Open strokes

  private static func recognizeOpen(_ path: [Point], length: Double) -> Result? {
    guard let first = path.first, let last = path.last else { return nil }
    let chord = first.distance(to: last)
    guard chord > 24 else { return nil }
    let deviation = path.map { Editing.distance($0, toSegmentFrom: first, to: last) }.max() ?? 0
    if deviation < chord * 0.07 {
      let center = Point((first.x + last.x) / 2, (first.y + last.y) / 2)
      let angle = snapAngle(atan2(last.y - first.y, last.x - first.x))
      let half = chord / 2
      let a = Point(center.x - half * cos(angle), center.y - half * sin(angle))
      let b = Point(center.x + half * cos(angle), center.y + half * sin(angle))
      // Snapping to the axis moves one end; keep the stroke anchored where it started.
      let snapped = angle == atan2(last.y - first.y, last.x - first.x)
      return .shape(
        ShapeSpec(
          kind: .line, center: center, width: chord, height: 0,
          rotation: snapped ? angle : atan2(b.y - a.y, b.x - a.x)))
    }
    let vertices = corners(of: path, closed: false, tolerance: max(4, length * 0.03))
    guard vertices.count == 3 else { return nil }
    let a = vertices[0]
    let b = vertices[1]
    let c = vertices[2]
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

  // MARK: Closed strokes

  private static func recognizeClosed(
    _ path: [Point], raw: [Point], length: Double, diagonal: Double
  )
    -> Result?
  {
    let vertices = corners(of: path, closed: true, tolerance: max(4, diagonal * 0.045))
    switch vertices.count {
    case 3:
      if let triangle = isoscelesTriangle(vertices) { return .shape(triangle) }
      return .polygon(vertices, closed: true)
    case 4:
      if let rectangle = rectangle(vertices, path: path) { return .shape(rectangle) }
      return .polygon(vertices, closed: true)
    default:
      break
    }
    if let ellipse = ellipse(path, raw: raw) { return .shape(ellipse) }
    // A rounded or sloppy rectangle has more than four soft corners but still hugs its box.
    if (5...9).contains(vertices.count), let rectangle = boxHugging(path, diagonal: diagonal) {
      return .shape(rectangle)
    }
    return nil
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
      min(lengths[0], lengths[2]) / max(lengths[0], lengths[2]) > 0.6,
      min(lengths[1], lengths[3]) / max(lengths[1], lengths[3]) > 0.6
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
    return fittedBox(path, rotation: rotation, kind: .rectangle)
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

  // Corner points of a stroke: Ramer–Douglas–Peucker, then drop vertices that barely turn.
  private static func corners(of path: [Point], closed: Bool, tolerance: Double) -> [Point] {
    var vertices: [Point]
    if closed {
      guard let first = path.first else { return [] }
      let far = path.indices.max { path[$0].distance(to: first) < path[$1].distance(to: first) }!
      let a = rdp(Array(path[0...far]), tolerance)
      let b = rdp(Array(path[far...]) + [first], tolerance)
      vertices = Array(a.dropLast()) + Array(b.dropLast())
    } else {
      vertices = rdp(path, tolerance)
    }
    var changed = true
    while changed, vertices.count > 2 {
      changed = false
      let n = vertices.count
      for i in 0..<n {
        if !closed, i == 0 || i == n - 1 { continue }
        let prev = vertices[(i + n - 1) % n]
        let next = vertices[(i + 1) % n]
        let cur = vertices[i]
        let u = Point(cur.x - prev.x, cur.y - prev.y)
        let v = Point(next.x - cur.x, next.y - cur.y)
        let lu = hypot(u.x, u.y)
        let lv = hypot(v.x, v.y)
        guard lu > 0.001, lv > 0.001 else {
          vertices.remove(at: i)
          changed = true
          break
        }
        let turn = acos(max(-1, min(1, (u.x * v.x + u.y * v.y) / (lu * lv))))
        if turn < 0.42 {
          vertices.remove(at: i)
          changed = true
          break
        }
      }
    }
    return vertices
  }
  private static func rdp(_ points: [Point], _ tolerance: Double) -> [Point] {
    guard points.count > 2, let first = points.first, let last = points.last else { return points }
    var worst = 0.0
    var split = 0
    for i in 1..<(points.count - 1) {
      let d = Editing.distance(points[i], toSegmentFrom: first, to: last)
      if d > worst {
        worst = d
        split = i
      }
    }
    guard worst > tolerance else { return [first, last] }
    return Array(rdp(Array(points[...split]), tolerance).dropLast())
      + rdp(Array(points[split...]), tolerance)
  }
}
