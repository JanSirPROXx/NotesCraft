import Foundation

// Clean curves from a hand-drawn stroke: graph lines, S-bends, spirals-out-of-a-pen, curved
// arrows. The stroke is lightly smoothed, fitted with as few cubic Béziers as the tolerance
// allows (Schneider's least-squares fit, so the hand's jitter averages out instead of being
// followed) and sampled densely again, which keeps the result a plain polyline in the model.
//
// Declining matters as much as fitting: handwriting must stay handwriting, so a stroke with a
// sharp corner, a loop or a tight squiggle is left alone.
extension ShapeRecognizer {
  // Corners tighter than this radius (points) are corners, not curves. A sine of a few hundred
  // points wide has a radius of 8 or more at its peaks, a hand-drawn "L" or "Z" about 2 to 4.
  private static let sharpRadius = 4.5
  // Spacing of the points the fitted curve is turned back into.
  private static let curveSpacing = 2.0

  // The smoothed curve for a plain curved open stroke, or nil when it is not one.
  static func smoothOpenCurve(_ input: [Point]) -> [Point]? {
    guard let path = curvePath(input) else { return nil }
    return fitSpline(path, diagonal: boundingDiagonal(path), raw: input)
  }

  // The stroke resampled evenly and de-jittered, if it qualifies as one smooth open curve.
  private static func curvePath(_ input: [Point]) -> [Point]? {
    let points = dedupe(input)
    guard points.count >= 8, let first = points.first, let last = points.last else { return nil }
    let length = pathLength(points)
    guard length >= 60, boundingDiagonal(points) >= 40 else { return nil }
    // Ends far enough apart: a loop or a "C" is a different figure.
    guard first.distance(to: last) > length * 0.15 else { return nil }
    let step = min(4, max(1.5, length / 150))
    var path = resample(points, count: max(8, Int(length / step) + 1))
    path[path.count - 1] = last
    path = relaxed(path, passes: 4)
    guard !hasSharpCorner(path, step: step), !crossesItself(path) else { return nil }
    return path
  }

  // Binomial smoothing with the end points held, so the curve still starts and ends where the
  // pen touched down and lifted.
  private static func relaxed(_ path: [Point], passes: Int) -> [Point] {
    var current = path
    guard current.count > 4 else { return current }
    for _ in 0..<passes {
      var next = current
      for i in 1..<(current.count - 1) {
        next[i] = Point(
          (current[i - 1].x + 2 * current[i].x + current[i + 1].x) / 4,
          (current[i - 1].y + 2 * current[i].y + current[i + 1].y) / 4)
      }
      current = next
    }
    return current
  }

  private static func hasSharpCorner(_ path: [Point], step: Double) -> Bool {
    let k = max(2, Int((sharpRadius / step).rounded()))
    guard path.count > 2 * k else { return false }
    // The turn between chords of one radius on both sides: for a circular bend of radius R it
    // is about chord / R, so the limit 1 rad rejects R below ~4.5 points.
    let chord = Double(k) * step
    let limit = min(1.1, chord / sharpRadius)
    for i in k..<(path.count - k) {
      let a = path[i - k]
      let b = path[i]
      let c = path[i + k]
      let ux = b.x - a.x
      let uy = b.y - a.y
      let vx = c.x - b.x
      let vy = c.y - b.y
      let lu = hypot(ux, uy)
      let lv = hypot(vx, vy)
      guard lu > 0.001, lv > 0.001 else { continue }
      if acos(max(-1, min(1, (ux * vx + uy * vy) / (lu * lv)))) > limit { return true }
    }
    return false
  }

  private static func crossesItself(_ path: [Point]) -> Bool {
    let n = path.count
    guard n > 4 else { return false }
    for i in 0..<(n - 1) {
      var j = i + 2
      while j < n - 1 {
        if segmentsCross(path[i], path[i + 1], path[j], path[j + 1]) { return true }
        j += 1
      }
    }
    return false
  }

