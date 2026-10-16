import Foundation
import Testing

@testable import NoteCraftCore

@Test func packageRoundTrip() throws {
  var page = Page()
  page.strokes = [Stroke(samples: [Sample(point: Point(10, 20), pressure: 0.4)])]
  page.images = [PageAsset(filename: "image.png", frame: Rect(x: 10, y: 10, width: 50, height: 50))]
  let original = NotebookPackage(
    notebook: Notebook(title: "Physics", pages: [page]), assets: ["image.png": Data([1, 2, 3])])
  let decoded = try NotebookPackage(fileWrapper: original.fileWrapper())
  #expect(decoded.notebook == original.notebook)
  #expect(decoded.assets == original.assets)
}
@Test func rejectsMissingAssetsAndTraversal() throws {
  var page = Page()
  page.backgroundPDF = "missing.pdf"
  #expect(throws: PackageError.self) {
    try NotebookPackage(notebook: Notebook(pages: [page])).fileWrapper()
  }
  #expect(throws: PackageError.self) {
    try NotebookPackage(assets: ["../escape": Data()]).fileWrapper()
  }
}
@Test func transformRoundTrip() {
  let t = ViewTransform(scale: 2.4, offset: Point(20, -18))
  let p = Point(40, 82)
  #expect(t.documentPoint(t.viewPoint(p)).distance(to: p) < 0.00001)
}
@Test func spatialQueriesMatchBruteForce() {
  let strokes = (0..<300).map { i in
    Stroke(samples: [Sample(point: Point(Double(i % 20) * 20, Double(i / 20) * 20))])
  }
  let index = SpatialIndex(strokes: strokes, bounds: Rect(x: 0, y: 0, width: 600, height: 800))
  for i in 0..<50 {
    let r = Rect(x: Double(i * 7), y: Double(i * 3), width: 55, height: 70)
    #expect(
      Set(index.query(r).map(\.id)) == Set(strokes.filter { $0.bounds.intersects(r) }.map(\.id)))
  }
}
@Test func lassoAndPrecisionErasure() {
  let s = Stroke(samples: (0...10).map { Sample(point: Point(Double($0) * 10, 50)) })
  let polygon = [Point(0, 0), Point(120, 0), Point(120, 100), Point(0, 100)]
  #expect(
    Editing.selection(
      strokes: [s], polygon: polygon, bounds: Rect(x: 0, y: 0, width: 600, height: 800)) == [s.id])
  let split = Editing.erase(
    strokes: [s], at: Point(50, 50), radius: 12, mode: .precision, highlighterOnly: false)
  #expect(split.count == 2)
  #expect(split.allSatisfy { $0.samples.allSatisfy { $0.point.distance(to: Point(50, 50)) > 13 } })
  #expect(
    Editing.erase(strokes: [s], at: Point(50, 50), radius: 12, mode: .stroke, highlighterOnly: true)
      == [s])
}
@Test func coordinatedSaveAndConflict() async throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".notecraft")
  defer { try? FileManager.default.removeItem(at: url) }
  let store = PackageStore()
  var package = NotebookPackage()
  try await store.save(package, to: url)
  package.notebook.revision = 1
  try await store.save(package, to: url, expectedRevision: 0)
  let read = try await store.read(from: url)
  #expect(read.notebook.revision == 1)
  await #expect(throws: PackageError.self) {
    try await store.save(package, to: url, expectedRevision: 0)
  }
}

@Test func sparseSegmentsCanBeSelectedAndErased() {
  let stroke = Stroke(samples: [Sample(point: Point(0, 50)), Sample(point: Point(200, 50))])
  let polygon = [Point(80, 30), Point(120, 30), Point(120, 70), Point(80, 70)]
  #expect(Editing.strokeIntersects(stroke, polygon: polygon))
  let segments = Editing.erase(
    strokes: [stroke], at: Point(100, 50), radius: 10, mode: .precision, highlighterOnly: false)
  #expect(segments.count == 2)
  #expect(
    segments.allSatisfy { $0.samples.allSatisfy { $0.point.distance(to: Point(100, 50)) > 11 } })
  #expect(
    Editing.erase(
      strokes: [stroke], at: Point(100, 50), radius: 10, mode: .entireStroke, highlighterOnly: false
    ).isEmpty)
}
@Test func rejectsFutureVersionAndEmptyNotebook() throws {
  let future = FileWrapper(directoryWithFileWrappers: [
    "manifest.json": FileWrapper(
      regularFileWithContents: Data(
        "{\"version\":42,\"notebook\":{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"Future\",\"pages\":[],\"revision\":0}}"
          .utf8))
  ])
  #expect(throws: PackageError.self) { try NotebookPackage(fileWrapper: future) }
  #expect(throws: PackageError.self) {
    try NotebookPackage(notebook: Notebook(pages: [])).fileWrapper()
  }
}

