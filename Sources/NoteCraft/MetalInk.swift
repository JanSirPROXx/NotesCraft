import CoreGraphics
import Foundation
import Metal
import NoteCraftCore
import QuartzCore

// GPU renderer for the stroke being written. The CPU only turns new samples into a few "cones"
// (a capsule whose two ends may differ in radius); the GPU fills them into a texture that holds
// the finished part of the stroke and composites the unstable tail on top, so the per-sample cost
// no longer depends on how fast the pen moves or how large the page is.

// Page-space geometry of one piece of ink: a round cap at `a` and `b`, joined by a linear taper.
struct InkCone {
  var a: SIMD2<Float>
  var b: SIMD2<Float>
  var ra: Float
  var rb: Float
}

// Mirrors `PageRenderer.smoothInkSegments`: the same midpoint quadratic segments and widths, cut
// into short cones instead of being stroked by CoreGraphics. A cone chain has round joins
// everywhere, which is what the CoreGraphics stroke (round caps and joins) looks like too.
enum InkTessellator {
  nonisolated static func cones(
    _ samples: [Sample], range: Range<Int>, width: Double, style: PenStyle,
    widths: [Double]? = nil, finish: Bool = false, pixelScale: Double
  ) -> [InkCone] {
    guard samples.count > 1 else { return [] }
    let useWidths = (style == .fountain || style == .pencil) && widths?.count == samples.count
    var cones: [InkCone] = []
    for i in range where i > 0 && i < samples.count {
      let a = samples[i - 1]
      let b = samples[i]
      let isLast = finish && i == samples.count - 1
      let start =
        i == 1
        ? a.point
        : Point(
          (samples[i - 2].point.x + a.point.x) / 2, (samples[i - 2].point.y + a.point.y) / 2)
      let end = isLast ? b.point : Point((a.point.x + b.point.x) / 2, (a.point.y + b.point.y) / 2)
      let startRadius: Double
      let endRadius: Double
      if useWidths, let widths {
        startRadius = (i == 1 ? widths[0] : (widths[i - 2] + widths[i - 1]) / 2) / 2
        endRadius = (isLast ? widths[i] : (widths[i - 1] + widths[i]) / 2) / 2
      } else {
        let pressure = style == .ballpoint ? 1 : max(0.2, (a.pressure + b.pressure) / 2)
        let tilt = style == .brush ? 1 + (1 - sin((a.altitude + b.altitude) / 2)) : 1
        startRadius = width * pressure * tilt * (style == .brush ? 1.7 : 1) / 2
        endRadius = startRadius
      }
      // Short chords keep the polyline within a fraction of a pixel of the curve.
      let length = start.distance(to: a.point) + a.point.distance(to: end)
      let steps = min(48, max(1, Int((length * pixelScale / 4).rounded(.up))))
      var previous = start
      for step in 1...steps {
        let t = Double(step) / Double(steps)
        let u = 1 - t
        let point = Point(
          u * u * start.x + 2 * u * t * a.point.x + t * t * end.x,
          u * u * start.y + 2 * u * t * a.point.y + t * t * end.y)
        let r0 = startRadius + (endRadius - startRadius) * Double(step - 1) / Double(steps)
        let r1 = startRadius + (endRadius - startRadius) * t
        cones.append(
          InkCone(
            a: SIMD2(Float(previous.x), Float(previous.y)),
            b: SIMD2(Float(point.x), Float(point.y)), ra: Float(r0), rb: Float(r1)))
        previous = point
      }
    }
    return cones
  }

  // A tap: a single round dab.
  nonisolated static func dot(at sample: Sample, width: Double) -> InkCone {
    let p = SIMD2(Float(sample.point.x), Float(sample.point.y))
    return InkCone(a: p, b: p, ra: Float(width / 2), rb: Float(width / 2))
  }
}

struct InkUniforms {
  // The alpha is how much of the colour a line lays down (pencil ink is a little under 1).
  var color: SIMD4<Float>
  var offset: SIMD2<Float>
  var viewport: SIMD2<Float>
  var scale: Float
  // 1 multiplies the line by the paper grain, anchored to the page like the committed ink.
  var grain: Float = 0
}

@MainActor final class MetalInkEngine {
  static let shared: MetalInkEngine? = MetalInkEngine()
  let device: MTLDevice
  let queue: MTLCommandQueue
  let inkPipeline: MTLRenderPipelineState
  let copyPipeline: MTLRenderPipelineState
  // The grain tile the committed pencil ink is multiplied with, one texel per tile texel.
  let grainTexture: MTLTexture

  // Compiled from source at run time so the Swift package builds without a Metal toolchain step.
  private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float TILE = \(PencilGrain.size).0;
    constant float TEXELS = \(PencilGrain.texelsPerPoint);

    struct Cone { float2 a; float2 b; float ra; float rb; };
    struct Uniforms { float4 color; float2 offset; float2 viewport; float scale; float grain; };
    struct InkOut {
      float4 position [[position]];
      float2 a [[flat]];
      float2 b [[flat]];
      float ra [[flat]];
      float rb [[flat]];
    };