  private static func segmentsCross(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
    func side(_ p: Point, _ q: Point, _ r: Point) -> Double {
      (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
    }
    let d1 = side(a, b, c)
    let d2 = side(a, b, d)
    let d3 = side(c, d, a)
    let d4 = side(c, d, b)
    return d1 * d2 < 0 && d3 * d4 < 0
  }

  private static func boundingDiagonal(_ points: [Point]) -> Double {
    let box = boundingBox(points)
    return hypot(box.width, box.height)
  }

  // MARK: Spline fit

  // The dense polyline of the fitted spline, or nil when the fit strays from the stroke.
  fileprivate static func fitSpline(_ path: [Point], diagonal: Double, raw: [Point]) -> [Point]? {
    let tolerance = max(1.2, min(4, diagonal * 0.008))
    let curves = BezierFit.fit(path, tolerance: tolerance)
    guard !curves.isEmpty else { return nil }
    var result: [Point] = []
    for curve in curves {
      let samples = curve.sampled(spacing: curveSpacing)
      result += result.isEmpty ? samples : Array(samples.dropFirst())
    }
    // The fit must still be the stroke the user drew: smoothing may move it by a few points,
    // never reshape it.
    let limit = max(5, diagonal * 0.05)
    for p in raw where distance(p, toPolyline: result) > limit { return nil }
    return result
  }

  static func maxDeviation(of points: [Point], from line: [Point]) -> Double {
    guard line.count > 1 else { return .infinity }
    return points.reduce(0) { max($0, distance($1, toPolyline: line)) }
  }

  private static func distance(_ p: Point, toPolyline line: [Point]) -> Double {
    var best = Double.infinity
    for i in 1..<line.count {
      best = min(best, Editing.distance(p, toSegmentFrom: line[i - 1], to: line[i]))
    }
    return best
  }

  // MARK: Curved arrow

  // A curved shaft that ends in a hand-drawn head (out along one barb, back to the tip, out
  // along the other) becomes one clean curve with a symmetric head. A straight shaft is left to
  // the exact `.arrow` shape.
  static func curvedArrow(_ input: [Point]) -> [Point]? {
    let points = dedupe(input)
    guard points.count >= 12 else { return nil }
    let length = pathLength(points)
    guard length >= 90 else { return nil }
    let step = min(4, max(1.5, length / 150))
    let count = max(40, Int(length / step) + 1)
    var path = resample(points, count: count)
    path[path.count - 1] = points[points.count - 1]
    let spacing = length / Double(path.count - 1)
    let window = max(2, Int((8 / spacing).rounded()))
    var corners = cornerIndices(path, closed: false, window: window)
    corners = pruned(corners, path: path, closed: false, length: length)
    guard corners.count >= 3 else { return nil }
    let tipIndex = corners[corners.count - 3]
    let firstBarb = corners[corners.count - 2]
    let secondTip = corners[corners.count - 1]
    guard tipIndex > path.count / 3, secondTip < path.count - 2 else { return nil }
    let tip = Point(
      (path[tipIndex].x + path[secondTip].x) / 2, (path[tipIndex].y + path[secondTip].y) / 2)
    let barbA = path[firstBarb]
    let barbB = path[path.count - 1]
    let lengthA = tip.distance(to: barbA)
    let lengthB = tip.distance(to: barbB)
    let shaftPath = Array(path[0...tipIndex])
    let shaftLength = pathLength(shaftPath)
    guard shaftLength > 50, path[tipIndex].distance(to: path[secondTip]) < min(lengthA, lengthB) * 0.7,
      lengthA > 10, lengthB > 10, lengthA < shaftLength * 0.6, lengthB < shaftLength * 0.6,
      min(lengthA, lengthB) / max(lengthA, lengthB) > 0.5
    else { return nil }
    // A straight shaft belongs to the exact arrow shape.
    let chord = shaftPath[0].distance(to: shaftPath[shaftPath.count - 1])
    var bow = 0.0
    for p in shaftPath {
      bow = max(bow, Editing.distance(p, toSegmentFrom: shaftPath[0], to: shaftPath[shaftPath.count - 1]))
    }
    guard bow > max(5, chord * 0.06) else { return nil }
    // The head leans back against the direction the shaft arrives in, on both sides.
    let lookback = max(2, Int((12 / spacing).rounded()))
    let before = path[max(0, tipIndex - lookback)]
    var tx = tip.x - before.x
    var ty = tip.y - before.y
    let norm = hypot(tx, ty)
    guard norm > 0.001 else { return nil }
    tx /= norm
    ty /= norm
    var angles: [Double] = []
    for barb in [barbA, barbB] {
      let bx = barb.x - tip.x
      let by = barb.y - tip.y
      let l = hypot(bx, by)
      let back = acos(max(-1, min(1, -(bx * tx + by * ty) / l)))
      guard back > 0.2, back < 1.25 else { return nil }
      angles.append(tx * by - ty * bx > 0 ? back : -back)
    }
    guard angles[0] * angles[1] < 0 else { return nil }
    guard let shaft = fitSpline(
      relaxed(shaftPath, passes: 3), diagonal: boundingDiagonal(shaftPath), raw: shaftPath)
    else { return nil }
    // Direction of the fitted shaft at its end, so the head sits square on the curve.
    let anchor = shaft[max(0, shaft.count - 1 - Int((12 / curveSpacing).rounded()))]
    let end = shaft[shaft.count - 1]
    var dx = end.x - anchor.x
    var dy = end.y - anchor.y
    let dn = hypot(dx, dy)
    guard dn > 0.001 else { return nil }
    dx /= dn
    dy /= dn
    let barb = (lengthA + lengthB) / 2
    let lean = (abs(angles[0]) + abs(angles[1])) / 2
    func head(_ angle: Double) -> Point {
      // The backward direction rotated by the lean, on the side the user's barb was.
      let c = cos(angle)
      let s = sin(angle)
      let bx = -dx
      let by = -dy
      return Point(end.x + barb * (bx * c - by * s), end.y + barb * (bx * s + by * c))
    }
    let sign = angles[0] > 0 ? 1.0 : -1.0
    let headA = head(sign * lean)
    let headB = head(-sign * lean)
    return shaft + [headA, end, headB]
  }
}

// Schneider's "An Algorithm for Automatically Fitting Digitized Curves" (Graphics Gems).
struct BezierFit {
  struct Vector {
    var x: Double
    var y: Double
    static func + (a: Vector, b: Vector) -> Vector { Vector(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Vector, b: Vector) -> Vector { Vector(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Vector, s: Double) -> Vector { Vector(x: a.x * s, y: a.y * s) }
    func dot(_ o: Vector) -> Double { x * o.x + y * o.y }
    var length: Double { hypot(x, y) }
    var unit: Vector {
      let l = length
      return l > 1e-12 ? Vector(x: x / l, y: y / l) : self
    }
  }

  struct Cubic {
    var p0: Vector
    var p1: Vector
    var p2: Vector
    var p3: Vector

    func at(_ t: Double) -> Vector {
      let u = 1 - t
      return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
    }
    func first(_ t: Double) -> Vector {
      let u = 1 - t
      return (p1 - p0) * (3 * u * u) + (p2 - p1) * (6 * u * t) + (p3 - p2) * (3 * t * t)
    }
    func second(_ t: Double) -> Vector {
      let u = 1 - t
      return (p2 - p1 * 2 + p0) * (6 * u) + (p3 - p2 * 2 + p1) * (6 * t)
    }

    func sampled(spacing: Double) -> [Point] {
      let hull = (p1 - p0).length + (p2 - p1).length + (p3 - p2).length
      let chord = (p3 - p0).length
      let estimate = (hull + chord) / 2
      let steps = max(2, Int((estimate / spacing).rounded(.up)))
      return (0...steps).map { i in
        let v = at(Double(i) / Double(steps))
        return Point(v.x, v.y)
      }
    }
  }

  static func fit(_ points: [Point], tolerance: Double) -> [Cubic] {
    let d = points.map { Vector(x: $0.x, y: $0.y) }
    guard d.count >= 2 else { return [] }
    let k = min(d.count - 1, 6)
    let left = (d[min(k, d.count - 1)] - d[0]).unit
    let right = (d[max(0, d.count - 1 - k)] - d[d.count - 1]).unit
    return fitCubic(d, 0, d.count - 1, left, right, tolerance * tolerance, depth: 0)
  }

  private static func fitCubic(
    _ d: [Vector], _ first: Int, _ last: Int, _ t1: Vector, _ t2: Vector, _ error: Double,
    depth: Int
  ) -> [Cubic] {
    let count = last - first + 1
    if count == 2 {
      let gap = (d[last] - d[first]).length / 3
      return [Cubic(p0: d[first], p1: d[first] + t1 * gap, p2: d[last] + t2 * gap, p3: d[last])]
    }
    var u = chordLength(d, first, last)
    var curve = generate(d, first, last, u, t1, t2)
    var (worst, split) = maxError(d, first, last, curve, u)
    if worst < error { return [curve] }
    if worst < error * 16 {
      for _ in 0..<6 {
        u = reparameterize(d, first, last, u, curve)
        curve = generate(d, first, last, u, t1, t2)
        (worst, split) = maxError(d, first, last, curve, u)
        if worst < error { return [curve] }
      }
    }
    // Hand-drawn data never needs this many pieces; stop rather than recurse without end.
    if depth > 14 || split <= first || split >= last { return [curve] }
    let center = (d[split - 1] - d[split + 1]).unit
    return fitCubic(d, first, split, t1, center, error, depth: depth + 1)
      + fitCubic(d, split, last, center * -1, t2, error, depth: depth + 1)
  }

  private static func generate(
    _ d: [Vector], _ first: Int, _ last: Int, _ u: [Double], _ t1: Vector, _ t2: Vector
  ) -> Cubic {
    let p0 = d[first]
    let p3 = d[last]
    var c00 = 0.0
    var c01 = 0.0
    var c11 = 0.0
    var x0 = 0.0
    var x1 = 0.0
    for i in 0..<u.count {
      let t = u[i]
      let s = 1 - t
      let b0 = s * s * s
      let b1 = 3 * t * s * s
      let b2 = 3 * t * t * s
      let b3 = t * t * t
      let a1 = t1 * b1
      let a2 = t2 * b2
      c00 += a1.dot(a1)
      c01 += a1.dot(a2)
      c11 += a2.dot(a2)
      let tmp = d[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3))
      x0 += a1.dot(tmp)
      x1 += a2.dot(tmp)
    }
    let det = c00 * c11 - c01 * c01
    let segment = (p3 - p0).length
    var alpha1 = 0.0
    var alpha2 = 0.0
    if abs(det) > 1e-12 {
      alpha1 = (x0 * c11 - x1 * c01) / det
      alpha2 = (c00 * x1 - c01 * x0) / det
    }
    // Handles that point backwards or are tiny would fold the curve; use the usual third.
    let epsilon = 1e-6 * segment
    if alpha1 < epsilon || alpha2 < epsilon {
      alpha1 = segment / 3
      alpha2 = segment / 3
    }
    return Cubic(p0: p0, p1: p0 + t1 * alpha1, p2: p3 + t2 * alpha2, p3: p3)
  }

