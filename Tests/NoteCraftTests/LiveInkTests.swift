import CoreGraphics
import Foundation
import NoteCraftCore
import Testing

@testable import NoteCraft

@MainActor private func penCanvas(style: PenStyle, stabilization: Double = 0) -> DrawingView {
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.configuration = CanvasConfiguration(
    page: Page(), assets: [:], tool: .pen, color: .ink, width: 3, style: style, pencilOnly: false,
    selection: [], onStroke: { _ in }, onGesture: { _ in }, onTap: { _ in }, holdToShape: false,
    stabilization: stabilization)
  return view
}

@MainActor private func write(
  _ view: DrawingView, count: Int, from x: Double = 20, at start: TimeInterval = 100
) {
  for i in 0..<count {
    view.accept(
      Sample(point: Point(x + Double(i) * 3, 60 + sin(Double(i) / 4) * 8), pressure: 0.6),
      time: start + Double(i) / 240)
  }
}

@MainActor @Test func everyStrokeStartsItsFountainWidthsOverInsteadOfContinuingThePreviousOnes() {
  let view = penCanvas(style: .fountain)
  write(view, count: 30)
  view.finish()
  write(view, count: 8)
  // The live ink is only drawn with the fountain model while there is one width per sample; a
  // second stroke that inherits the first one's widths falls back to plain pressure widths and then
  // changes thickness when the pen lifts.
  #expect(view.input.fountain.widths.count == view.samples.count)
}

@MainActor @Test func theSmootherStartsFreshWithEachStroke() throws {
  let view = penCanvas(style: .ballpoint)
  write(view, count: 40, from: 20)
  view.finish()
  // A second stroke far away must not be pulled towards where the first one ended.
  write(view, count: 3, from: 400, at: 101)
  let first = try #require(view.samples.first)
  #expect(first.point == Point(400, 60))
}

@MainActor @Test func theCommittedStrokeEndsWhereThePenLifted() throws {
  let view = penCanvas(style: .ballpoint)
  var committed: Stroke?
  view.configuration?.onStroke = { committed = $0 }
  write(view, count: 40)
  let lift = Sample(point: Point(300, 90), pressure: 0.6)
  view.accept(lift, time: 100 + 40.0 / 240)
  view.finish()
  let end = try #require(committed?.samples.last)
  #expect(end.point == lift.point, "ink must reach the tip even though the filter trails it")
}

@MainActor @Test func aSteadyHandKeepsItsShapeThroughTheSmoother() throws {
  // A straight horizontal stroke at 3 pt per sample: the smoother may only trail, not wander.
  let view = penCanvas(style: .ballpoint)
  view.accept(Sample(point: Point(20, 200)), time: 100)
  var wander = 0.0
  for i in 1..<120 {
    view.accept(Sample(point: Point(20 + Double(i) * 3, 200)), time: 100 + Double(i) / 240)
    wander = max(wander, abs(view.samples[i].point.y - 200))
  }
  #expect(wander < 0.01)
}

@MainActor @Test func lowerStabilizationLetsTheTipFollowCloser() throws {
  func lag(_ stabilization: Double) -> Double {
    let view = penCanvas(style: .ballpoint, stabilization: stabilization)
    for i in 0..<240 {
      view.accept(Sample(point: Point(20 + Double(i) * 2, 200)), time: 100 + Double(i) / 240)
    }
    return 20 + 239 * 2 - (view.samples.last?.point.x ?? 0)
  }
  #expect(lag(0) < lag(0.5) && lag(0.5) < lag(1))
  #expect(lag(0) < 1)
}

// The plan must keep doing what the live renderer did before Pencil estimates existed.
@Test func withoutPendingMeasurementsThePlanMatchesTheOriginalSplit() {
  var baked = 0
  for count in 1...80 {
    let plan = LiveInkPlan(count: count, bakedThrough: baked, firstPending: nil)
    let stableEnd = count - 2
    let expectedBake = stableEnd > baked ? (baked + 1)..<(stableEnd + 1) : (baked + 1)..<(baked + 1)
    #expect(plan.bake == expectedBake, "count \(count)")
    if stableEnd > baked { baked = stableEnd }
    #expect(plan.bakedThrough == baked)
    // The original tail: the last three samples (fewer at the start), its segments from the one
    // that ends at the newest sample.
    let context = min(3, count)
    #expect(count - plan.tailStart == context, "count \(count)")
    #expect(plan.tailFirstSegment == max(1, count - 1) - (count - context), "count \(count)")
  }
}

@Test func aSampleWaitingForItsForceHoldsTheBakedInkBack() {
  // 30 samples, the newest ones waiting: nothing from sample 25 on may be baked.
  let plan = LiveInkPlan(count: 30, bakedThrough: 20, firstPending: 25)
  #expect(plan.bake == 21..<25)
  #expect(plan.bakedThrough == 24)
  // The tail now reaches back to the last baked sample and covers everything waiting.
  #expect(plan.tailStart == 23)
  #expect(plan.tailFirstSegment == 2)
  // Already baked ink is never taken back, even if an older sample is reported late.
  let late = LiveInkPlan(count: 30, bakedThrough: 27, firstPending: 25)
  #expect(late.bake.isEmpty)
  #expect(late.bakedThrough == 27)
}
