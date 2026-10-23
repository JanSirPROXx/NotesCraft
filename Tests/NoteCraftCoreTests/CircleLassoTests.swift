import Foundation
import Testing

@testable import NoteCraftCore

private func stroke(_ points: [Point], width: Double = 2) -> Stroke {
  Stroke(samples: points.map { Sample(point: $0) }, width: width)
}

// A circle sampled like a pen would, `turns` times around, starting at the top.
private func circle(
  center: Point, radius: Double, turns: Double = 1, samples: Int = 80, squash: Double = 1
) -> [Point] {
  (0...samples).map { i in
    let angle = -Double.pi / 2 + Double(i) / Double(samples) * turns * 2 * .pi
    return Point(
      center.x + radius * cos(angle) * squash, center.y + radius * sin(angle))
  }
}

private func line(from a: Point, to b: Point, count: Int = 30) -> [Point] {
  (0..<count).map { i in
    let t = Double(i) / Double(count - 1)
    return Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
  }
}

private let around = Rect(x: 0, y: 0, width: 600, height: 800)

@Test func aClosedCircleIsALoop() {
  #expect(InkGestures.loopPolygon(stroke(circle(center: Point(200, 200), radius: 50))) != nil)
}

@Test func aLoopThatOvershootsItsStartIsStillALoop() {
  // 1.1 turns: the pen ends past where it began, with a visible gap to the start.
  let overshoot = circle(center: Point(200, 200), radius: 50, turns: 1.1, samples: 90)
  #expect(InkGestures.loopPolygon(stroke(overshoot)) != nil)
}

@Test func aLoopThatStopsShortOfItsStartIsStillALoopWhenTheGapIsSmall() {
  let nearly = circle(center: Point(200, 200), radius: 50, turns: 0.96, samples: 80)
  #expect(InkGestures.loopPolygon(stroke(nearly)) != nil)
}

@Test func aWideOvalAroundALineOfTextIsALoop() {
  #expect(
    InkGestures.loopPolygon(
      stroke(circle(center: Point(300, 100), radius: 25, samples: 120, squash: 9))) != nil)
}

@Test func aRectangleDrawnInOneStrokeIsALoop() {
  let corners = [
    Point(100, 100), Point(260, 100), Point(260, 190), Point(100, 190), Point(100, 98),
  ]
  var points: [Point] = []
  for (a, b) in zip(corners, corners.dropFirst()) { points += line(from: a, to: b, count: 20) }
  #expect(InkGestures.loopPolygon(stroke(points)) != nil)
}

@Test(arguments: ["straight line", "open arc", "figure eight", "double spiral", "small o", "zigzag"])
func shapesThatAreNotLoopsAreLeftAlone(name: String) {
  let points: [Point]
  switch name {
  case "straight line": points = line(from: Point(50, 50), to: Point(300, 120), count: 40)
  case "open arc": points = circle(center: Point(200, 200), radius: 50, turns: 0.7)
  case "figure eight":
    points = (0...120).map { i in
      let t = Double(i) / 120 * 2 * .pi
      return Point(200 + 60 * sin(t), 200 + 40 * sin(2 * t))
    }
  case "double spiral":
    points = (0...160).map { i in
      let t = Double(i) / 160
      let angle = t * 4 * .pi
      return Point(200 + (20 + 50 * t) * cos(angle), 200 + (20 + 50 * t) * sin(angle))
    }
  case "small o": points = circle(center: Point(100, 100), radius: 5, samples: 30)
  default:
    points = (0..<60).map { Point(Double($0) * 4, $0.isMultiple(of: 2) ? 100 : 130) }
  }
  #expect(InkGestures.loopPolygon(stroke(points)) == nil, "\(name)")
}

@Test func shapesAndStickersAreNeverLoops() {
  var circleShape = stroke(circle(center: Point(200, 200), radius: 50))
  circleShape.tool = .shapes
  #expect(InkGestures.loopPolygon(circleShape) == nil)
  var highlighted = stroke(circle(center: Point(200, 200), radius: 50))
  highlighted.tool = .highlighter
  #expect(InkGestures.loopPolygon(highlighted) == nil)
}

// A word written inside a ring that was drawn afterwards.
private func pageWithRingAroundWord() -> (Page, ring: Stroke, word: [Stroke]) {
  let word = [
    stroke(line(from: Point(180, 190), to: Point(190, 215))),
    stroke(line(from: Point(200, 190), to: Point(212, 215))),
  ]
  let ring = stroke(circle(center: Point(200, 202), radius: 45))
  var page = Page()
  page.strokes = word + [ring]
  return (page, ring, word)
}

