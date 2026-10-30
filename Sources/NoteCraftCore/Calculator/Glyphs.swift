import Foundation

// The shapes of the symbols the calculator pen reads, drawn by hand in code: a few ways of writing
// each one, as strokes in a box where a digit is 1 tall (y runs down). They are the starting point
// of the recognizer, before a single stroke of the reader's own handwriting is known: the templates
// made from them (`StockTemplates`) are what the first calculation is read against. They are also
// what the tests write expressions with, bent out of shape.

// Small, repeatable random numbers: stock templates and tests must come out the same every run.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

struct Glyph {
  // What the symbol means in an expression: digits, + - * ( ) and "÷", the obelus, which reads as
  // a division.
  var symbol: String
  var strokes: [[Point]]
}

enum StockGlyphs {
  private static func p(_ x: Double, _ y: Double) -> Point { Point(x, y) }

  private static func line(_ a: Point, _ b: Point) -> [Point] {
    (0...6).map { i in
      let t = Double(i) / 6
      return Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }
  }
  private static func polyline(_ points: [Point]) -> [Point] {
    var out: [Point] = []
    for i in 1..<points.count {
      let segment = line(points[i - 1], points[i])
      out += out.isEmpty ? segment : Array(segment.dropFirst())
    }
    return out
  }
  private static func bezier(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> [Point] {
    (0...12).map { i in
      let t = Double(i) / 12, u = 1 - t
      return Point(
        u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
        u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y)
    }
  }
  private static func ellipse(
    _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, from start: Double, sweep: Double
  ) -> [Point] {
    (0...28).map { i in
      let a = start + sweep * Double(i) / 28
      return Point(cx + rx * cos(a), cy + ry * sin(a))
    }
  }
  private static func chain(_ parts: [Point]...) -> [Point] {
    var out: [Point] = []
    for part in parts { out += out.isEmpty ? part : Array(part.dropFirst()) }
    return out
  }

  static let all: [Glyph] = {
    var glyphs: [Glyph] = []
    func g(_ symbol: String, _ strokes: [[Point]]) { glyphs.append(Glyph(symbol: symbol, strokes: strokes)) }

    // 0
    g("0", [ellipse(0.28, 0.5, 0.26, 0.5, from: -.pi / 2, sweep: 2 * .pi * 1.03)])
    g("0", [ellipse(0.28, 0.5, 0.24, 0.5, from: -.pi / 2, sweep: -2 * .pi * 0.97)])
    g("0", [ellipse(0.3, 0.5, 0.2, 0.5, from: -.pi / 3, sweep: -2 * .pi * 1.02)])
    // 1
    g("1", [polyline([p(0.05, 0.28), p(0.3, 0), p(0.3, 1)])])
    g("1", [polyline([p(0.3, 0), p(0.3, 1)])])
    g("1", [polyline([p(0.05, 0.28), p(0.3, 0), p(0.3, 1)]), polyline([p(0.05, 1), p(0.55, 1)])])
    g("1", [polyline([p(0.08, 0.2), p(0.28, 0), p(0.27, 1)])])
    // 2
    g("2", [chain(
      bezier(p(0.03, 0.28), p(0.05, -0.05), p(0.55, -0.05), p(0.52, 0.3)),
      bezier(p(0.52, 0.3), p(0.5, 0.55), p(0.1, 0.75), p(0.02, 1)), line(p(0.02, 1), p(0.56, 1)))])
    g("2", [chain(
      bezier(p(0.04, 0.3), p(0.1, -0.02), p(0.55, -0.02), p(0.5, 0.3)),
      line(p(0.5, 0.3), p(0.02, 1)), line(p(0.02, 1), p(0.54, 1)))])
    // 3
    g("3", [chain(
      bezier(p(0.04, 0.15), p(0.15, -0.08), p(0.55, -0.05), p(0.5, 0.25)),
      bezier(p(0.5, 0.25), p(0.48, 0.42), p(0.32, 0.48), p(0.2, 0.5)),
      bezier(p(0.2, 0.5), p(0.62, 0.5), p(0.6, 1.02), p(0.02, 0.88)))])
    g("3", [
      polyline([p(0.05, 0.05), p(0.5, 0.05), p(0.25, 0.45)]),
      bezier(p(0.25, 0.45), p(0.6, 0.45), p(0.6, 1.0), p(0.02, 0.9)),
    ])
    // 4
    g("4", [polyline([p(0.42, 1), p(0.42, 0), p(0, 0.68), p(0.58, 0.68)])])
    g("4", [polyline([p(0.4, 0), p(0, 0.68), p(0.58, 0.68)]), polyline([p(0.4, 0.2), p(0.4, 1)])])
    g("4", [polyline([p(0.05, 0), p(0.05, 0.62), p(0.5, 0.62)]), polyline([p(0.5, 0), p(0.5, 1)])])
    // 5
    g("5", [chain(
      polyline([p(0.5, 0), p(0.1, 0), p(0.06, 0.45)]),
      bezier(p(0.06, 0.45), p(0.3, 0.36), p(0.6, 0.5), p(0.5, 0.8)),
      bezier(p(0.5, 0.8), p(0.45, 1), p(0.15, 1.02), p(0, 0.88)))])
    g("5", [
      polyline([p(0.5, 0), p(0.1, 0)]),
      chain(
        polyline([p(0.1, 0), p(0.06, 0.45)]),
        bezier(p(0.06, 0.45), p(0.3, 0.36), p(0.6, 0.5), p(0.5, 0.8)),
        bezier(p(0.5, 0.8), p(0.45, 1), p(0.15, 1.02), p(0, 0.88))),
    ])
    // 6
    g("6", [chain(
      bezier(p(0.45, 0), p(0.2, 0.1), p(0.02, 0.4), p(0.03, 0.72)),
      ellipse(0.27, 0.72, 0.25, 0.28, from: .pi, sweep: -2 * .pi))])
    g("6", [chain(
      polyline([p(0.4, 0), p(0.05, 0.62)]),
      ellipse(0.27, 0.72, 0.24, 0.28, from: .pi, sweep: -2 * .pi))])
    // 7
    g("7", [polyline([p(0, 0.02), p(0.5, 0.02), p(0.14, 1)])])
    g("7", [polyline([p(0, 0.02), p(0.5, 0.02), p(0.14, 1)]), polyline([p(0.1, 0.52), p(0.42, 0.52)])])
    g("7", [polyline([p(0.02, 0.12), p(0, 0), p(0.5, 0), p(0.15, 1)])])
    // 8
    g("8", [chain(
      ellipse(0.27, 0.25, 0.2, 0.25, from: .pi / 2, sweep: 2 * .pi),
      ellipse(0.27, 0.76, 0.25, 0.26, from: -.pi / 2, sweep: -2 * .pi))])
    g("8", [
      ellipse(0.27, 0.25, 0.2, 0.25, from: .pi / 2, sweep: 2 * .pi),
      ellipse(0.27, 0.76, 0.25, 0.26, from: -.pi / 2, sweep: -2 * .pi),
    ])
    // 9
    g("9", [chain(
      ellipse(0.27, 0.3, 0.25, 0.3, from: 0, sweep: -2 * .pi),
      bezier(p(0.52, 0.3), p(0.52, 0.6), p(0.48, 0.85), p(0.2, 1)))])
    g("9", [chain(
      ellipse(0.27, 0.3, 0.25, 0.3, from: 0, sweep: -2 * .pi),
      line(p(0.52, 0.3), p(0.48, 1)))])
    // operators
    g("+", [line(p(0, 0.5), p(0.5, 0.5)), line(p(0.25, 0.25), p(0.25, 0.75))])
    g("-", [line(p(0, 0.5), p(0.45, 0.5))])
    g("*", [line(p(0, 0.3), p(0.42, 0.72)), line(p(0.42, 0.3), p(0, 0.72))])
    g("*", [line(p(0.02, 0.3), p(0.4, 0.7)), line(p(0.4, 0.3), p(0.02, 0.7))])
    g("÷", [
      line(p(0, 0.5), p(0.5, 0.5)), [p(0.25, 0.27), p(0.255, 0.275)], [p(0.25, 0.73), p(0.255, 0.735)],
    ])
    // No "/": written by hand it is a slanted "1", and the two cannot be told apart. Division is
    // written with the obelus or a fraction bar.
    g("(", [bezier(p(0.3, 0), p(0, 0.25), p(0, 0.75), p(0.3, 1))])
    g(")", [bezier(p(0, 0), p(0.3, 0.25), p(0.3, 0.75), p(0, 1))])
    return glyphs
  }()

  // The glyph's strokes bent out of shape, the way two writings of the same symbol differ. At
  // strength 1 this is a casual hand; 1.5 is a bad one.
  static func perturbed(
    _ strokes: [[Point]], strength s: Double, using rng: inout SeededGenerator
  ) -> [[Point]] {
    func r(_ amount: Double) -> Double { Double.random(in: -amount...amount, using: &rng) }
    let sx = 1 + r(0.2 * s), sy = 1 + r(0.1 * s)
    let angle = r(0.14 * s), shear = r(0.2 * s)
    let warpX = r(0.04 * s), warpY = r(0.04 * s)
    let phase = Double.random(in: 0...(2 * .pi), using: &rng)
    return strokes.map { stroke in
      var points = densified(stroke, step: 0.03)
      let front = Int(Double(points.count) * Double.random(in: 0...(0.05 * s), using: &rng))
      let back = Int(Double(points.count) * Double.random(in: 0...(0.05 * s), using: &rng))
      if points.count - front - back >= 2 { points = Array(points[front..<(points.count - back)]) }
      return points.map { point in
        var x = point.x * sx + shear * point.y
        var y = point.y * sy
        x += warpX * sin(y * 4 + phase)
        y += warpY * sin(x * 4 + phase)
        let cx = x - 0.25, cy = y - 0.5
        x = 0.25 + cx * cos(angle) - cy * sin(angle) + r(0.012 * s)
        y = 0.5 + cx * sin(angle) + cy * cos(angle) + r(0.012 * s)
        return Point(x, y)
      }
    }
  }

  // Points at an even spacing along a stroke, so a thinned or dense original reads alike.
  static func densified(_ points: [Point], step: Double) -> [Point] {
    guard points.count > 1 else { return points }
    var out = [points[0]]
    for i in 1..<points.count {
      let a = points[i - 1], b = points[i]
      let length = a.distance(to: b)
      let pieces = max(1, Int((length / step).rounded(.up)))
      for k in 1...pieces {
        let t = Double(k) / Double(pieces)
        out.append(Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
      }
    }
    return out
  }
}
