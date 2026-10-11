import CoreGraphics
import Foundation
import NoteCraftCore
import Testing

@testable import NoteCraft

@MainActor private func canvas(
  _ page: Page, selection: Set<UUID>, tool: InkTool = .lasso,
  transform: @escaping (SelectionTransform) -> Void
) -> DrawingView {
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.configuration = CanvasConfiguration(
    page: page, assets: [:], tool: tool, color: .ink, width: 2, style: .ballpoint,
    pencilOnly: false, selection: selection, onStroke: { _ in }, onGesture: { _ in },
    onTap: { _ in }, onTransformSelection: transform, holdToShape: false)
  return view
}

@MainActor private func drag(_ view: DrawingView, from a: Point, to b: Point) {
  view.accept(Sample(point: a))
  view.accept(Sample(point: b))
  view.finish()
}

@MainActor @Test func draggingTheRightEdgeStretchesAShapeAndKeepsTheLeftEdgeFixed() throws {
  let spec = ShapeSpec(kind: .rectangle, center: Point(200, 200), width: 100, height: 60)
  let stroke = Stroke.shape(spec, color: .ink, width: 2)
  var page = Page()
  page.strokes = [stroke]
  var applied: SelectionTransform?
  let view = canvas(page, selection: [stroke.id]) { applied = $0 }
  drag(view, from: Point(250, 200), to: Point(310, 200))
  let result = InkGestures.transform(page, ids: [stroke.id], by: try #require(applied))
  let moved = try #require(result.strokes.first?.shape)
  #expect(abs(moved.width - 160) < 0.001)
  #expect(abs(moved.height - 60) < 0.001)
  #expect(abs((moved.center.x - moved.width / 2) - 150) < 0.001, "The left edge must stay put")
}

@MainActor @Test func draggingACornerScalesProportionallyAboutTheOppositeCorner() throws {
  let spec = ShapeSpec(kind: .rectangle, center: Point(200, 200), width: 100, height: 60)
  let stroke = Stroke.shape(spec, color: .ink, width: 2)
  var page = Page()
  page.strokes = [stroke]
  var applied: SelectionTransform?
  let view = canvas(page, selection: [stroke.id]) { applied = $0 }
  // Bottom-right corner (250, 230) dragged along the diagonal away from the top-left (150, 170).
  drag(view, from: Point(250, 230), to: Point(350, 290))
  let result = InkGestures.transform(page, ids: [stroke.id], by: try #require(applied))
  let moved = try #require(result.strokes.first?.shape)
  #expect(abs(moved.width / moved.height - 100 / 60) < 0.001)
  #expect(abs(moved.width - 200) < 0.001)
  #expect(abs((moved.center.x - moved.width / 2) - 150) < 0.001)
  #expect(abs((moved.center.y - moved.height / 2) - 170) < 0.001)
  #expect(result.strokes.first?.width == 2, "Line weight does not scale with a shape")
}

@MainActor @Test func rotatedShapeStretchesAlongItsOwnAxis() throws {
  let spec = ShapeSpec(
    kind: .rectangle, center: Point(300, 300), width: 100, height: 40, rotation: .pi / 2)
  let stroke = Stroke.shape(spec, color: .ink, width: 2)
  var page = Page()
  page.strokes = [stroke]
  var applied: SelectionTransform?
  let view = canvas(page, selection: [stroke.id]) { applied = $0 }
  // The local +x edge now points down the page: its midpoint is (300, 350).
  drag(view, from: Point(300, 350), to: Point(300, 400))
  let result = InkGestures.transform(page, ids: [stroke.id], by: try #require(applied))
  let moved = try #require(result.strokes.first?.shape)
  #expect(abs(moved.width - 150) < 0.001)
  #expect(abs(moved.height - 40) < 0.001)
  #expect(abs(moved.center.y - 325) < 0.001)
  #expect(abs(moved.center.x - 300) < 0.001)
}

@MainActor @Test func theRotateHandleSnapsToFifteenDegrees() throws {
  let spec = ShapeSpec(kind: .rectangle, center: Point(300, 300), width: 100, height: 60)
  let stroke = Stroke.shape(spec, color: .ink, width: 2)
  var page = Page()
  page.strokes = [stroke]
  var applied: SelectionTransform?
  let view = canvas(page, selection: [stroke.id]) { applied = $0 }
  // Rotate handle sits 30 pt above the top edge: (300, 240).
  let angle = 29.0 / 180 * Double.pi
  drag(
    view, from: Point(300, 240),
    to: Point(300 + 60 * sin(angle), 300 - 60 * cos(angle)))
  let result = InkGestures.transform(page, ids: [stroke.id], by: try #require(applied))
  let rotated = try #require(result.strokes.first?.shape)
  #expect(abs(rotated.rotation - 30.0 / 180 * Double.pi) < 0.001)
}

@MainActor @Test func tappingFindsShapesStickersAndImagesButNotEmptyPaper() {
  var page = Page()
  let rectangle = Stroke.shape(
    ShapeSpec(kind: .rectangle, center: Point(100, 100), width: 80, height: 60), color: .ink,
    width: 2)
  let heart = Stroke.sticker(.heart, at: Point(300, 100))
  let image = PageAsset(filename: "a", frame: Rect(x: 400, y: 300, width: 100, height: 100))
  page.strokes = [rectangle, heart]
  page.images = [image]
  #expect(InkGestures.objectID(at: Point(60, 100), page: page, tolerance: 8) == rectangle.id)
  #expect(
    InkGestures.objectID(at: Point(100, 100), page: page, tolerance: 8) == nil,
    "The inside of an unfilled shape is empty paper")
  #expect(InkGestures.objectID(at: Point(300, 100), page: page, tolerance: 8) == heart.id)
  #expect(InkGestures.objectID(at: Point(450, 350), page: page, tolerance: 8) == image.id)
  #expect(InkGestures.objectID(at: Point(500, 700), page: page, tolerance: 8) == nil)
}

@Test func translatingAndTransformingKeepsShapeSpecsInSync() {
  let spec = ShapeSpec(kind: .ellipse, center: Point(100, 100), width: 80, height: 40)
  let stroke = Stroke.shape(spec, color: .ink, width: 3)
  var page = Page()
  page.strokes = [stroke]
  let moved = InkGestures.translate(page, ids: [stroke.id], by: Point(10, 20))
  #expect(moved.strokes[0].shape?.center == Point(110, 120))
  #expect(moved.strokes[0].samples.first?.point == spec.outline.first.map { Point($0.x + 10, $0.y + 20) })
  let scaled = InkGestures.transform(
    page, ids: [stroke.id], by: SelectionTransform(center: Point(100, 100), scale: 2))
  #expect(scaled.strokes[0].shape?.width == 160)
  #expect(scaled.strokes[0].width == 3)
}

@MainActor @Test func imagesAndTextStretchWithEdgeHandles() throws {
  var page = Page()
  let image = PageAsset(filename: "a", frame: Rect(x: 100, y: 100, width: 200, height: 100))
  page.images = [image]
  var applied: SelectionTransform?
  let view = canvas(page, selection: [image.id], tool: .image) { applied = $0 }
  drag(view, from: Point(200, 200), to: Point(200, 260))  // bottom edge midpoint
  let result = InkGestures.transform(page, ids: [image.id], by: try #require(applied))
  let frame = try #require(result.images.first?.frame)
  #expect(abs(frame.width - 200) < 0.001)
  #expect(abs(frame.height - 160) < 0.001)
  #expect(abs(frame.y - 100) < 0.001, "The top edge stays fixed")
}
