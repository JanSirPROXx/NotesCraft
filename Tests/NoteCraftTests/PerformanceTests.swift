import CoreGraphics
import ImageIO
import Foundation
import NoteCraftCore
import Testing

@testable import NoteCraft

// A page full of handwriting (~1600 strokes), the case every interaction has to stay fast on.
private func fullPage(style: PenStyle) -> Page {
  var page = Page()
  for line in 0..<36 {
    for word in 0..<9 {
      for letter in 0..<5 {
        let x = 40 + Double(word) * 60 + Double(letter) * 10
        let y = 50 + Double(line) * 22
        let samples = (0..<30).map { i -> Sample in
          let t = Double(i) / 29
          return Sample(
            point: Point(x + 6 * sin(t * 6.28), y + 14 * t), pressure: 0.3 + 0.6 * t, altitude: 1)
        }
        page.strokes.append(Stroke(samples: samples, width: 1.5, style: style))
      }
    }
  }
  return page
}

// Printed rather than asserted: it guides tuning, and debug builds are an order of magnitude
// slower than release. Run with `swift test -c release -Xswiftc -enable-testing --filter pageRender`.
#if DEBUG
  private let optimized = false
#else
  private let optimized = true
#endif

// Skipped in debug builds, where it would hold the main actor for seconds and starve the
// timing-sensitive canvas tests.
@MainActor @Test(.enabled(if: optimized)) func pageRenderTimings() throws {
  let clock = ContinuousClock()
  for style in [PenStyle.ballpoint, .fountain, .brush] {
    let page = fullPage(style: style)
    let context = try #require(
      CGContext(
        data: nil, width: 1668, height: 2388, bitsPerComponent: 8, bytesPerRow: 1668 * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: 2, y: 2)
    let elapsed = clock.measure { PageRenderer.render(page, assets: [:], in: context) }
    print("TIMING render full page \(style): \(elapsed)")
  }
}

// Rebuilding a page cache must not decode the same photo again each time.
@MainActor @Test func decodedImagesAreCachedPerAsset() throws {
  let context = try #require(
    CGContext(
      data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 64 * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
  let image = try #require(context.makeImage())
  let data = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
  let bytes = data as Data
  let first = try #require(PageRenderer.decodedImage("a.png", bytes))
  #expect(PageRenderer.decodedImage("a.png", bytes) === first)
  #expect(PageRenderer.decodedImage("b.png", bytes) !== first, "another asset is another image")
  #expect(first.width == 64 && first.height == 48)
}

// The cache of a heavy page is built off the main thread, and what it shows must be the same
// pixels the in-place build would have produced.
@MainActor @Test func backgroundPageCacheMatchesTheInPlaceCache() async throws {
  func flipped() throws -> CGContext {
    let context = try #require(
      CGContext(
        data: nil, width: 595, height: 842, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue))
    // Like a UIKit context: y points down.
    context.translateBy(x: 0, y: 842)
    context.scaleBy(x: 1, y: -1)
    return context
  }
  func configuration(_ page: Page) -> CanvasConfiguration {
    CanvasConfiguration(
      page: page, assets: [:], tool: .pen, color: .ink, width: 2, style: .ballpoint,
      pencilOnly: true, selection: [], onStroke: { _ in }, onGesture: { _ in }, onTap: { _ in })
  }
  var page = fullPage(style: .ballpoint)
  page.strokes.append(Stroke(samples: (0..<40).map { Sample(point: Point(500, 20 + Double($0) * 3)) }, color: .red, width: 6))

  let reference = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  reference.input.backgroundCacheThreshold = .max
  let referenceContext = try flipped()
  reference.paint(configuration(page), referenceContext)
  #expect(reference.cachedPage != nil, "small threshold pages are built in place")

  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.configuration = configuration(page)
  let first = try flipped()
  view.paint(configuration(page), first)
  #expect(view.cachedPage == nil, "the first paint does not wait for the page")
  let deadline = ContinuousClock.now.advanced(by: .seconds(20))
  while view.input.readyCache == nil && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  let context = try flipped()
  view.paint(configuration(page), context)
  #expect(view.cachedPage != nil)
  let expected = try #require(referenceContext.makeImage()?.dataProvider?.data as Data?)
  let actual = try #require(context.makeImage()?.dataProvider?.data as Data?)
  #expect(expected.count == actual.count)
  var total = 0
  for (a, b) in zip(expected, actual) { total += abs(Int(a) - Int(b)) }
  // Anti-aliased edges may differ by a little where the bitmap is resampled onto the layer.
  #expect(Double(total) / Double(expected.count) < 0.5, "mean byte difference \(Double(total) / Double(expected.count))")
}

@MainActor @Test func aPageEditedWhileItsCacheIsBuildingIsNeverShownStale() async throws {
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.input.backgroundCacheThreshold = 100
  var page = fullPage(style: .ballpoint)
  func configuration(_ page: Page) -> CanvasConfiguration {
    CanvasConfiguration(
      page: page, assets: [:], tool: .pen, color: .ink, width: 2, style: .ballpoint,
      pencilOnly: true, selection: [], onStroke: { _ in }, onGesture: { _ in }, onTap: { _ in })
  }
  func context() throws -> CGContext {
    try #require(
      CGContext(
        data: nil, width: 595, height: 842, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  }
  view.configuration = configuration(page)
  try view.paint(configuration(page), context())
  let building = view.input.cacheBuilding
  #expect(building)
  let generation = view.input.cacheGeneration
  page.strokes.removeLast()
  view.configuration = configuration(page)
  #expect(view.input.cacheGeneration > generation, "the edit retires the build in flight")
  let deadline = ContinuousClock.now.advanced(by: .seconds(20))
  while view.input.cacheBuilding && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(view.input.readyCache == nil, "the outdated bitmap was dropped")
  try view.paint(configuration(page), context())
  #expect(view.input.cacheBuilding, "a new build for the edited page started")
}

// Committing a pen stroke repaints the box of that stroke, not the whole page.
@MainActor @Test func anAppendedPenStrokeRepaintsOnlyItsOwnBox() throws {
  func configuration(_ page: Page) -> CanvasConfiguration {
    CanvasConfiguration(
      page: page, assets: [:], tool: .pen, color: .ink, width: 2, style: .ballpoint,
      pencilOnly: true, selection: [], onStroke: { _ in }, onGesture: { _ in }, onTap: { _ in })
  }
  func context() throws -> CGContext {
    try #require(
      CGContext(
        data: nil, width: 595, height: 842, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  }
  var page = Page()
  let view = DrawingView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
  view.configuration = configuration(page)
  try view.paint(configuration(page), context())
  #expect(view.cachedPage != nil)

  let stroke = Stroke(samples: (0..<20).map { Sample(point: Point(100 + Double($0), 200)) })
  view.input.pendingStroke = stroke
  let old = configuration(page)
  page.strokes.append(stroke)
  let rect = try #require(view.updatePageCache(from: old, to: configuration(page)))
  #expect(view.cachedPage != nil, "the stroke went into the cache")
  #expect(rect.width < 100 && rect.height < 60, "\(rect)")
  #expect(rect.contains(CGPoint(x: 110, y: 200)))
  #expect(!DrawingView.affectsPixels(old, configuration(page), ignoringPage: true))
  #expect(DrawingView.affectsPixels(old, configuration(page)))

  // Without a pending stroke the cache cannot be patched, so nothing narrows the repaint.
  let before = configuration(page)
  page.strokes.removeLast()
  #expect(view.updatePageCache(from: before, to: configuration(page)) == nil)
  #expect(view.cachedPage == nil)
}