@Test func concurrentWritersCannotOverwriteSameRevision() async throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".notecraft")
  defer { try? FileManager.default.removeItem(at: url) }
  try await PackageStore().save(NotebookPackage(), to: url)
  var a = NotebookPackage()
  a.notebook.revision = 1
  a.notebook.title = "Writer A"
  var b = a
  b.notebook.title = "Writer B"
  let snapshots = [a, b]
  let successes = await withTaskGroup(of: Bool.self) { group in
    for package in snapshots {
      group.addTask {
        do {
          try await PackageStore().save(package, to: url, expectedRevision: 0)
          return true
        } catch { return false }
      }
    }
    var results: [Bool] = []
    for await result in group { results.append(result) }
    return results.filter { $0 }.count
  }
  #expect(successes == 1)
  #expect(try await PackageStore().read(from: url).notebook.revision == 1)
}
@Test func hexColorsAndTextGeometry() {
  #expect(InkColor(hex: "#FF0000") == InkColor(red: 1, green: 0, blue: 0))
  #expect(InkColor(hex: "oops") == nil)
  var text = TextBox(
    origin: Point(20, 20), text: "A long line that wraps across several rows in a small box.")
  text.boxWidth = 80
  #expect(text.bounds.height > text.size * 3)
}

@Test func shapeRecognitionPreservesTrianglesAndSnapsLines() {
  let triangle = Stroke(
    samples: [Point(50, 20), Point(100, 100), Point(0, 100), Point(50, 20)].map {
      Sample(point: $0)
    }, tool: .shapes)
  #expect(Editing.shape(from: triangle).samples.count <= 5)
  let line = Stroke(
    samples: [Point(0, 0), Point(20, 4), Point(80, 2)].map { Sample(point: $0) }, tool: .shapes)
  #expect(Editing.shape(from: line).samples.count == 2)
}

@Test func heldCircleIsRoundAndResizesWithoutMovingItsCenter() throws {
  let raw = Stroke(
    samples: (0...48).map { i in
      let angle = Double(i) / 48 * 2 * Double.pi
      return Sample(point: Point(100 + 42 * cos(angle), 110 + 38 * sin(angle)))
    })
  let circle = try #require(InkGestures.heldShape(raw))
  #expect(abs(circle.bounds.width - circle.bounds.height) < 0.001)
  let resized = InkGestures.resizeHeldShape(circle, from: Point(140, 110), to: Point(180, 110))
  #expect(
    abs((resized.bounds.width - resized.width) / (circle.bounds.width - circle.width) - 2) < 0.01)
  #expect(abs(resized.bounds.x + resized.bounds.width / 2 - 100) < 0.01)
  let curve = Stroke(
    samples: (0..<20).map { Sample(point: Point(Double($0) * 5, sin(Double($0) * 0.3) * 30)) })
  #expect(InkGestures.heldShape(curve) == nil)
}

@Test func scribbleErasesIntersectedInkButKeepsOrdinaryHandwriting() throws {
  let scratch = (0...8).map { Point($0.isMultiple(of: 2) ? 20 : 100, 30 + Double($0) * 4) }
  let target = Stroke(samples: [Sample(point: Point(60, 0)), Sample(point: Point(60, 100))])
  let other = Stroke(samples: [Sample(point: Point(200, 0)), Sample(point: Point(200, 100))])
  #expect(InkGestures.isScratch(scratch))
  let cutThrough = try #require(InkGestures.scratchOutcome(scratch, strokes: [target, other]))
  #expect(cutThrough.strokes.contains(other), "ink away from the scribble stays")
  #expect(!cutThrough.strokes.contains(target), "the line is cut, not left as it was")
  let neighbour = Stroke(
    samples: [Sample(point: Point(10, 78)), Sample(point: Point(110, 78))], width: 2)
  let highlight = Stroke(
    samples: [Sample(point: Point(60, 0)), Sample(point: Point(60, 100))], width: 14,
    tool: .highlighter)
  #expect(
    InkGestures.scratchOutcome(scratch, strokes: [neighbour, highlight]) == nil,
    "Scribbling must not erase an adjacent line or highlighter underneath")
  let circle = (0...64).map {
    Point(50 + 30 * cos(Double($0) / 64 * 2 * .pi), 50 + 30 * sin(Double($0) / 64 * 2 * .pi))
  }
  #expect(!InkGestures.isScratch(circle))
  #expect(!InkGestures.isScratch([Point(0, 0), Point(100, 0)]))
}

