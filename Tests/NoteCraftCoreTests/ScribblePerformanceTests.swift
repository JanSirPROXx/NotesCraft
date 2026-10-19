import Foundation
import Testing

@testable import NoteCraftCore

// A page full of handwriting: many short strokes with Pencil-density sampling.
private func denseTextPage(lines: Int = 36, wordsPerLine: Int = 9, lettersPerWord: Int = 5) -> [Stroke] {
  var strokes: [Stroke] = []
  for line in 0..<lines {
    for word in 0..<wordsPerLine {
      for letter in 0..<lettersPerWord {
        let x = 40 + Double(word) * 60 + Double(letter) * 10
        let y = 50 + Double(line) * 22
        let samples = (0..<60).map { i -> Sample in
          let t = Double(i) / 59
          return Sample(point: Point(x + 6 * sin(t * 6.28), y + 14 * t))
        }
        strokes.append(Stroke(samples: samples, width: 1.5))
      }
    }
  }
  return strokes
}

// A big back-and-forth scrub across the whole text block, drawn with Pencil-density samples.
private func bigScribble(sweeps: Int = 30) -> [Point] {
  var points: [Point] = []
  for sweep in 0..<sweeps {
    // Slanted sweeps, so every turn is a sharp reversal like a real scrub.
    let leftToRight = sweep.isMultiple(of: 2)
    for i in 0...120 {
      let t = Double(i) / 120
      points.append(Point(40 + (leftToRight ? t : 1 - t) * 560, 50 + (Double(sweep) + t) * 26))
    }
  }
  return points
}

@Test func bigScribbleOverAFullPageStaysInteractive() throws {
  let page = denseTextPage()
  let scribble = bigScribble()
  let clock = ContinuousClock()
  var outcome: InkGestures.ScratchOutcome?
  let elapsed = clock.measure { outcome = InkGestures.scratchOutcome(scribble, strokes: page) }
  #expect(try #require(outcome).strokes.count < page.count / 4)
  // Comparing every sample with every scribble segment took ~15 s here in a debug build; with
  // the segment grid it is ~0.35 s in debug and ~10 ms in release. The bound is loose enough
  // for debug builds on a busy machine and still catches that regression.
  #expect(elapsed < .seconds(3))
}

// Timings of the other page-sized operations. Printed rather than asserted: they guide tuning.
@Test func pageSizedOperationTimings() throws {
  let page = denseTextPage()
  let clock = ContinuousClock()
  func time(_ label: String, _ body: () throws -> Void) rethrows {
    let t = try clock.measure(body)
    print("TIMING \(label): \(t)")
  }
  // Eraser: a drag of 400 events across the page, as one gesture.
  for mode in [EraserMode.stroke, .precision] {
    var session = EraseSession(strokes: page)
    time("EraseSession x400 \(mode)") {
      for i in 0..<400 {
        _ = session.erase(
          at: Point(40 + Double(i) * 1.4, 50 + Double(i) * 1.8), radius: 10, mode: mode,
          highlighterOnly: false)
      }
    }
  }
  // Lasso around most of the page.
  let ring = (0..<40).map { i -> Point in
    let a = Double(i) / 40 * 2 * Double.pi
    return Point(320 + 300 * cos(a), 420 + 400 * sin(a))
  }
  time("lasso selection") {
    _ = Editing.selection(strokes: page, polygon: ring, bounds: Rect(x: 0, y: 0, width: 640, height: 900))
  }
  var notebookPage = Page()
  notebookPage.strokes = page
  let package = NotebookPackage(notebook: Notebook(pages: Array(repeating: notebookPage, count: 10)))
  var wrapper: FileWrapper?
  try time("encode 10 pages") { wrapper = try package.fileWrapper() }
  let size = wrapper?.fileWrappers?["manifest.json"]?.regularFileContents?.count ?? 0
  print("TIMING manifest bytes: \(size)")
  try time("decode 10 pages") { _ = try NotebookPackage(fileWrapper: try #require(wrapper)) }
}

// The grid must change nothing about what the eraser does, only how fast it finds the ink.
@Test(arguments: [EraserMode.precision, .stroke, .entireStroke])
func eraseSessionMatchesStraightforwardErasing(mode: EraserMode) {
  let page = denseTextPage(lines: 12, wordsPerLine: 6)
  var long = Stroke(samples: [Sample(point: Point(-500, 100)), Sample(point: Point(5000, 140))], width: 3)
  long.tool = .highlighter
  let strokes = page + [long]
  let path = (0..<120).map { i in Point(30 + Double(i) * 3.1, 40 + Double(i) * 2.2) }

  var expected = strokes
  for point in Editing.sweep(path, spacing: 5) {
    expected = Editing.erase(strokes: expected, at: point, radius: 10, mode: mode, highlighterOnly: false)
  }
  let actual = Editing.erase(strokes: strokes, along: path, radius: 10, mode: mode, highlighterOnly: false)
  #expect(actual.map(\.samples) == expected.map(\.samples))
  #expect(actual.count < strokes.count || mode == .precision)
}

@Test func eraseSessionReportsDirtyAreaAndRepaintStrokes() {
  var session = EraseSession(strokes: denseTextPage(lines: 4, wordsPerLine: 3))
  #expect(session.erase(at: Point(900, 900), radius: 10, mode: .stroke, highlighterOnly: false) == nil)
  let dirty = session.erase(at: Point(46, 58), radius: 10, mode: .stroke, highlighterOnly: false)
  #expect(dirty != nil)
  let nearby = session.strokes(reaching: Rect(x: 40, y: 50, width: 20, height: 20))
  #expect(nearby.count < session.strokes.count)
}
