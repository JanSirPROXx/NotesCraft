import Foundation
import Testing

@testable import NoteCraftCore

// Deterministic "hand wobble" so the tests are stable.
private struct Wobble {
  var state: UInt64 = 12345
  mutating func next(_ amount: Double) -> Double {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return (Double(state >> 33) / Double(1 << 31) - 0.5) * 2 * amount
  }
}

private func polyline(_ corners: [Point], closed: Bool, wobble amount: Double = 1.5, density: Double = 3)
  -> [Point]
{
  var w = Wobble()
  var result: [Point] = []
  let loop = closed ? corners + [corners[0]] : corners
  for (a, b) in zip(loop, loop.dropFirst()) {
    let steps = max(2, Int(a.distance(to: b) / density))
    for i in 0..<steps {
      let t = Double(i) / Double(steps)
      result.append(
        Point(a.x + (b.x - a.x) * t + w.next(amount), a.y + (b.y - a.y) * t + w.next(amount)))
    }
  }
  if let last = loop.last { result.append(last) }
  return result
}

private func spec(_ result: ShapeRecognizer.Result?) -> ShapeSpec? {
  if case .shape(let spec) = result { return spec }
  return nil
}

@Test func handDrawnRectangleIsNotMistakenForACircle() throws {
  let points = polyline(
    [Point(100, 100), Point(300, 105), Point(298, 240), Point(103, 235)], closed: true)
  let rectangle = try #require(spec(ShapeRecognizer.recognize(points)))
  #expect(rectangle.kind == .rectangle)
  #expect(abs(rectangle.width - 200) < 15)
  #expect(abs(rectangle.height - 135) < 15)
  #expect(rectangle.rotation == 0)
}