  private static func reparameterize(
    _ d: [Vector], _ first: Int, _ last: Int, _ u: [Double], _ curve: Cubic
  ) -> [Double] {
    u.enumerated().map { i, t in
      let q = curve.at(t) - d[first + i]
      let q1 = curve.first(t)
      let q2 = curve.second(t)
      let numerator = q.dot(q1)
      let denominator = q1.dot(q1) + q.dot(q2)
      guard abs(denominator) > 1e-12 else { return t }
      return min(1, max(0, t - numerator / denominator))
    }
  }

  private static func chordLength(_ d: [Vector], _ first: Int, _ last: Int) -> [Double] {
    var u = [0.0]
    for i in (first + 1)...last { u.append(u[u.count - 1] + (d[i] - d[i - 1]).length) }
    let total = u[u.count - 1]
    guard total > 0 else { return u.indices.map { Double($0) / Double(max(1, u.count - 1)) } }
    return u.map { $0 / total }
  }

  private static func maxError(
    _ d: [Vector], _ first: Int, _ last: Int, _ curve: Cubic, _ u: [Double]
  ) -> (Double, Int) {
    var worst = 0.0
    var split = (first + last) / 2
    for i in (first + 1)..<last {
      let v = curve.at(u[i - first]) - d[i]
      let distance = v.dot(v)
      if distance >= worst {
        worst = distance
        split = i
      }
    }
    return (worst, split)
  }
}