@Test func lassoTranslationMovesSelectedObjectsTogetherAndPreservesOthers() {
  var page = Page()
  let stroke = Stroke(samples: [Sample(point: Point(20, 30)), Sample(point: Point(60, 80))])
  let other = Stroke(samples: [Sample(point: Point(300, 400))])
  let text = TextBox(origin: Point(30, 50), text: "Keep formatting")
  let image = PageAsset(filename: "image.png", frame: Rect(x: 60, y: 90, width: 100, height: 80))
  page.strokes = [stroke, other]
  page.texts = [text]
  page.images = [image]
  let ids: Set<UUID> = [stroke.id, text.id, image.id]
  #expect(InkGestures.selectionContains(Point(40, 60), page: page, ids: ids))
  #expect(!InkGestures.selectionContains(Point(400, 500), page: page, ids: ids))
  let changed = InkGestures.translate(page, ids: ids, by: Point(-12, 24))
  #expect(changed.strokes[0].samples[0].point == Point(8, 54))
  #expect(changed.texts[0].origin == Point(18, 74))
  #expect(changed.images[0].frame.x == 48)
  #expect(changed.images[0].frame.y == 114)
  #expect(changed.images[0].frame.width == image.frame.width)
  #expect(changed.strokes[1] == other)
  #expect(changed.id == page.id)
}

@Test func continuedPageCopiesPaperAndPDFDimensionsWithoutCopyingContent() {
  var previous = Page(paper: Paper(size: .letter, pattern: .dotted, landscape: true))
  previous.backgroundPDF = "original.pdf"
  previous.backgroundSize = Point(900, 1200)
  previous.strokes = [Stroke(samples: [Sample(point: Point(20, 30))])]
  let next = InkGestures.blankPage(matching: previous)
  #expect(next.id != previous.id)
  #expect(next.paper == previous.paper)
  #expect(next.dimensions == previous.dimensions)
  #expect(next.backgroundPDF == nil)
  #expect(next.strokes.isEmpty)
}

@Test func groupTransformsRotateAndScaleImagesAndTextAroundTheSameCenter() throws {
  var page = Page()
  let stroke = Stroke(
    samples: [Sample(point: Point(10, 0)), Sample(point: Point(30, 0))], width: 2)
  let image = PageAsset(filename: "image.png", frame: Rect(x: 10, y: 10, width: 20, height: 10))
  var text = TextBox(origin: Point(10, 30), text: "Rotate me")
  text.boxWidth = 100
  page.strokes = [stroke]
  page.images = [image]
  page.texts = [text]
  let ids: Set<UUID> = [stroke.id, image.id, text.id]
  let transform = SelectionTransform(
    center: Point(0, 0), scale: 2, angle: .pi / 2,
    translation: Point(100, 100))
  let changed = InkGestures.transform(page, ids: ids, by: transform)
  #expect(abs(changed.strokes[0].samples[0].point.x - 100) < 0.0001)
  #expect(abs(changed.strokes[0].samples[0].point.y - 120) < 0.0001)
  #expect(changed.strokes[0].width == 4)
  #expect(abs(changed.images[0].frame.x + changed.images[0].frame.width / 2 - 70) < 0.0001)
  #expect(abs(changed.images[0].frame.y + changed.images[0].frame.height / 2 - 140) < 0.0001)
  #expect(changed.images[0].rotation == .pi / 2)
  #expect(changed.texts[0].rotation == .pi / 2)
  #expect(changed.texts[0].size == 40)
  #expect(changed.texts[0].boxWidth == 200)
  #expect(abs(changed.texts[0].bounds.height - 200) < 0.0001)
  let package = NotebookPackage(
    notebook: Notebook(pages: [changed]), assets: ["image.png": Data([1])])
  let decoded = try NotebookPackage(fileWrapper: package.fileWrapper())
  #expect(decoded.notebook.pages[0].texts[0].rotation == .pi / 2)
  #expect(decoded.notebook.pages[0].images[0].contains(Point(70, 140)))
  #expect(!decoded.notebook.pages[0].images[0].contains(Point(200, 300)))
}

