import Foundation
import Testing

@testable import NoteCraftCore

private func stroke(_ x: Double, _ y: Double, tool: InkTool = .pen, style: PenStyle = .ballpoint)
  -> Stroke
{
  Stroke(
    samples: [Sample(point: Point(x, y)), Sample(point: Point(x + 10, y + 10))],
    color: .ink, width: 2, tool: tool, style: style)
}

private func area(_ change: PageChange) -> Rect? {
  if case .area(let rect) = change { return rect }
  return nil
}

@Test func aPageThatDidNotChangeHasNoChange() {
  var page = Page()
  page.strokes = [stroke(10, 10)]
  #expect(PageDiff.change(from: page, to: page) == .none)
}

@Test func anAddedStrokeChangesOnlyItsOwnBox() throws {
  var old = Page()
  old.strokes = [stroke(10, 10)]
  var new = old
  let added = stroke(300, 400)
  new.strokes.append(added)
  let rect = try #require(area(PageDiff.change(from: old, to: new)))
  #expect(rect.x <= 299 && rect.y <= 399)
  #expect(rect.x + rect.width >= 311 && rect.y + rect.height >= 411)
  #expect(rect.width < 40 && rect.height < 40)
}

@Test func aRemovedStrokeChangesWhereItWas() throws {
  var old = Page()
  old.strokes = [stroke(10, 10), stroke(300, 400)]
  var new = old
  new.strokes.removeLast()
  let rect = try #require(area(PageDiff.change(from: old, to: new)))
  #expect(rect.x > 200)
}

@Test func aMovedStrokeChangesBothPlaces() throws {
  var old = Page()
  old.strokes = [stroke(10, 10)]
  var new = old
  new.strokes[0] = Stroke(
    id: old.strokes[0].id, samples: stroke(500, 600).samples, color: .ink, width: 2, tool: .pen,
    style: .ballpoint)
  let rect = try #require(area(PageDiff.change(from: old, to: new)))
  #expect(rect.x < 20 && rect.x + rect.width > 510)
  #expect(rect.y < 20 && rect.y + rect.height > 610)
}

@Test func piecesCutIntoTheMiddleOfThePageStayLocal() throws {
  var old = Page()
  old.strokes = [stroke(10, 10), stroke(300, 400), stroke(700, 900)]
  var new = old
  new.strokes.remove(at: 1)
  new.strokes.insert(stroke(300, 400), at: 1)  // a piece in the old stroke's place, new id
  let rect = try #require(area(PageDiff.change(from: old, to: new)))
  #expect(rect.x > 200 && rect.x + rect.width < 400)
}

@Test func reorderedStrokesNeedARedraw() {
  var old = Page()
  old.strokes = [stroke(10, 10), stroke(12, 12)]
  var new = old
  new.strokes.reverse()
  #expect(PageDiff.change(from: old, to: new) == .everything)
}

@Test func anotherPaperOrTextNeedsARedraw() {
  var old = Page()
  old.strokes = [stroke(10, 10)]
  var paper = old
  paper.paper.pattern = .dotted
  #expect(PageDiff.change(from: old, to: paper) == .everything)
  var text = old
  text.texts.append(TextBox(origin: Point(50, 50), text: "hello"))
  #expect(PageDiff.change(from: old, to: text) == .everything)
}

@Test func editingAmongPencilStrokesNeedsARedrawButAppendingDoesNot() throws {
  var old = Page()
  old.strokes = [stroke(10, 10, style: .pencil), stroke(100, 100, style: .pencil)]
  var appended = old
  appended.strokes.append(stroke(400, 400, style: .pencil))
  #expect(area(PageDiff.change(from: old, to: appended)) != nil)
  var removed = old
  removed.strokes.remove(at: 0)
  #expect(PageDiff.change(from: old, to: removed) == .everything)
}

@Test func aMovedImageChangesBothPlaces() throws {
  var old = Page()
  old.images = [PageAsset(filename: "a.png", frame: Rect(x: 10, y: 10, width: 100, height: 100))]
  var new = old
  new.images[0].frame.x = 400
  let rect = try #require(area(PageDiff.change(from: old, to: new)))
  #expect(rect.x < 10 && rect.x + rect.width > 500)
}

@Test func aWholePageOfStrokesIsComparedQuickly() {
  var old = Page()
  for i in 0..<1600 { old.strokes.append(stroke(Double(i % 40) * 20, Double(i / 40) * 20)) }
  var new = old
  new.strokes.append(stroke(5, 5))
  let start = ContinuousClock.now
  for _ in 0..<20 { _ = PageDiff.change(from: old, to: new) }
  // Well under a frame each, with room for a busy machine.
  #expect(ContinuousClock.now - start < .seconds(1))
}