@Test func holdingOnTheLoopSelectsWhatItEnclosesAndNotTheLoop() throws {
  let (page, ring, word) = pageWithRingAroundWord()
  // The top of the ring.
  let target = try #require(
    InkGestures.loopSelection(at: Point(200, 157), page: page, tolerance: 12, bounds: around))
  #expect(target.loop == ring.id)
  #expect(target.selection == Set(word.map(\.id)))
}

@Test func onlyAPressOnTheLoopItselfCountsNotInsideOrFarAway() {
  let (page, _, _) = pageWithRingAroundWord()
  #expect(
    InkGestures.loopSelection(at: Point(200, 202), page: page, tolerance: 12, bounds: around)
      == nil, "the middle of the ring is a press on the word, not on the loop")
  #expect(
    InkGestures.loopSelection(at: Point(400, 400), page: page, tolerance: 12, bounds: around)
      == nil)
  // Near the outline, within the tolerance.
  #expect(
    InkGestures.loopSelection(at: Point(200, 165), page: page, tolerance: 12, bounds: around)
      != nil)
}

@Test func aLoopAroundNothingStaysInk() {
  var page = Page()
  page.strokes = [stroke(circle(center: Point(300, 300), radius: 40))]
  #expect(
    InkGestures.loopSelection(at: Point(300, 260), page: page, tolerance: 12, bounds: around)
      == nil)
}

@Test func aLoopThatEnclosesNothingDoesNotHideTheOneUnderIt() throws {
  var (page, ring, word) = pageWithRingAroundWord()
  // A small empty ring inside the big one, between its top and the word, touching neither.
  let empty = stroke(circle(center: Point(200, 178), radius: 10, samples: 60))
  page.strokes.append(empty)
  // A press near the top is within reach of both rings; the empty one is topmost but encloses
  // nothing.
  let target = try #require(
    InkGestures.loopSelection(at: Point(200, 163), page: page, tolerance: 12, bounds: around))
  #expect(target.loop == ring.id)
  #expect(target.selection.isSuperset(of: Set(word.map(\.id))))
}

@Test func theTopmostLoopWinsWhenSeveralAreUnderThePress() throws {
  var (page, _, word) = pageWithRingAroundWord()
  let outer = stroke(circle(center: Point(200, 202), radius: 47, samples: 90))
  page.strokes.append(outer)
  let target = try #require(
    InkGestures.loopSelection(at: Point(200, 156), page: page, tolerance: 12, bounds: around))
  #expect(target.loop == outer.id)
  // The inner ring is touched by the outer one, so it is part of what gets selected too.
  #expect(target.selection.isSuperset(of: Set(word.map(\.id))))
}

@Test func imagesAndTextBoxesInsideTheLoopAreSelectedToo() throws {
  var page = Page()
  let image = PageAsset(
    filename: "a.png", frame: Rect(x: 170, y: 170, width: 60, height: 60))
  var text = TextBox(origin: Point(150, 120), text: "note")
  text.boxWidth = 20
  page.images = [image]
  page.texts = [text]
  page.strokes = [stroke(circle(center: Point(200, 200), radius: 60))]
  let target = try #require(
    InkGestures.loopSelection(at: Point(200, 140), page: page, tolerance: 12, bounds: around))
  #expect(target.selection.contains(image.id))
  let withoutImages = InkGestures.loopSelection(
    at: Point(200, 140), page: page, tolerance: 12, bounds: around, images: false, texts: false)
  #expect(withoutImages == nil, "with nothing left that may be selected the loop stays ink")
}

@Test func lassoSelectionRespectsTheFiltersAndTheExclusion() {
  var page = Page()
  let inside = stroke(line(from: Point(190, 190), to: Point(210, 210)))
  let image = PageAsset(filename: "a.png", frame: Rect(x: 180, y: 180, width: 40, height: 40))
  page.strokes = [inside]
  page.images = [image]
  let polygon = circle(center: Point(200, 200), radius: 60)
  #expect(
    InkGestures.lassoSelection(page: page, polygon: polygon, bounds: around)
      == [inside.id, image.id])
  #expect(
    InkGestures.lassoSelection(page: page, polygon: polygon, bounds: around, ink: false)
      == [image.id])
  #expect(
    InkGestures.lassoSelection(
      page: page, polygon: polygon, bounds: around, images: false, excluding: [inside.id])
      == [])
}