@Test func reusableElementsPreserveAllObjectTypesAndNeverOverwriteAssets() throws {
  var page = Page()
  let stroke = Stroke(samples: [Sample(point: Point(50, 60))])
  var text = TextBox(origin: Point(60, 70), text: "Reusable text")
  text.rotation = .pi / 4
  let image = PageAsset(filename: "same.png", frame: Rect(x: 100, y: 100, width: 30, height: 40))
  page.strokes = [stroke]
  page.texts = [text]
  page.images = [image]
  let ids: Set<UUID> = [stroke.id, text.id, image.id]
  let clip = try ElementClip.capture(
    title: "Mixed clip", page: page, ids: ids,
    assets: ["same.png": Data([1, 2, 3])])
  let decoded = try JSONDecoder().decode(ElementClip.self, from: JSONEncoder().encode(clip))
  #expect(decoded == clip)
  var package = NotebookPackage(assets: ["same.png": Data([9])])
  try decoded.insert(into: &package, pageIndex: 0, at: Point(200, 300))
  try decoded.insert(into: &package, pageIndex: 0, at: Point(400, 500))
  let result = package.notebook.pages[0]
  #expect(result.strokes.count == 2 && result.texts.count == 2 && result.images.count == 2)
  #expect(result.strokes[0].id != result.strokes[1].id)
  #expect(result.texts[0].rotation == .pi / 4)
  #expect(result.images[0].filename != result.images[1].filename)
  #expect(package.assets["same.png"] == Data([9]))
  #expect(package.assets[result.images[0].filename] == Data([1, 2, 3]))
  let duplicate = InkGestures.duplicatePage(result)
  #expect(duplicate.id != result.id)
  #expect(duplicate.strokes[0].id != result.strokes[0].id)
  #expect(duplicate.images[0].filename == result.images[0].filename)
}

@Test func magneticPagingMovesAtMostOnePageAndClampsAtEdges() {
  #expect(
    NotebookPaging.target(
      origin: 1600, projected: 3200, velocity: 0,
      pageWidth: 800, contentWidth: 4000) == 3200)
  #expect(
    NotebookPaging.target(
      origin: 800, projected: 3300, velocity: 2000,
      pageWidth: 800, contentWidth: 4000) == 1600)
  #expect(
    NotebookPaging.target(
      origin: 800, projected: 500, velocity: -500,
      pageWidth: 800, contentWidth: 4000) == 0)
  #expect(
    NotebookPaging.target(
      origin: 800, projected: 850, velocity: 0,
      pageWidth: 800, contentWidth: 4000) == 800)
  #expect(
    NotebookPaging.target(
      origin: 3200, projected: 3800, velocity: 500,
      pageWidth: 800, contentWidth: 4000) == 3200)
  #expect(
    NotebookPaging.target(
      origin: 0, projected: -800, velocity: -500,
      pageWidth: 800, contentWidth: 4000) == 0)
}

@Test func explicitShapeToolsCreateClosedGeometryAndPreserveInkAttributes() {
  let raw = Stroke(
    samples: [Sample(point: Point(30, 50)), Sample(point: Point(100, 120))],
    color: .red, width: 3, tool: .shapes)
  for preset in [ShapePreset.rectangle, .ellipse, .triangle, .diamond] {
    let result = Editing.shape(from: raw, preset: preset)
    #expect(result.samples.first?.point == result.samples.last?.point)
    #expect(result.color == raw.color && result.width == raw.width && result.id == raw.id)
    #expect(result.samples.count >= 4)
  }
  #expect(Editing.shape(from: raw, preset: .line).samples == raw.samples)
}

@Test func smallScribbleErasesOnlyTheScrubbedLetter() throws {
  func letter(_ x: Double) -> Stroke {
    Stroke(samples: [Sample(point: Point(x, 0)), Sample(point: Point(x, 12))], width: 1.5)
  }
  let left = letter(0)
  let middle = letter(14)
  let right = letter(28)
  let scrub = (0..<8).map { Point($0.isMultiple(of: 2) ? 9 : 19, Double($0) * 1.7) }
  #expect(InkGestures.isScratch(scrub), "A short scrub over one letter must be recognised")
  let result = try #require(InkGestures.scratchOutcome(scrub, strokes: [left, middle, right]))
  #expect(result.strokes.map(\.id) == [left.id, right.id])
  #expect(result.certainty == .clear)
}

