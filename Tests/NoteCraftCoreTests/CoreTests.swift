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

@Test func scribbleErasesIntersectedInkButKeepsOrdinaryHandwriting() {
  let scratch = (0...8).map { Point($0.isMultiple(of: 2) ? 20 : 100, 30 + Double($0) * 4) }
  let target = Stroke(samples: [Sample(point: Point(60, 0)), Sample(point: Point(60, 100))])
  let other = Stroke(samples: [Sample(point: Point(200, 0)), Sample(point: Point(200, 100))])
  #expect(InkGestures.isScratch(scratch))
  #expect(InkGestures.scratchTargets(scratch, strokes: [target, other]) == [target.id])
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
