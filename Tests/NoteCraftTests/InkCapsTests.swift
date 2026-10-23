import CoreGraphics
import Foundation
import NoteCraftCore
import Testing

@testable import NoteCraft

// The round caps of fountain ink are ellipses added to the same path as the ribbon quads. They have
// to turn the same way, or the nonzero fill rule cancels the half of the cap that lies inside the
// ribbon and leaves a bite out of both ends of every stroke.
@MainActor @Test func theEndsOfAFountainStrokeAreSolid() throws {
  let samples = (0..<40).map { Sample(point: Point(50 + Double($0) * 2.5, 40), pressure: 1) }
  var stroke = Stroke(samples: samples, color: .ink, width: 12, tool: .pen, style: .fountain)
  stroke.tip = PenTip(sharpness: 0, pressure: 0, flatness: 0)
  var page = Page(paper: Paper(size: .a4, pattern: .blank))
  page.strokes = [stroke]
  var bytes = [UInt8](repeating: 0, count: 200 * 80 * 4)
  bytes.withUnsafeMutableBytes { raw in
    let c = CGContext(
      data: raw.baseAddress, width: 200, height: 80, bitsPerComponent: 8, bytesPerRow: 200 * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: 80)
    c.scaleBy(x: 1, y: -1)
    PageRenderer.render(page, assets: [:], in: c, includeBackground: false)
  }
  func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * 200 + x) * 4 + 3] }
  // Just inside each end, on the centre line, where the cap overlaps the ribbon.
  let first = try #require(stroke.samples.first)
  let last = try #require(stroke.samples.last)
  #expect(alpha(Int(first.point.x) + 2, 40) > 240, "start: \(alpha(Int(first.point.x) + 2, 40))")
  #expect(alpha(Int(last.point.x) - 2, 40) > 240, "end: \(alpha(Int(last.point.x) - 2, 40))")
  #expect(alpha(100, 40) > 240)
}