@Test func scribbleOnALongLineCutsOutOnlyTheScrubbedPart() throws {
  let underline = Stroke(
    samples: [Sample(point: Point(-50, 6)), Sample(point: Point(100, 6))], width: 2)
  let lineAbove = Stroke(
    samples: [Sample(point: Point(-50, -14)), Sample(point: Point(100, -14))], width: 2)
  let lineBelow = Stroke(
    samples: [Sample(point: Point(-50, 26)), Sample(point: Point(100, 26))], width: 2)
  // Back and forth across the underline, a little loose in height.
  let scrub = (0..<9).map { Point($0.isMultiple(of: 2) ? 0 : 30, 6 + ($0.isMultiple(of: 2) ? -4 : 4)) }
  let result = try #require(
    InkGestures.scratchOutcome(scrub, strokes: [lineAbove, underline, lineBelow]))
  #expect(result.strokes.first == lineAbove && result.strokes.last == lineBelow)
  let pieces = Array(result.strokes.dropFirst().dropLast())
  #expect(pieces.count == 2, "the underline is split, not removed")
  let left = try #require(pieces.first)
  let right = try #require(pieces.last)
  #expect(left.bounds.x < -45 && left.bounds.x + left.bounds.width < 0)
  #expect(right.bounds.x > 28 && right.bounds.x + right.bounds.width > 95)
  #expect(result.certainty == .doubtful, "cutting through long ink is a close call")
}

@Test func strokesMostlyInsideTheScribbleGoEntirelyEvenWhereTheyStickOut() throws {
  // Scrub over x 0…60 along y = 20. A word 70 wide has 94 % inside: it goes whole.
  let scrub = (0..<9).map { Point($0.isMultiple(of: 2) ? 0 : 60, $0.isMultiple(of: 2) ? 17 : 23) }
  let word = Stroke(samples: [Sample(point: Point(-5, 20)), Sample(point: Point(65, 20))])
  // About 65 of 100 inside is below 80 %, but it is crossed on every sweep: only that part goes.
  let rule = Stroke(samples: [Sample(point: Point(-20, 20)), Sample(point: Point(80, 20))])
  let tight = try #require(InkGestures.scratchOutcome(scrub, strokes: [word]))
  #expect(tight.strokes.isEmpty)
  let loose = try #require(InkGestures.scratchOutcome(scrub, strokes: [word, rule]))
  #expect(loose.strokes.count == 2 && !loose.strokes.contains(word))
  #expect(loose.strokes.allSatisfy { $0.samples.count > 1 && $0.id != rule.id })
}

@Test func aLooseScribbleReachesInkBetweenItsSweepsButASmallOneStaysPrecise() throws {
  // Coarse scribble: sweeps 14 apart. A short stroke between two sweeps is still inside.
  let coarse = (0..<9).map { Point($0.isMultiple(of: 2) ? 0 : 80, Double($0) * 14) }
  let between = Stroke(samples: [Sample(point: Point(40, 21)), Sample(point: Point(40, 35))], width: 1.5)
  let result = try #require(InkGestures.scratchOutcome(coarse, strokes: [between]))
  #expect(result.strokes.isEmpty)
  // Fine scrub in place: a stroke 7 pt to the side is out of reach.
  let fine = (0..<9).map { Point($0.isMultiple(of: 2) ? 9 : 19, Double($0) * 1.5) }
  let hit = Stroke(samples: [Sample(point: Point(14, 0)), Sample(point: Point(14, 12))], width: 1.5)
  let near = Stroke(samples: [Sample(point: Point(28, 0)), Sample(point: Point(28, 12))], width: 1.5)
  let precise = try #require(InkGestures.scratchOutcome(fine, strokes: [hit, near]))
  #expect(precise.strokes == [near])
}

