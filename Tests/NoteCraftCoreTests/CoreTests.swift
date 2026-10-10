import Foundation
import Testing
@testable import NoteCraftCore

@Test func packageRoundTrip() throws {
    var page = Page(); page.strokes = [Stroke(samples: [Sample(point: Point(10, 20), pressure: 0.4)])]
    page.images = [PageAsset(filename: "image.png", frame: Rect(x: 10, y: 10, width: 50, height: 50))]
    let original = NotebookPackage(notebook: Notebook(title: "Physics", pages: [page]), assets: ["image.png": Data([1, 2, 3])])
    let decoded = try NotebookPackage(fileWrapper: original.fileWrapper())
    #expect(decoded.notebook == original.notebook); #expect(decoded.assets == original.assets)
}
@Test func rejectsMissingAssetsAndTraversal() throws {
    var page = Page(); page.backgroundPDF = "missing.pdf"
    #expect(throws: PackageError.self) { try NotebookPackage(notebook: Notebook(pages: [page])).fileWrapper() }
    #expect(throws: PackageError.self) { try NotebookPackage(assets: ["../escape": Data()]).fileWrapper() }
}
@Test func transformRoundTrip() {
    let t = ViewTransform(scale: 2.4, offset: Point(20, -18)), p = Point(40, 82)
    #expect(t.documentPoint(t.viewPoint(p)).distance(to: p) < 0.00001)
}
@Test func spatialQueriesMatchBruteForce() {
    let strokes = (0..<300).map { i in Stroke(samples: [Sample(point: Point(Double(i % 20) * 20, Double(i / 20) * 20))]) }
    let index = SpatialIndex(strokes: strokes, bounds: Rect(x: 0, y: 0, width: 600, height: 800))
    for i in 0..<50 {
        let r = Rect(x: Double(i * 7), y: Double(i * 3), width: 55, height: 70)
        #expect(Set(index.query(r).map(\.id)) == Set(strokes.filter { $0.bounds.intersects(r) }.map(\.id)))
    }
}
@Test func lassoAndPrecisionErasure() {
    let s = Stroke(samples: (0...10).map { Sample(point: Point(Double($0) * 10, 50)) })
    let polygon = [Point(0, 0), Point(120, 0), Point(120, 100), Point(0, 100)]
    #expect(Editing.selection(strokes: [s], polygon: polygon, bounds: Rect(x: 0, y: 0, width: 600, height: 800)) == [s.id])
    let split = Editing.erase(strokes: [s], at: Point(50, 50), radius: 12, mode: .precision, highlighterOnly: false)
    #expect(split.count == 2); #expect(split.allSatisfy { $0.samples.allSatisfy { $0.point.distance(to: Point(50, 50)) > 13 } })
    #expect(Editing.erase(strokes: [s], at: Point(50, 50), radius: 12, mode: .stroke, highlighterOnly: true) == [s])
}
@Test func coordinatedSaveAndConflict() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".notecraft")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = PackageStore(); var package = NotebookPackage()
    try await store.save(package, to: url)
    package.notebook.revision = 1
    try await store.save(package, to: url, expectedRevision: 0)
    let read = try await store.read(from: url); #expect(read.notebook.revision == 1)
    await #expect(throws: PackageError.self) { try await store.save(package, to: url, expectedRevision: 0) }
}
