import CoreGraphics
import Foundation
import NoteCraftCore
import PDFKit
import Testing

@testable import NoteCraft

private typealias Pixel = (r: Int, g: Int, b: Int)

// The top left 400 x 300 points of a page, one pixel per point.
@MainActor private func picture(of page: Page) -> (Int, Int) -> Pixel {
  let width = 400
  let height = 300
  var bytes = [UInt8](repeating: 0, count: width * height * 4)
  bytes.withUnsafeMutableBytes { raw in
    let c = CGContext(
      data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: Double(height))
    c.scaleBy(x: 1, y: -1)
    PageRenderer.render(page, assets: [:], in: c)
  }
  return { x, y in
    let at = (y * width + x) * 4
    return (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]))
  }
}

private func isDark(_ p: Pixel) -> Bool { p.r + p.g + p.b < 300 }
private func isPaper(_ p: Pixel) -> Bool { p.r > 245 && p.g > 245 && p.b > 245 }
// The yellow of the strips in these tests, or that yellow with a lighter pattern on it.
private func isTape(_ p: Pixel) -> Bool { p.r > 200 && p.g > 160 && p.b < 190 && p.r - p.b > 60 }

private func blankPage() -> Page { Page(paper: Paper(size: .a4, pattern: .blank)) }

private func line(_ a: Point, _ b: Point, width: Double = 6) -> Stroke {
  Stroke(samples: [Sample(point: a), Sample(point: b)], color: InkColor(red: 0, green: 0, blue: 0), width: width)
}

private func strip(
  _ a: Point, _ b: Point, width: Double = 24, pattern: TapePattern = .plain
) -> Stroke {
  Stroke.tape(along: [a, b], color: .yellow, width: width, pattern: pattern, straight: true)!
}

@MainActor @Test func aCoveredStripHidesInkAndAPeeledOneShowsIt() {
  var page = blankPage()
  page.strokes = [line(Point(60, 100), Point(260, 100)), strip(Point(50, 100), Point(270, 100))]
  let covered = picture(of: page)
  for x in stride(from: 60, through: 260, by: 10) {
    #expect(isTape(covered(x, 100)), "x \(x): \(covered(x, 100))")
  }
  #expect(isPaper(covered(160, 130)), "nothing is drawn beside the strip")

  page.toggleTape(at: Point(160, 100))
  let peeled = picture(of: page)
  #expect(isDark(peeled(160, 100)), "the ink can be read: \(peeled(160, 100))")
  // The strip is still there to tap: a tint where it lies, paper where it does not.
  let tint = peeled(160, 108)
  #expect(!isPaper(tint) && !isTape(tint) && tint.b < tint.r, "\(tint)")
  #expect(isPaper(peeled(160, 130)))
}

@MainActor @Test func tapeIsOnTopOfTextBoxesAndOfInkWrittenAfterItWasLaid() {
  var box = TextBox(origin: Point(60, 84), text: "MMMMMMMM")
  box.size = 28
  box.boxWidth = 300
  var open = blankPage()
  open.texts = [box]
  let text = picture(of: open)
  let inked = (60...200).contains { isDark(text($0, 100)) || isDark(text($0, 104)) }
  #expect(inked, "the text is where the strip will be")

  var page = open
  // The strip is first in the page's strokes; the line was written afterwards.
  page.strokes = [strip(Point(50, 100), Point(300, 100), width: 40), line(Point(60, 104), Point(290, 104))]
  let covered = picture(of: page)
  for y in [90, 100, 104, 112] {
    for x in stride(from: 56, through: 294, by: 2) {
      #expect(isTape(covered(x, y)), "(\(x), \(y)): \(covered(x, y))")
    }
  }
}

@MainActor @Test(arguments: [TapePattern.stripes, .dots, .checks])
func aPatternStaysInsideItsStripAndLeavesItsColour(pattern: TapePattern) {
  var page = blankPage()
  page.strokes = [strip(Point(50, 100), Point(350, 100), width: 30, pattern: pattern)]
  let image = picture(of: page)
  var shades = Set<Int>()
  for y in 87...113 {
    for x in 60...340 {
      let p = image(x, y)
      #expect(isTape(p), "(\(x), \(y)): \(p)")
      shades.insert(p.b / 16)
    }
  }
  #expect(shades.count > 1, "a pattern is lighter than the tape it is on")
  for x in stride(from: 40, through: 360, by: 8) {
    #expect(isPaper(image(x, 80)) && isPaper(image(x, 120)))
  }
}

@MainActor @Test func theEndsOfAStripAreCutInAZigzag() {
  var page = blankPage()
  page.strokes = [strip(Point(50, 100), Point(350, 100), width: 32)]
  let image = picture(of: page)
  // The last column of the strip: teeth and the notches between them.
  for x in [50, 349] {
    let taped = (85...115).filter { isTape(image(x, $0)) }.count
    #expect(taped > 2 && taped < 28, "x \(x): \(taped) of 31")
  }
  // A few points in, the strip is whole.
  #expect((85...115).allSatisfy { isTape(image(56, $0)) })
  #expect((85...115).allSatisfy { isPaper(image(46, $0)) })
}