@Test func aLooseScribbleAcrossOnlyALongLineStaysInk() {
  let wire = Stroke(samples: [Sample(point: Point(0, 50)), Sample(point: Point(400, 50))], width: 2)
  // Four reversals: how a resistor or source symbol across a wire looks.
  let symbol = (0..<6).map { Point($0.isMultiple(of: 2) ? 194 : 206, $0.isMultiple(of: 2) ? 35 : 65) }
  #expect(InkGestures.isScratch(symbol))
  #expect(InkGestures.scratchOutcome(symbol, strokes: [wire]) == nil)
  // A dense scrub in the same place is unmistakable: it cuts, and says it was a close call.
  let dense = (0..<12).map { Point($0.isMultiple(of: 2) ? 194 : 206, $0.isMultiple(of: 2) ? 35 : 65) }
  let cut = InkGestures.scratchOutcome(dense, strokes: [wire])
  #expect(cut?.strokes.count == 2)
  #expect(cut?.certainty == .doubtful)
}

@Test func onlyCloseCallsAreReportedAsDoubtful() throws {
  let letter = Stroke(samples: [Sample(point: Point(14, 0)), Sample(point: Point(14, 12))], width: 1.5)
  let scrub = (0..<9).map { Point($0.isMultiple(of: 2) ? 9 : 19, Double($0) * 1.5) }
  #expect(try #require(InkGestures.scratchOutcome(scrub, strokes: [letter])).certainty == .clear)
  // About 85 % of this stroke lies under the scribble: erased, but a close call.
  let long = Stroke(samples: [Sample(point: Point(14, 0)), Sample(point: Point(14, 18.5))], width: 1.5)
  let result = try #require(InkGestures.scratchOutcome(scrub, strokes: [long]))
  #expect(result.strokes.isEmpty)
  #expect(result.certainty == .doubtful)
}

@Test func theTipOfAScribbleGrazingANeighbourDoesNotEraseIt() throws {
  let target = Stroke(samples: [Sample(point: Point(0, 0)), Sample(point: Point(0, 40))], width: 2)
  // The scribble runs over x = -8…8, its extreme sweep dips to touch a line at y = 46.
  let scrub = (0..<9).map { Point($0.isMultiple(of: 2) ? -8 : 8, Double($0) * 4) }
  let graze = Stroke(samples: [Sample(point: Point(-30, 34)), Sample(point: Point(30, 34))], width: 2)
  let result = try #require(InkGestures.scratchOutcome(scrub, strokes: [target, graze]))
  #expect(result.strokes == [graze], "only the vertical line under the pen goes")
}

@Test func twoQuickPassesBackAndForthOverInkErasesIt() throws {
  // Right, left, right, left: three reversals along the same line, the way a quick scrub looks.
  let xs: [Double] = [10, 50, 90, 50, 10, 50, 90, 50, 10]
  let scrub = xs.enumerated().map { Point($0.element, 40 + ($0.offset.isMultiple(of: 2) ? 0 : 3)) }
  let word = Stroke(samples: [Sample(point: Point(10, 40)), Sample(point: Point(90, 41))])
  let other = Stroke(samples: [Sample(point: Point(10, 120)), Sample(point: Point(90, 120))])
  #expect(InkGestures.isScratch(scrub))
  let result = try #require(InkGestures.scratchOutcome(scrub, strokes: [word, other]))
  #expect(result.strokes == [other])
  #expect(result.certainty == .doubtful, "three reversals is the weakest scribble that counts")
  // A single pass there and back is a stroke, not a scribble.
  #expect(!InkGestures.isScratch([Point(10, 40), Point(90, 40), Point(10, 41)]))
  // A zigzag "W" has reversals too, but does not run over itself enough to count.
  #expect(!InkGestures.isScratch([Point(0, 0), Point(15, 40), Point(30, 0), Point(45, 40), Point(60, 0)]))
}

@Test func handwritingThatDoesNotDoubleBackIsNotAScribble() {
  let wave = (0..<40).map { Point(Double($0) * 3, 10 + sin(Double($0) * 0.5) * 6) }
  #expect(!InkGestures.isScratch(wave))
  #expect(InkGestures.scratchOutcome(wave, strokes: []) == nil)
}