@Test func squareWithRoundedCornersStillRecognizesAsRectangleNotCircle() throws {
  var path: [Point] = []
  let r = 18.0
  let corners = [
    (Point(200 - r, 100 + r), -Double.pi / 2), (Point(200 - r, 200 - r), 0),
    (Point(100 + r, 200 - r), Double.pi / 2), (Point(100 + r, 100 + r), Double.pi),
  ]
  for (center, start) in corners {
    for i in 0...6 {
      let a = start + Double(i) / 6 * Double.pi / 2
      path.append(Point(center.x + r * cos(a), center.y + r * sin(a)))
    }
  }
  path.append(path[0])
  let result = ShapeRecognizer.recognize(path)
  if let shape = spec(result) { #expect(shape.kind == .rectangle) } else { #expect(result == nil) }
  #expect(spec(result)?.kind != .ellipse)
}

@Test func wobblyCircleBecomesACircle() throws {
  var w = Wobble(state: 7)
  let points = (0...80).map { i -> Point in
    let a = Double(i) / 80 * 2 * Double.pi * 1.04
    let r = 80 + w.next(3)
    return Point(300 + r * cos(a), 300 + r * sin(a))
  }
  let circle = try #require(spec(ShapeRecognizer.recognize(points)))
  #expect(circle.kind == .ellipse)
  #expect(abs(circle.width - circle.height) < 0.001)
  #expect(abs(circle.width - 160) < 14)
}

@Test func ellipseKeepsItsProportions() throws {
  let points = (0...80).map { i -> Point in
    let a = Double(i) / 80 * 2 * Double.pi
    return Point(300 + 120 * cos(a), 300 + 50 * sin(a))
  }
  let ellipse = try #require(spec(ShapeRecognizer.recognize(points)))
  #expect(ellipse.kind == .ellipse)
  #expect(abs(ellipse.width - 240) < 8)
  #expect(abs(ellipse.height - 100) < 8)
}

@Test func triangleIsRecognized() throws {
  let points = polyline([Point(200, 100), Point(300, 260), Point(100, 262)], closed: true)
  let triangle = try #require(spec(ShapeRecognizer.recognize(points)))
  #expect(triangle.kind == .triangle)
}

@Test func straightStrokeBecomesALineAndSnapsLevel() throws {
  let points = polyline([Point(100, 100), Point(400, 106)], closed: false, wobble: 1)
  let line = try #require(spec(ShapeRecognizer.recognize(points)))
  #expect(line.kind == .line)
  #expect(line.rotation == 0)
  #expect(abs(line.width - 300) < 4)
}

@Test func squiggleIsLeftAlone() {
  var w = Wobble(state: 99)
  let points = (0..<90).map { i in
    Point(100 + Double(i) * 3, 200 + sin(Double(i) * 0.5) * 30 + w.next(4))
  }
  #expect(ShapeRecognizer.recognize(points) == nil)
}

@Test(arguments: [
  ([Point(100, 100), Point(100, 220), Point(260, 222)], 0.0),
  ([Point(300, 300), Point(300, 180), Point(140, 178)], Double.pi),
])
func rightAngleIsRecognizedAndKeepsItsCorner(corners: [Point], turn: Double) throws {
  let points = polyline(corners, closed: false, wobble: 1)
  let angle = try #require(spec(ShapeRecognizer.recognize(points)))
  #expect(angle.kind == .rightAngle)
  // The outline's corner (second vertex of the built-in L) lands on the drawn corner.
  let outline = angle.outline
  let corner = outline[1]
  #expect(corner.distance(to: corners[1]) < 8)
  #expect(abs(cos(angle.rotation) - cos(turn)) < 0.2)
}

@Test func shapeOutlineStaysInsideItsBoxAndRotates() {
  for kind in ShapeKind.allCases {
    let spec = ShapeSpec(kind: kind, center: Point(200, 200), width: 100, height: kind.isLinear ? 0 : 60)
    let box = Stroke.shape(spec, color: .ink, width: 2).bounds
    #expect(box.width <= 100 + 2.5 + 0.001, "\(kind)")
    #expect(box.height <= 60 + 2.5 + 0.001, "\(kind)")
  }
  let rotated = ShapeSpec(kind: .line, center: Point(0, 0), width: 10, height: 0, rotation: .pi / 2)
  let ends = rotated.outline
  #expect(abs(ends[0].x) < 1e-9 && abs(ends[0].y + 5) < 1e-9)
}

@Test func shapeObjectsSurviveEncodingAndOldFilesStillDecode() throws {
  let sticker = Stroke.sticker(.heart, at: Point(50, 50))
  let decoded = try JSONDecoder().decode(Stroke.self, from: JSONEncoder().encode(sticker))
  #expect(decoded == sticker)
  let legacy = Stroke(samples: [Sample(point: Point(1, 2))])
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
  object["shape"] = nil
  object["fillOpacity"] = nil
  let old = try JSONDecoder().decode(Stroke.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(old.shape == nil && old.fillOpacity == nil)
}

// MARK: Free-form drawing, the GoodNotes bar

private func polygon(_ result: ShapeRecognizer.Result?) -> [Point]? {
  if case .polygon(let points, _) = result { return points }
  return nil
}

@Test(arguments: [
  [Point(300, 100), Point(400, 200), Point(300, 300), Point(200, 200)],
  [Point(300, 120), Point(430, 200), Point(300, 280), Point(170, 200)],
])
func diamondIsNotMistakenForACircle(corners: [Point]) throws {
  let diamond = try #require(spec(ShapeRecognizer.recognize(polyline(corners, closed: true))))
  #expect(diamond.kind == .diamond)
  #expect(abs(diamond.width - (corners[1].x - corners[3].x)) < 16)
  #expect(abs(diamond.height - (corners[2].y - corners[0].y)) < 16)
}

@Test func diamondDrawnWithRoundedCornersAndOvershoot() throws {
  var corners: [Point] = []
  let top = Point(300, 100), right = Point(420, 200), bottom = Point(300, 300), left = Point(180, 200)
  let loop = [top, right, bottom, left, top, Point(360, 150)]
  for (a, b) in zip(loop, loop.dropFirst()) {
    for i in 0..<20 {
      let t = Double(i) / 20
      corners.append(Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
    }
  }
  // Round every corner by averaging, as a quick pen stroke does.
  var rounded = corners
  for _ in 0..<3 {
    rounded = rounded.indices.map { i in
      guard i > 0, i < rounded.count - 1 else { return rounded[i] }
      return Point(
        (rounded[i - 1].x + rounded[i].x * 2 + rounded[i + 1].x) / 4,
        (rounded[i - 1].y + rounded[i].y * 2 + rounded[i + 1].y) / 4)
    }
  }
  let shape = try #require(spec(ShapeRecognizer.recognize(rounded)))
  #expect(shape.kind == .diamond)
}

@Test func archSweepIsAnArcAndHalfCircleBecomesExactlyHalf() throws {
  let half = (0...40).map { i -> Point in
    let a = Double.pi + Double(i) / 40 * Double.pi * 0.97
    return Point(300 + 100 * cos(a), 300 + 100 * sin(a))
  }
  let points = try #require(polygon(ShapeRecognizer.recognize(half)))
  // Ends form a diameter and the bulge reaches a full radius.
  let ends = points[0].distance(to: points[points.count - 1])
  #expect(abs(ends - 200) < 6)
  #expect(abs((points.map(\.y).min() ?? 0) - 200) < 6)
}

@Test func gentleCurveIsKeptAsDrawnOrBecomesAnArcButNeverALine() {
  let wave = (0...60).map { i in Point(100 + Double(i) * 5, 200 + 40 * sin(Double(i) / 60 * 2 * .pi)) }
  #expect(ShapeRecognizer.recognize(wave) == nil)
}

@Test func openCornerKeepsItsShapeAsPolyline() throws {
  // Half a rectangle: three straight sides.
  let points = polyline(
    [Point(100, 100), Point(300, 104), Point(298, 240), Point(103, 238)], closed: false)
  let result = try #require(polygon(ShapeRecognizer.recognize(points)))
  #expect(result.count == 4)
  #expect(abs(result[0].y - result[1].y) < 0.001, "top edge snaps level")
  #expect(abs(result[1].x - result[2].x) < 0.001, "right edge snaps plumb")
}

@Test func singleStrokeArrowBecomesAnArrow() throws {
  // Shaft, then barb out and back, then the other barb.
  let tip = Point(400, 200)
  let points = polyline(
    [Point(100, 200), tip, Point(360, 170), tip, Point(360, 232)], closed: false, wobble: 1)
  let arrow = try #require(spec(ShapeRecognizer.recognize(points)))
  #expect(arrow.kind == .arrow)
  #expect(abs(arrow.width - 300) < 12)
}

@Test func halfRoundedRectangleKeepsStraightSidesAndArc() throws {
  // A "D": straight spine closed by a half circle.
  var points = [Point(200, 100), Point(200, 300)]
  points = polyline(points, closed: false, wobble: 0.5)
  for i in 1...30 {
    let a = Double.pi / 2 - Double(i) / 30 * Double.pi
    points.append(Point(200 + 100 * cos(a), 200 + 100 * sin(a)))
  }
  let shape = try #require(ShapeRecognizer.recognize(points))
  #expect(polygon(shape) != nil)
}

@Test func circleDrawnWithOverlapIsStillACircle() throws {
  let points = (0...100).map { i -> Point in
    let a = Double(i) / 100 * 2 * Double.pi * 1.12 - 1
    return Point(300 + 70 * cos(a), 300 + 70 * sin(a))
  }
  let circle = try #require(spec(ShapeRecognizer.recognize(points)))
  #expect(circle.kind == .ellipse)
}

@Test func squareAndUprightRectangleAreNotDiamonds() throws {
  let square = try #require(
    spec(
      ShapeRecognizer.recognize(
        polyline([Point(100, 100), Point(220, 100), Point(220, 220), Point(100, 220)], closed: true))))
  #expect(square.kind == .rectangle)
  let flat = try #require(
    spec(
      ShapeRecognizer.recognize(
        polyline([Point(100, 100), Point(400, 100), Point(400, 130), Point(100, 130)], closed: true))))
  #expect(flat.kind == .rectangle)
}

@Test func erDiagramPartsAreAllRecognized() throws {
  let entity = polyline(
    [Point(50, 50), Point(210, 52), Point(208, 120), Point(52, 118)], closed: true)
  #expect(spec(ShapeRecognizer.recognize(entity))?.kind == .rectangle)
  let attribute = (0...60).map { i -> Point in
    let a = Double(i) / 60 * 2 * Double.pi
    return Point(400 + 70 * cos(a), 80 + 32 * sin(a))
  }
  #expect(spec(ShapeRecognizer.recognize(attribute))?.kind == .ellipse)
  let relation = polyline(
    [Point(300, 250), Point(380, 290), Point(300, 330), Point(220, 290)], closed: true)
  #expect(spec(ShapeRecognizer.recognize(relation))?.kind == .diamond)
  let link = polyline([Point(210, 90), Point(300, 250)], closed: false, wobble: 1)
  #expect(spec(ShapeRecognizer.recognize(link))?.kind == .line)
}

// Every shape, drawn from any starting point, in either direction, at several sizes and
// with realistic hand wobble, must come back as itself.
private func rotated(_ points: [Point], by turn: Double) -> [Point] {
  points.map {
    Point($0.x * cos(turn) - $0.y * sin(turn) + 400, $0.x * sin(turn) + $0.y * cos(turn) + 400)
  }
}

@Test func shapesSurviveStartPointDirectionSizeAndWobble() {
  let figures: [(name: String, corners: [Point], kind: ShapeKind)] = [
    ("rectangle", [Point(-1, -0.6), Point(1, -0.6), Point(1, 0.6), Point(-1, 0.6)], .rectangle),
    ("square", [Point(-1, -1), Point(1, -1), Point(1, 1), Point(-1, 1)], .rectangle),
    ("diamond", [Point(0, -1), Point(1.3, 0), Point(0, 1), Point(-1.3, 0)], .diamond),
    ("square diamond", [Point(0, -1), Point(1, 0), Point(0, 1), Point(-1, 0)], .diamond),
    ("triangle", [Point(0, -1), Point(1, 0.8), Point(-1, 0.8)], .triangle),
  ]
  var failures: [String] = []
  for figure in figures {
    for scale in [60.0, 110.0, 200.0] {
      for wobble in [0.8, 2.0] {
        for start in 0..<figure.corners.count {
          for reversed in [false, true] {
            var corners = figure.corners.map { Point($0.x * scale, $0.y * scale) }
            corners = Array(corners[start...] + corners[..<start])
            if reversed { corners.reverse() }
            let points = rotated(polyline(corners, closed: true, wobble: wobble), by: 0)
            let result = ShapeRecognizer.recognize(points)
            if spec(result)?.kind != figure.kind {
              failures.append("\(figure.name) scale \(scale) wobble \(wobble) start \(start) rev \(reversed) → \(String(describing: spec(result)?.kind))")
            }
          }
        }
      }
    }
  }
  #expect(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(12))")
}

@Test func circlesAndEllipsesSurviveStartPointDirectionAndSize() {
  var failures: [String] = []
  var w = Wobble(state: 31)
  for (rx, ry) in [(40.0, 40.0), (90.0, 90.0), (150.0, 60.0), (120.0, 40.0), (60.0, 130.0)] {
    for start in stride(from: 0.0, to: 6.2, by: 1.3) {
      for direction in [1.0, -1.0] {
        let points = (0...90).map { i -> Point in
          let a = start + direction * Double(i) / 90 * 2 * Double.pi * 1.05
          return Point(400 + rx * cos(a) + w.next(2), 400 + ry * sin(a) + w.next(2))
        }
        if spec(ShapeRecognizer.recognize(points))?.kind != .ellipse {
          failures.append("ellipse \(rx)x\(ry) start \(start) dir \(direction)")
        }
      }
    }
  }
  #expect(failures.isEmpty, "\(failures.count) failures: \(failures.prefix(12))")
}