    vertex InkOut ink_vertex(
      uint vid [[vertex_id]], uint iid [[instance_id]],
      constant Cone *cones [[buffer(0)]], constant Uniforms &u [[buffer(1)]])
    {
      Cone c = cones[iid];
      InkOut out;
      out.a = c.a * u.scale + u.offset;
      out.b = c.b * u.scale + u.offset;
      out.ra = c.ra * u.scale;
      out.rb = c.rb * u.scale;
      float pad = max(out.ra, out.rb) + 1.0;
      float2 lo = min(out.a, out.b) - pad;
      float2 hi = max(out.a, out.b) + pad;
      float2 corner = float2((vid & 1) ? hi.x : lo.x, (vid & 2) ? hi.y : lo.y);
      out.position = float4(
        corner.x / u.viewport.x * 2.0 - 1.0, 1.0 - corner.y / u.viewport.y * 2.0, 0.0, 1.0);
      return out;
    }

    constexpr sampler grainSampler(address::repeat, filter::nearest);

    // Coverage of a round cone, one pixel of anti-aliasing. Blending takes the maximum, so
    // overlapping pieces of one stroke union exactly instead of darkening their edges.
    fragment float4 ink_fragment(
      InkOut in [[stage_in]], constant Uniforms &u [[buffer(1)]],
      texture2d<float> grainTexture [[texture(1)]])
    {
      float2 ab = in.b - in.a;
      float len2 = dot(ab, ab);
      float t = len2 > 1e-6 ? clamp(dot(in.position.xy - in.a, ab) / len2, 0.0, 1.0) : 0.0;
      float r = mix(in.ra, in.rb, t);
      float d = length(in.position.xy - (in.a + ab * t)) - r;
      float coverage = clamp(0.5 - d, 0.0, 1.0);
      if (u.grain > 0.5) {
        // Page position of this pixel; the tile is `TILE` texels, `TEXELS` of them per page point.
        float2 page = (in.position.xy - u.offset) / u.scale;
        coverage *= grainTexture.sample(grainSampler, page * (TEXELS / TILE)).r;
      }
      coverage *= u.color.a;
      return float4(u.color.rgb * coverage, coverage);
    }

    vertex float4 copy_vertex(uint vid [[vertex_id]]) {
      float2 p = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
      return float4(p, 0.0, 1.0);
    }

