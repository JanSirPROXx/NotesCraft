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