@Test func scribblingErasesSmallDotsWithoutTouchingNearbyInk() throws {
  let dot = Stroke(samples: [Sample(point: Point(50, 50))], width: 2.5)
  let twoSampleDot = Stroke(
    samples: [Sample(point: Point(80, 50)), Sample(point: Point(80.4, 50.3))], width: 2.5)
  let letter = Stroke(
    samples: [Sample(point: Point(66, 40)), Sample(point: Point(66, 60))], width: 2)
  let farLetter = Stroke(
    samples: [Sample(point: Point(100, 40)), Sample(point: Point(100, 60))], width: 2)
  // A 9 pt scrub around the dot, offset by a couple of points as a hand would.
  func scrub(around c: Point) -> [Point] {
    (0..<9).map { Point(c.x + ($0.isMultiple(of: 2) ? -4 : 4) + 1, c.y - 4 + Double($0)) }
  }
  #expect(InkGestures.isScratch(scrub(around: dot.samples[0].point)))
  let first = try #require(
    InkGestures.scratchOutcome(
      scrub(around: dot.samples[0].point), strokes: [dot, twoSampleDot, letter, farLetter]))
  #expect(first.strokes.map(\.id) == [twoSampleDot.id, letter.id, farLetter.id])
  let second = try #require(
    InkGestures.scratchOutcome(
      scrub(around: twoSampleDot.samples[0].point), strokes: [twoSampleDot, letter, farLetter]))
  #expect(second.strokes.map(\.id) == [letter.id, farLetter.id])
}

@Test func danglingImageReferencesAreDroppedSoSavingKeepsWorking() throws {
  var page = Page(paper: Paper(pattern: .blank))
  page.strokes = [Stroke(samples: [Sample(point: Point(1, 1)), Sample(point: Point(9, 9))])]
  page.images = [
    PageAsset(filename: "kept.image", frame: Rect(x: 0, y: 0, width: 10, height: 10)),
    PageAsset(filename: "gone.image", frame: Rect(x: 20, y: 0, width: 10, height: 10)),
  ]
  var package = NotebookPackage(
    notebook: Notebook(pages: [page]), assets: ["kept.image": Data([1, 2, 3])])
  #expect(throws: PackageError.self) { try package.fileWrapper() }
  #expect(package.pruneMissingAssets() == ["gone.image"])
  let restored = try NotebookPackage(fileWrapper: package.fileWrapper())
  #expect(restored.notebook.pages[0].images.map(\.filename) == ["kept.image"])
  #expect(restored.notebook.pages[0].strokes.count == 1)
  #expect(package.pruneMissingAssets().isEmpty)
}

@Test func infiniteScrollingAppendsABlankPageOnlyAfterTheLastPageHasContent() throws {
  var first = Page(paper: Paper(pattern: .ruled))
  #expect(InkGestures.blankPageNeeded(after: [first]) == nil)
  first.strokes = [Stroke(samples: [Sample(point: Point(5, 5))])]
  let next = try #require(InkGestures.blankPageNeeded(after: [first]))
  #expect(next.id != first.id && next.strokes.isEmpty)
  #expect(next.paper == first.paper && next.dimensions == first.dimensions)
  #expect(InkGestures.blankPageNeeded(after: [first, next]) == nil)
  var pdf = Page(paper: Paper(pattern: .blank))
  pdf.backgroundPDF = "source.pdf"
  #expect(InkGestures.blankPageNeeded(after: [pdf]) != nil)
  #expect(InkGestures.blankPageNeeded(after: []) == nil)
}

@Test func fountainWidthsRespondToPressureSpeedAndEndsDeterministically() {
  func line(spacing: Double, pressure: Double, count: Int = 40) -> [Sample] {
    (0..<count).map { Sample(point: Point(Double($0) * spacing, 0), pressure: pressure) }
  }
  let tip = PenTip(sharpness: 0.5, pressure: 0.5, flatness: 0)
  let slow = FountainInk.widths(for: line(spacing: 0.5, pressure: 0.3), base: 3, tip: tip)
  let fast = FountainInk.widths(for: line(spacing: 8, pressure: 0.3), base: 3, tip: tip)
  #expect(fast[20] < slow[20], "Faster strokes must be thinner")
  let light = FountainInk.widths(for: line(spacing: 1, pressure: 0.05), base: 3, tip: tip)
  let firm = FountainInk.widths(for: line(spacing: 1, pressure: 0.7), base: 3, tip: tip)
  #expect(firm[20] > light[20], "Harder pressure must be thicker")
  let blind = PenTip(sharpness: 0.5, pressure: 0, flatness: 0)
  let a = FountainInk.widths(for: line(spacing: 1, pressure: 0.05), base: 3, tip: blind)
  let b = FountainInk.widths(for: line(spacing: 1, pressure: 0.7), base: 3, tip: blind)
  #expect(abs(a[20] - b[20]) < 0.001, "Zero sensitivity ignores pressure")
  let constant = FountainInk.widths(for: line(spacing: 1, pressure: 1), base: 3, tip: tip)
  #expect(abs(constant[20] - FountainInk.widths(for: line(spacing: 1, pressure: 1), base: 3, tip: PenTip(sharpness: 0.5, pressure: 1, flatness: 0))[20]) < 0.001, "Pressure 1 means no pressure data")
  #expect(slow[0] < slow[20] && slow.last! < slow[20], "Ink enters and leaves tapered")
  var state = FountainInk.State()
  let samples = line(spacing: 2, pressure: 0.4)
  let incremental = samples.map { FountainInk.advance(&state, sample: $0, base: 3, tip: tip) }
  let batch = FountainInk.widths(for: samples, base: 3, tip: tip, finished: false)
  #expect(incremental == batch, "Live widths must equal the committed ones before the end taper")
  let flat = PenTip(sharpness: 0.5, pressure: 0.5, flatness: 1)
  let diagonal = (0..<40).map { Sample(point: Point(Double($0), Double($0)), pressure: 0.3) }
  let anti = (0..<40).map { Sample(point: Point(Double($0), -Double($0)), pressure: 0.3) }
  #expect(
    FountainInk.widths(for: anti, base: 3, tip: flat)[20]
      != FountainInk.widths(for: diagonal, base: 3, tip: flat)[20],
    "A flat nib draws differently along and across its edge")
}