    fragment float4 copy_fragment(
      float4 position [[position]], texture2d<float, access::read> source [[texture(0)]])
    {
      return source.read(uint2(position.xy));
    }
    """

  private static func makeGrainTexture(_ device: MTLDevice) -> MTLTexture? {
    let size = PencilGrain.size
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    PencilGrain.alpha.withUnsafeBytes {
      texture.replace(
        region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!,
        bytesPerRow: size)
    }
    return texture
  }

  private init?() {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let grain = Self.makeGrainTexture(device),
      let library = try? device.makeLibrary(source: Self.source, options: nil),
      let inkVertex = library.makeFunction(name: "ink_vertex"),
      let inkFragment = library.makeFunction(name: "ink_fragment"),
      let copyVertex = library.makeFunction(name: "copy_vertex"),
      let copyFragment = library.makeFunction(name: "copy_fragment")
    else { return nil }
    let ink = MTLRenderPipelineDescriptor()
    ink.vertexFunction = inkVertex
    ink.fragmentFunction = inkFragment
    ink.colorAttachments[0].pixelFormat = .bgra8Unorm
    ink.colorAttachments[0].isBlendingEnabled = true
    ink.colorAttachments[0].rgbBlendOperation = .max
    ink.colorAttachments[0].alphaBlendOperation = .max
    ink.colorAttachments[0].sourceRGBBlendFactor = .one
    ink.colorAttachments[0].sourceAlphaBlendFactor = .one
    ink.colorAttachments[0].destinationRGBBlendFactor = .one
    ink.colorAttachments[0].destinationAlphaBlendFactor = .one
    let copy = MTLRenderPipelineDescriptor()
    copy.vertexFunction = copyVertex
    copy.fragmentFunction = copyFragment
    copy.colorAttachments[0].pixelFormat = .bgra8Unorm
    guard let inkState = try? device.makeRenderPipelineState(descriptor: ink),
      let copyState = try? device.makeRenderPipelineState(descriptor: copy)
    else { return nil }
    self.device = device
    self.queue = queue
    grainTexture = grain
    inkPipeline = inkState
    copyPipeline = copyState
  }
}

// The persistent half of the live stroke: finished segments accumulate in `baked`; each frame
// composites it with the tail into the target.
@MainActor final class MetalInkSurface {
  let engine: MetalInkEngine
  private var baked: MTLTexture?
  private(set) var width = 0
  private(set) var height = 0
  // Whether anything has been drawn since the last clear, so an empty surface is left alone.
  private(set) var hasContent = false

  init(engine: MetalInkEngine) { self.engine = engine }

  // Returns true when the texture was (re)allocated, which loses what had been baked.
  func resize(width: Int, height: Int) -> Bool {
    guard width != self.width || height != self.height || baked == nil else { return false }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: max(1, width), height: max(1, height), mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private
    baked = engine.device.makeTexture(descriptor: descriptor)
    self.width = width
    self.height = height
    hasContent = false
    return true
  }

  private func buffer(_ cones: [InkCone]) -> MTLBuffer? {
    cones.withUnsafeBytes {
      guard let base = $0.baseAddress, $0.count > 0 else { return nil }
      return engine.device.makeBuffer(bytes: base, length: $0.count, options: .storageModeShared)
    }
  }

  private func fill(
    _ encoder: MTLRenderCommandEncoder, _ cones: [InkCone], _ uniforms: InkUniforms
  ) {
    guard !cones.isEmpty, let buffer = buffer(cones) else { return }
    var uniforms = uniforms
    encoder.setRenderPipelineState(engine.inkPipeline)
    encoder.setFragmentTexture(engine.grainTexture, index: 1)
    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<InkUniforms>.stride, index: 1)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<InkUniforms>.stride, index: 1)
    encoder.drawPrimitives(
      type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cones.count)
  }

  // Bakes `bake` into the persistent texture (after clearing it when `reset`), then draws the
  // texture plus `tail` into `target`. Without a drawable the caller waits on the returned buffer.
  @discardableResult
  func draw(
    bake: [InkCone], tail: [InkCone], uniforms: InkUniforms, reset: Bool, target: MTLTexture,
    drawable: MTLDrawable? = nil
  ) -> MTLCommandBuffer? {
    guard let baked, let commands = engine.queue.makeCommandBuffer() else { return nil }
    if reset || !bake.isEmpty {
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = baked
      pass.colorAttachments[0].loadAction = reset ? .clear : .load
      pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
      pass.colorAttachments[0].storeAction = .store
      if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
        fill(encoder, bake, uniforms)
        encoder.endEncoding()
      }
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .dontCare
    pass.colorAttachments[0].storeAction = .store
    if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
      encoder.setRenderPipelineState(engine.copyPipeline)
      encoder.setFragmentTexture(baked, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      fill(encoder, tail, uniforms)
      encoder.endEncoding()
    }
    if let drawable { commands.present(drawable) }
    commands.commit()
    hasContent = !reset && (hasContent || !bake.isEmpty || !tail.isEmpty)
    return commands
  }
}

#if os(iOS)
  import UIKit

  // The layer the live stroke is drawn into: transparent, above the page and its CoreGraphics
  // overlay, composited by the system like any other layer.
  @MainActor final class MetalInkView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    let surface: MetalInkSurface
    // Device pixels per view point of the current drawable.
    private(set) var pixelScale = 1.0

    static func make(frame: CGRect) -> MetalInkView? {
      MetalInkEngine.shared.map { MetalInkView(frame: frame, engine: $0) }
    }
    private init(frame: CGRect, engine: MetalInkEngine) {
      surface = MetalInkSurface(engine: engine)
      super.init(frame: frame)
      isOpaque = false
      backgroundColor = .clear
      isUserInteractionEnabled = false
      metalLayer.device = engine.device
      metalLayer.pixelFormat = .bgra8Unorm
      metalLayer.framebufferOnly = true
      metalLayer.isOpaque = false
      // Two drawables keep the queue short: a stale frame is worse than a dropped one.
      metalLayer.maximumDrawableCount = 2
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    // Sizes the drawable to the view at the current zoom (capped like the page cache). True when
    // the contents were lost and the stroke has to be baked again.
    func fitDrawable() -> Bool {
      let longSide = max(bounds.width, bounds.height)
      guard longSide > 0 else { return false }
      pixelScale = min(Double(contentScaleFactor), 4096 / Double(longSide))
      let width = max(1, Int((bounds.width * pixelScale).rounded()))
      let height = max(1, Int((bounds.height * pixelScale).rounded()))
      if metalLayer.drawableSize != CGSize(width: width, height: height) {
        metalLayer.drawableSize = CGSize(width: width, height: height)
      }
      return surface.resize(width: width, height: height)
    }

    func draw(bake: [InkCone], tail: [InkCone], uniforms: InkUniforms, reset: Bool) {
      guard let drawable = metalLayer.nextDrawable() else { return }
      surface.draw(
        bake: bake, tail: tail, uniforms: uniforms, reset: reset, target: drawable.texture,
        drawable: drawable)
    }

    func clear() {
      guard surface.hasContent, surface.width > 0 else { return }
      let uniforms = InkUniforms(
        color: SIMD4(0, 0, 0, 1), offset: SIMD2(0, 0),
        viewport: SIMD2(Float(surface.width), Float(surface.height)), scale: 1)
      draw(bake: [], tail: [], uniforms: uniforms, reset: true)
    }
  }
#endif
