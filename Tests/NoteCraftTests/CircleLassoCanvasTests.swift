import CoreGraphics
import Foundation
import NoteCraftCore
import Testing

@testable import NoteCraft

@MainActor private func canvas(
  holdToShape: Bool = true, onStroke: @escaping (Stroke) -> Void = { _ in },
  onLoopHold: @escaping (Point) -> Bool
) -> DrawingView {
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.configuration = CanvasConfiguration(
    page: Page(), assets: [:], tool: .pen, color: .ink, width: 2, style: .ballpoint,
    pencilOnly: false, selection: [], onStroke: onStroke, onGesture: { _ in }, onTap: { _ in },
    onLoopHold: onLoopHold, holdToShape: holdToShape)
  return view
}

@MainActor private func wait(until condition: () -> Bool) async throws {
  // The hold task runs on the main actor, which other tests keep busy for seconds at a time.
  let deadline = ContinuousClock.now.advanced(by: .seconds(15))
  while !condition() && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(50))
  }
}

@MainActor @Test func aPenHeldStillOnALoopTurnsItIntoASelectionWithoutLeavingInk() async throws {
  var asked: [Point] = []
  var committed: [Stroke] = []
  let view = canvas(onStroke: { committed.append($0) }) { point in
    asked.append(point)
    return true
  }
  view.accept(Sample(point: Point(200, 157)), time: 100)
  view.accept(Sample(point: Point(200.4, 157.3)), time: 100.01)
  try await wait { view.input.consumed }
  #expect(view.input.consumed)
  #expect(asked.count == 1)
  #expect(asked.first == Point(200, 157))
  #expect(view.samples.isEmpty, "the touch that made the selection must not draw a dot")
  // The pen is still down: more movement is ignored, and lifting commits nothing.
  view.accept(Sample(point: Point(260, 190)), time: 100.7)
  view.accept(Sample(point: Point(300, 200)), time: 100.71)
  #expect(view.samples.isEmpty)
  view.finish()
  #expect(committed.isEmpty)
  // The next touch starts clean.
  view.resetInput()
  view.accept(Sample(point: Point(10, 10)), time: 101)
  #expect(view.samples.count == 1)
}

@MainActor @Test func aPressThatIsNotOnALoopStaysAnOrdinaryTouch() async throws {
  var asked = 0
  var committed: [Stroke] = []
  let view = canvas(holdToShape: false, onStroke: { committed.append($0) }) { _ in
    asked += 1
    return false
  }
  view.accept(Sample(point: Point(200, 157)), time: 100)
  try await wait { asked > 0 }
  #expect(asked == 1)
  #expect(!view.input.consumed)
  view.finish()
  #expect(committed.count == 1, "the dot is ink, as before")
}

@MainActor @Test func aPenThatIsMovingNeverCountsAsAPressOnALoop() async throws {
  var asked = 0
  let view = canvas { _ in
    asked += 1
    return true
  }
  // A real stroke across a loop, ending with a pause: that is draw-and-hold, not a press.
  for i in 0..<30 {
    view.accept(Sample(point: Point(100 + Double(i) * 4, 157)), time: 100 + Double(i) / 240)
  }
  try await Task.sleep(for: .milliseconds(900))
  #expect(asked == 0)
  #expect(!view.input.consumed)
}

@MainActor @Test func theLoopHoldDoesNotNeedDrawAndHoldToBeOn() async throws {
  var asked = 0
  let view = canvas(holdToShape: false) { _ in
    asked += 1
    return true
  }
  view.accept(Sample(point: Point(50, 50)), time: 100)
  try await wait { view.input.consumed }
  #expect(asked == 1)
}

@MainActor @Test func withoutALoopCallbackTheHoldBehavesAsBefore() async throws {
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.configuration = CanvasConfiguration(
    page: Page(), assets: [:], tool: .pen, color: .ink, width: 2, style: .ballpoint,
    pencilOnly: false, selection: [], onStroke: { _ in }, onGesture: { _ in }, onTap: { _ in },
    holdToShape: false)
  view.accept(Sample(point: Point(50, 50)), time: 100)
  try await Task.sleep(for: .milliseconds(700))
  #expect(!view.input.consumed)
  #expect(view.samples.count == 1)
}
