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

@MainActor private func write(_ view: DrawingView, count: Int, from x: Double = 20) {
  for i in 0..<count {
    view.accept(Sample(point: Point(x + Double(i) * 3, 60 + sin(Double(i) / 4) * 8), pressure: 0.6))
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

