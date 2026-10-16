import CoreGraphics
import Foundation
import Metal
import NoteCraftCore
import Testing

@testable import NoteCraft

// The live stroke is drawn by the GPU and replaced by the CoreGraphics stroke once it is
// committed. These tests hold the two to the same picture, so nothing visibly changes at pen-up.
@MainActor private struct InkBitmaps {
  let width = 600
  let height = 360
  let scale = 3.0

  func samples() -> [Sample] {
    (0..<70).map { i in
      let t = Double(i) / 69
      return Sample(
        point: Point(12 + t * 170, 60 + sin(t * 9) * 32 + t * 10),
        pressure: 0.35 + 0.6 * abs(sin(t * 5)), altitude: 0.5 + 0.9 * abs(cos(t * 3)))
    }
  }

  func coreGraphicsAlpha(
    _ samples: [Sample], style: PenStyle, width ink: Double, widths: [Double]?
  ) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { raw in
      let c = CGContext(
        data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.translateBy(x: 0, y: Double(height))
      c.scaleBy(x: scale, y: -scale)
      PageRenderer.smoothInkSegments(
        samples, range: 1..<samples.count, color: .ink, width: ink, style: style, in: c,
        finish: true, widths: widths)
    }
    return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
  }

  func metalAlpha(_ samples: [Sample], style: PenStyle, width ink: Double, widths: [Double]?)
    -> [UInt8]?
  {
    guard let engine = MetalInkEngine.shared else { return nil }
    let surface = MetalInkSurface(engine: engine)
    _ = surface.resize(width: width, height: height)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = engine.device.makeTexture(descriptor: descriptor) else { return nil }
    let cones = InkTessellator.cones(
      samples, range: 1..<samples.count, width: ink, style: style, widths: widths, finish: true,
      pixelScale: scale)
    let uniforms = InkUniforms(
      color: SIMD4(0, 0, 0, 1), offset: SIMD2(0, 0),
      viewport: SIMD2(Float(width), Float(height)), scale: Float(scale))
    surface.draw(bake: cones, tail: [], uniforms: uniforms, reset: true, target: target)?
      .waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    target.getBytes(
      &bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
  }
}

@MainActor @Test(arguments: [PenStyle.ballpoint, .brush, .fountain])
func gpuInkMatchesTheCoreGraphicsStroke(style: PenStyle) throws {
  let bitmaps = InkBitmaps()
  let samples = bitmaps.samples()
  let widths =
    style == .fountain
    ? FountainInk.widths(for: samples, base: 3.2, tip: .standard, finished: false) : nil
  let reference = bitmaps.coreGraphicsAlpha(samples, style: style, width: 3.2, widths: widths)
  guard let gpu = bitmaps.metalAlpha(samples, style: style, width: 3.2, widths: widths) else {
    return  // No Metal device on this machine.
  }
  var total = 0
  var strong = 0
  var covered = 0
  for (a, b) in zip(reference, gpu) {
    let difference = abs(Int(a) - Int(b))
    total += difference
    if difference > 96 { strong += 1 }
    if a > 128 { covered += 1 }
  }
  #expect(covered > 1500, "the reference stroke should have ink")
  // Anti-aliasing differs at the edges; the shape must not.
  #expect(Double(total) / Double(reference.count) < 0.6, "mean alpha error \(Double(total) / Double(reference.count))")
  #expect(Double(strong) / Double(max(1, covered)) < 0.03, "\(strong) of \(covered) ink pixels differ strongly")
}

@MainActor @Test func gpuInkKeepsWhatWasBakedAndAddsTheTail() throws {
  let bitmaps = InkBitmaps()
  let samples = bitmaps.samples()
  guard let engine = MetalInkEngine.shared else { return }
  let surface = MetalInkSurface(engine: engine)
  _ = surface.resize(width: bitmaps.width, height: bitmaps.height)
  let descriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: bitmaps.width, height: bitmaps.height, mipmapped: false)
  descriptor.usage = [.renderTarget, .shaderRead]
  descriptor.storageMode = .shared
  let target = try #require(engine.device.makeTexture(descriptor: descriptor))
  let uniforms = InkUniforms(
    color: SIMD4(0, 0, 0, 1), offset: SIMD2(0, 0),
    viewport: SIMD2(Float(bitmaps.width), Float(bitmaps.height)), scale: Float(bitmaps.scale))
  func render(bake: Range<Int>, tail: Range<Int>, reset: Bool) -> [UInt8] {
    let baked = InkTessellator.cones(
      samples, range: bake, width: 3.2, style: .ballpoint, finish: false, pixelScale: 3)
    let rest = InkTessellator.cones(
      samples, range: tail, width: 3.2, style: .ballpoint, finish: true, pixelScale: 3)
    surface.draw(bake: baked, tail: rest, uniforms: uniforms, reset: reset, target: target)?
      .waitUntilCompleted()
    var bytes = [UInt8](repeating: 0, count: bitmaps.width * bitmaps.height * 4)
    target.getBytes(
      &bytes, bytesPerRow: bitmaps.width * 4,
      from: MTLRegionMake2D(0, 0, bitmaps.width, bitmaps.height), mipmapLevel: 0)
    return stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }
  }
  // Frame 1 bakes the first half; frame 2 bakes nothing new and only adds a tail. The first half
  // must still be there in the second frame.
  let first = render(bake: 1..<35, tail: 35..<36, reset: true)
  let second = render(bake: 36..<36, tail: 36..<samples.count, reset: false)
  let firstInk = first.filter { $0 > 128 }.count
  let secondInk = second.filter { $0 > 128 }.count
  #expect(secondInk > firstInk + 500, "baked ink survives and the tail is added")
  // A reset clears everything.
  let cleared = render(bake: 1..<1, tail: 1..<1, reset: true)
  #expect(cleared.allSatisfy { $0 == 0 })
}