@MainActor @Test func aStripAtAnAngleIsDrawnAlongItsPath() {
  var page = blankPage()
  page.strokes = [strip(Point(60, 60), Point(260, 260), width: 24, pattern: .stripes)]
  let image = picture(of: page)
  #expect(isTape(image(160, 160)))
  #expect(isTape(image(166, 154)))
  // The corners of its bounding box are paper.
  #expect(isPaper(image(240, 80)) && isPaper(image(80, 240)))
}

// MARK: the canvas

@MainActor private final class Recorder {
  var strokes: [Stroke] = []
  var taps: [Point] = []
}

@MainActor private func tapeCanvas(
  page: Page = blankPage(), straight: Bool = true, recorder: Recorder
) -> DrawingView {
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.input.backgroundCacheThreshold = .max
  view.configuration = CanvasConfiguration(
    page: page, assets: [:], tool: .tape, color: .yellow, width: 24, style: .ballpoint,
    pencilOnly: false, selection: [], onStroke: { recorder.strokes.append($0) },
    onGesture: { _ in }, onTap: { recorder.taps.append($0) }, tapePattern: .dots,
    straightTape: straight)
  return view
}

@MainActor @Test func aDragWithTheTapeToolLaysAStrip() throws {
  let recorder = Recorder()
  let view = tapeCanvas(recorder: recorder)
  for i in 0...20 {
    view.accept(Sample(point: Point(100 + Double(i) * 10, 200 + Double(i % 3))), time: 100 + Double(i) / 100)
  }
  view.finish()
  let tape = try #require(recorder.strokes.first)
  #expect(recorder.strokes.count == 1)
  #expect(recorder.taps.isEmpty)
  #expect(tape.tape == Tape(pattern: .dots, revealed: false))
  #expect(tape.tool == .pen, "stored as a pen stroke, so the page stays readable for older builds")
  #expect(tape.samples.map(\.point) == [Point(100, 200), Point(300, 200)])
  #expect(tape.color == .yellow && tape.width == 24)
  // The same stroke goes straight into the cached page when the model has it.
  #expect(view.input.pendingStroke == tape)
}

@MainActor @Test func aStripDrawnByHandFollowsThePen() throws {
  let recorder = Recorder()
  let view = tapeCanvas(straight: false, recorder: recorder)
  for i in 0...60 {
    let t = Double(i) / 60
    view.accept(Sample(point: Point(100 + 200 * t, 300 - 80 * sin(t * .pi))), time: 100 + t)
  }
  view.finish()
  let tape = try #require(recorder.strokes.first)
  #expect(tape.samples.count > 6)
  #expect(tape.isTape)
  #expect(abs((tape.samples.map(\.point.y).min() ?? 0) - 220) < 4)
}

@MainActor @Test func aTapWithTheTapeToolIsATapNotAStrip() {
  let recorder = Recorder()
  let view = tapeCanvas(recorder: recorder)
  view.accept(Sample(point: Point(150, 200)), time: 100)
  view.accept(Sample(point: Point(151, 201)), time: 100.02)
  view.finish()
  #expect(recorder.strokes.isEmpty)
  #expect(recorder.taps == [Point(150, 200)])
  #expect(view.input.pendingStroke == nil)
}

@MainActor @Test func inkWrittenAcrossAStripEndsUpUnderIt() throws {
  var page = blankPage()
  page.strokes = [strip(Point(50, 100), Point(270, 100))]
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.input.backgroundCacheThreshold = .max
  var configuration = CanvasConfiguration(
    page: page, assets: [:], tool: .pen, color: .ink, width: 6, style: .ballpoint,
    pencilOnly: false, selection: [], onStroke: { _ in }, onGesture: { _ in }, onTap: { _ in })
  view.configuration = configuration
  let width = 595
  let height = 842
  var bytes = [UInt8](repeating: 0, count: width * height * 4)
  func paint() {
    bytes.withUnsafeMutableBytes { raw in
      let c = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.translateBy(x: 0, y: Double(height))
      c.scaleBy(x: 1, y: -1)
      view.paint(configuration, c)
    }
  }
  func pixel(_ x: Int, _ y: Int) -> Pixel {
    let at = (y * width + x) * 4
    return (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]))
  }
  paint()
  let cache = try #require(view.cachedPage)

  // A stroke somewhere else is drawn straight into the cached page, as always.
  let away = line(Point(60, 400), Point(260, 400))
  view.input.pendingStroke = away
  configuration.page.strokes.append(away)
  view.configuration = configuration
  #expect(view.cachedPage === cache)

  // One across the strip cannot be: it has to go under the tape.
  let across = line(Point(160, 60), Point(160, 140))
  view.input.pendingStroke = across
  configuration.page.strokes.append(across)
  view.configuration = configuration
  #expect(view.cachedPage == nil)
  paint()
  #expect(isDark(pixel(160, 70)), "the line is there above the strip")
  #expect(isTape(pixel(160, 100)), "and hidden where the strip is: \(pixel(160, 100))")
  #expect(isDark(pixel(160, 400)))
}