@Test func strokeTipRoundTripsAndOlderFilesStillDecode() throws {
  let tip = PenTip(sharpness: 0.8, pressure: 0.3, flatness: 0.6)
  let stroke = Stroke(
    samples: [Sample(point: Point(1, 2))], style: .fountain, tip: tip)
  let decoded = try JSONDecoder().decode(Stroke.self, from: JSONEncoder().encode(stroke))
  #expect(decoded.tip == tip)
  var legacy = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(stroke)) as? [String: Any])
  legacy.removeValue(forKey: "tip")
  let old = try JSONDecoder().decode(
    Stroke.self, from: JSONSerialization.data(withJSONObject: legacy))
  #expect(old.tip == nil)
}

@Test func fastEraserSwipeDoesNotSkipInkBetweenSamples() {
  let rung = Stroke(samples: [Sample(point: Point(100, 0)), Sample(point: Point(100, 40))], width: 2)
  // Two samples 200 pt apart with an 8 pt eraser: a point-only test would jump over the stroke.
  let result = Editing.erase(
    strokes: [rung], along: [Point(0, 20), Point(200, 20)], radius: 8, mode: .stroke,
    highlighterOnly: false)
  #expect(result.isEmpty)
}

@Test func eraserOverADensePageStaysFast() {
  var strokes: [Stroke] = []
  for i in 0..<3000 {
    let x = Double(i % 60) * 12
    let y = Double(i / 60) * 14
    strokes.append(
      Stroke(samples: (0..<40).map { Sample(point: Point(x + Double($0) * 0.2, y + sin(Double($0)) * 3)) }))
  }
  let path = (0..<400).map { Point(Double($0) * 1.8, 300 + sin(Double($0) / 20) * 40) }
  let start = ContinuousClock.now
  let result = Editing.erase(
    strokes: strokes, along: path, radius: 10, mode: .stroke, highlighterOnly: false)
  let elapsed = ContinuousClock.now - start
  #expect(result.count < strokes.count)
  #expect(elapsed < .milliseconds(400), "took \(elapsed)")
}

@Test func scribbleOverAPageWithUntouchedStrokesDoesNotTrap() throws {
  // A stroke whose bounds overlap the scribble but whose segments never touch it used to
  // overflow an Int subtraction and crash the app.
  let nearMiss = Stroke(samples: [Sample(point: Point(0, 0)), Sample(point: Point(200, 0))])
  let target = Stroke(samples: [Sample(point: Point(40, 0)), Sample(point: Point(40, 80))])
  let scribble = (0..<400).map { i -> Point in
    let phase = (Double(i) / 50).truncatingRemainder(dividingBy: 2)
    return Point(10 + (phase < 1 ? phase : 2 - phase) * 60, 20 + Double(i) * 0.1)
  }
  let result = try #require(InkGestures.scratchOutcome(scribble, strokes: [nearMiss, target]))
  #expect(result.strokes.first == nearMiss)
  #expect(result.strokes.count == 3 && !result.strokes.contains(target), "the crossed line is cut")
}
