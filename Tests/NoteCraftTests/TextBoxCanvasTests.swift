import CoreGraphics
import Foundation
import NoteCraftCore
import Testing

@testable import NoteCraft

// A page with one text box at (100, 200), 220 pt wide, and the text tool.
@MainActor private final class Recorder {
  var selected: [UUID] = []
  var translations: [Point] = []
  var menus = 0
  var taps: [Point] = []
}

@MainActor private func textCanvas(selected: Bool, recorder: Recorder) -> (DrawingView, TextBox) {
  var box = TextBox(origin: Point(100, 200), text: "Hello")
  box.boxWidth = 220
  var page = Page()
  page.texts = [box]
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.configuration = CanvasConfiguration(
    page: page, assets: [:], tool: .text, color: .ink, width: 2, style: .ballpoint,
    pencilOnly: false, selection: selected ? [box.id] : [], onStroke: { _ in },
    onGesture: { _ in }, onTap: { recorder.taps.append($0) },
    onTranslateSelection: { recorder.translations.append($0) },
    onSelectionMenu: { recorder.menus += 1 },
    onSelectObject: { recorder.selected.append($0) }, holdToShape: false)
  return (view, box)
}

private let insideTheBox = Point(180, 212)

@MainActor @Test func draggingAnUnselectedTextBoxSelectsAndMovesIt() {
  let recorder = Recorder()
  let (view, box) = textCanvas(selected: false, recorder: recorder)
  view.accept(Sample(point: insideTheBox), time: 100)
  #expect(recorder.selected == [box.id], "the box is selected as soon as the touch lands on it")
  view.accept(Sample(point: Point(230, 262)), time: 100.05)
  view.accept(Sample(point: Point(280, 312)), time: 100.1)
  view.finish()
  #expect(recorder.translations == [Point(100, 100)])
  #expect(recorder.menus == 0)
  #expect(recorder.taps.isEmpty)
}

@MainActor @Test func draggingASelectedTextBoxMovesItWithoutSelectingAgain() {
  let recorder = Recorder()
  let (view, _) = textCanvas(selected: true, recorder: recorder)
  view.accept(Sample(point: insideTheBox), time: 100)
  view.accept(Sample(point: Point(205, 237)), time: 100.05)
  view.finish()
  #expect(recorder.selected.isEmpty)
  #expect(recorder.translations == [Point(25, 25)])
}

@MainActor @Test func aTapOnAnUnselectedTextBoxOnlySelectsIt() {
  let recorder = Recorder()
  let (view, box) = textCanvas(selected: false, recorder: recorder)
  view.accept(Sample(point: insideTheBox), time: 100)
  view.finish()
  #expect(recorder.selected == [box.id])
  #expect(recorder.menus == 0, "the first tap selects; it must not open the box for editing")
  #expect(recorder.translations.isEmpty)
}

@MainActor @Test func aTapOnTheSelectedTextBoxAsksToEditIt() {
  let recorder = Recorder()
  let (view, _) = textCanvas(selected: true, recorder: recorder)
  view.accept(Sample(point: insideTheBox), time: 100)
  view.finish()
  #expect(recorder.menus == 1)
  #expect(recorder.selected.isEmpty)
}

@MainActor @Test func aTapOnEmptyPaperIsAnOrdinaryTap() {
  let recorder = Recorder()
  let (view, _) = textCanvas(selected: false, recorder: recorder)
  view.accept(Sample(point: Point(400, 600)), time: 100)
  view.finish()
  #expect(recorder.taps == [Point(400, 600)])
  #expect(recorder.selected.isEmpty)
}

@MainActor @Test func aTouchOnAnotherTextBoxTakesHoldOfThatOneInstead() {
  let recorder = Recorder()
  var first = TextBox(origin: Point(100, 200), text: "One")
  first.boxWidth = 220
  var second = TextBox(origin: Point(100, 400), text: "Two")
  second.boxWidth = 220
  var page = Page()
  page.texts = [first, second]
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.configuration = CanvasConfiguration(
    page: page, assets: [:], tool: .text, color: .ink, width: 2, style: .ballpoint,
    pencilOnly: false, selection: [first.id], onStroke: { _ in }, onGesture: { _ in },
    onTap: { _ in }, onTranslateSelection: { recorder.translations.append($0) },
    onSelectObject: { recorder.selected.append($0) }, holdToShape: false)
  view.accept(Sample(point: Point(180, 412)), time: 100)
  view.accept(Sample(point: Point(180, 452)), time: 100.05)
  view.finish()
  #expect(recorder.selected == [second.id])
  #expect(recorder.translations == [Point(0, 40)])
}

@MainActor @Test func theOtherToolsAreNotAffectedByTheTextGrab() {
  let recorder = Recorder()
  var box = TextBox(origin: Point(100, 200), text: "Hello")
  box.boxWidth = 220
  var page = Page()
  page.texts = [box]
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.configuration = CanvasConfiguration(
    page: page, assets: [:], tool: .pen, color: .ink, width: 2, style: .ballpoint,
    pencilOnly: false, selection: [], onStroke: { _ in }, onGesture: { _ in }, onTap: { _ in },
    onSelectObject: { recorder.selected.append($0) }, holdToShape: false)
  view.accept(Sample(point: insideTheBox), time: 100)
  view.finish()
  #expect(recorder.selected.isEmpty, "a pen drawn over a text box writes, it does not grab it")
}

@MainActor @Test func theRightEdgeHandleWidensASelectedTextBoxAndKeepsItsLeftEdge() throws {
  var box = TextBox(origin: Point(100, 200), text: "Hello")
  box.boxWidth = 220
  var page = Page()
  page.texts = [box]
  var applied: SelectionTransform?
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.configuration = CanvasConfiguration(
    page: page, assets: [:], tool: .text, color: .ink, width: 2, style: .ballpoint,
    pencilOnly: false, selection: [box.id], onStroke: { _ in }, onGesture: { _ in },
    onTap: { _ in }, onTransformSelection: { applied = $0 }, holdToShape: false)
  // The handle on the right edge, halfway down the box: 100 + 220 across, 200 + 15 down.
  view.accept(Sample(point: Point(320, 215)), time: 100)
  view.accept(Sample(point: Point(380, 215)), time: 100.05)
  view.finish()
  let result = InkGestures.transform(page, ids: [box.id], by: try #require(applied))
  let moved = try #require(result.texts.first)
  #expect(abs((moved.boxWidth ?? 0) - 280) < 0.5)
  #expect(abs(moved.layoutBounds.x - 100) < 0.5, "the left edge stays where it was")
  #expect(moved.size == 20, "stretching changes the width, not the type size")
}