@MainActor @Test func theCanvasSaysHowManyStripsThereAreAndHowManyStillCover() {
  var page = blankPage()
  page.strokes = [
    line(Point(60, 100), Point(260, 100)), strip(Point(50, 100), Point(270, 100)),
    strip(Point(50, 200), Point(270, 200)),
  ]
  #expect(CanvasConfiguration.accessibilitySummary(of: page) == "1 strokes, 2 tapes, 2 covered")
  page.toggleTape(at: Point(100, 200))
  #expect(CanvasConfiguration.accessibilitySummary(of: page) == "1 strokes, 2 tapes, 1 covered")
  page.removeTapes()
  #expect(CanvasConfiguration.accessibilitySummary(of: page) == "1 strokes")
}

// MARK: export

@MainActor @Test func anExportedPageHasItsTapeAsTheLastAnnotation() throws {
  var box = TextBox(origin: Point(60, 84), text: "Answer")
  box.boxWidth = 200
  var page = blankPage()
  page.texts = [box]
  // The strip first, ink after it: in the PDF the strip still comes last, over ink and text.
  page.strokes = [strip(Point(50, 100), Point(270, 100)), line(Point(60, 100), Point(260, 100))]
  func annotations(_ page: Page) throws -> [PDFAnnotation] {
    let data = try PDFEditor.export(NotebookPackage(notebook: Notebook(pages: [page])))
    return try #require(PDFDocument(data: data)?.page(at: 0)).annotations
  }
  let covered = try annotations(page)
  #expect(covered.count == 3)
  let last = try #require(covered.last)
  #expect(last.type == "Ink")
  #expect(last.border?.lineWidth == 24)
  #expect(last.color.cgColor.alpha > 0.99, "what is covered in the notebook is covered in the PDF")
  #expect(covered.first?.border?.lineWidth == 6)

  page.toggleTape(at: Point(100, 100))
  let peeled = try #require(try annotations(page).last)
  #expect(peeled.border?.lineWidth == 24)
}

// PDFKit reads an annotation's colour back without its alpha, so what a reader of the PDF sees is
// checked on the drawn page: a covered strip hides the line, a peeled one lets it through.
@MainActor @Test func anExportedPageShowsWhatTheNotebookShowsUnderItsTape() throws {
  var page = blankPage()
  page.strokes = [line(Point(60, 100), Point(260, 100)), strip(Point(50, 100), Point(270, 100))]
  func drawn(_ page: Page) throws -> (Int, Int) -> Pixel {
    let data = try PDFEditor.export(NotebookPackage(notebook: Notebook(pages: [page])))
    let pdfPage = try #require(PDFDocument(data: data)?.page(at: 0))
    let width = 595
    let height = 842
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    bytes.withUnsafeMutableBytes { raw in
      let c = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      pdfPage.draw(with: .mediaBox, to: c)
    }
    return { x, y in
      let at = (y * width + x) * 4
      return (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]))
    }
  }
  let covered = try drawn(page)
  #expect(isTape(covered(160, 100)), "\(covered(160, 100))")
  page.toggleTape(at: Point(100, 100))
  let peeled = try drawn(page)
  #expect(isDark(peeled(160, 100)), "the line can be read through a peeled strip: \(peeled(160, 100))")
  #expect(!isPaper(peeled(160, 108)) && !isTape(peeled(160, 108)), "\(peeled(160, 108))")
}

@MainActor @Test func aWhiteboardExportDrawsTheStripOverTheInk() throws {
  var page = blankPage()
  page.strokes = [line(Point(60, 100), Point(260, 100)), strip(Point(50, 100), Point(270, 100))]
  var notebook = Notebook(pages: [page])
  notebook.kind = .whiteboard
  let data = try PDFEditor.export(NotebookPackage(notebook: notebook))
  let document = try #require(PDFDocument(data: data))
  let pdfPage = try #require(document.page(at: 0))
  // Content bounds start 40 points before the content: the strip's middle is 52 points down.
  let bounds = pdfPage.bounds(for: .mediaBox)
  let width = Int(bounds.width)
  let height = Int(bounds.height)
  var bytes = [UInt8](repeating: 255, count: width * height * 4)
  bytes.withUnsafeMutableBytes { raw in
    let c = CGContext(
      data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    pdfPage.draw(with: .mediaBox, to: c)
  }
  let at = (52 * width + width / 2) * 4
  let middle: Pixel = (Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]))
  #expect(isTape(middle), "\(middle)")
}
