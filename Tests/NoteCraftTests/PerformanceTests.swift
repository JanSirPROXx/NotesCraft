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
