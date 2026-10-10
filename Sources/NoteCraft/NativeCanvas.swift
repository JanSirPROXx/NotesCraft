import NoteCraftCore
import SwiftUI

@MainActor struct CanvasConfiguration {
  var page: Page
  var assets: [String: Data]
  var tool: InkTool
  var color: InkColor
  var width: Double
  var style: PenStyle
  var pencilOnly: Bool
  var selection: Set<UUID>
  var onStroke: (Stroke) -> Void
  var onGesture: ([Point]) -> Void
  var onTap: (Point) -> Void
}
#if os(macOS)
  struct NativeCanvas: NSViewRepresentable {
    var configuration: CanvasConfiguration
    func makeNSView(context: Context) -> DrawingView { DrawingView() }
    func updateNSView(_ view: DrawingView, context: Context) {
      view.configuration = configuration
      view.needsDisplay = true
    }
  }
  @MainActor final class DrawingView: NSView {
    var configuration: CanvasConfiguration? {
      didSet { if oldValue?.page != configuration?.page { cachedPage = nil } }
    }
    var cachedPage: CGLayer?
    var cachedResolution = 0.0
    var samples: [Sample] = []
    var predictedSamples: [Sample] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
      guard let c = NSGraphicsContext.current?.cgContext, let configuration else { return }
      paint(configuration, c)
    }
    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      samples = []
      predictedSamples = []
      append(event)
      needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
      append(event)
      needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
      append(event)
      finish()
      needsDisplay = true
    }
    func append(_ event: NSEvent) {
      guard let configuration else { return }
      let p = convert(event.locationInWindow, from: nil)
      let scale = bounds.width / configuration.page.dimensions.x
      samples.append(
        Sample(
          point: Point(p.x / scale, p.y / scale),
          pressure: event.pressure > 0 ? Double(event.pressure) : 1))
    }
  }
#else
  struct NativeCanvas: UIViewRepresentable {
    var configuration: CanvasConfiguration
    func makeUIView(context: Context) -> DrawingView {
      let view = DrawingView()
      view.isMultipleTouchEnabled = false
      view.backgroundColor = .white
      view.contentScaleFactor = UIScreen.main.scale
      return view
    }
    func updateUIView(_ view: DrawingView, context: Context) {
      view.configuration = configuration
      view.setNeedsDisplay()
    }
  }
  @MainActor final class DrawingView: UIView {
    var configuration: CanvasConfiguration? {
      didSet { if oldValue?.page != configuration?.page { cachedPage = nil } }
    }
    var cachedPage: CGLayer?
    var cachedResolution = 0.0
    var samples: [Sample] = []
    var predictedSamples: [Sample] = []
    override func draw(_ rect: CGRect) {
      guard let c = UIGraphicsGetCurrentContext(), let configuration else { return }
      paint(configuration, c)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let touch = touches.first, let configuration,
        configuration.tool == .readOnly || !configuration.pencilOnly || touch.type == .pencil
      else { return }
      samples = []
      predictedSamples = []
      append(touch)
      setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard !samples.isEmpty, let touch = touches.first else { return }
      for sample in event?.coalescedTouches(for: touch) ?? [touch] { append(sample) }
      predictedSamples = (event?.predictedTouches(for: touch) ?? []).map { sample($0) }
      setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard !samples.isEmpty else { return }
      if let touch = touches.first { append(touch) }
      finish()
      setNeedsDisplay()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      samples = []
      predictedSamples = []
      setNeedsDisplay()
    }
    private var displayLink: CADisplayLink?
    private var displayTarget: CanvasDisplayTarget?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      displayLink?.invalidate()
      displayLink = nil
      displayTarget = nil
      guard window != nil else { return }
      let target = CanvasDisplayTarget()
      target.view = self
      displayTarget = target
      let link = CADisplayLink(target: target, selector: #selector(CanvasDisplayTarget.update))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    func sample(_ touch: UITouch) -> Sample {
      let p = touch.location(in: self)
      let scale = bounds.width / (configuration?.page.dimensions.x ?? 595)
      return Sample(
        point: Point(p.x / scale, p.y / scale),
        pressure: touch.type == .pencil
          ? min(1, Double(touch.force / max(0.01, touch.maximumPossibleForce))) : 1,
        altitude: Double(touch.altitudeAngle))
    }
    func append(_ touch: UITouch) {
      guard configuration != nil else { return }
      samples.append(sample(touch))
    }
  }
  @MainActor private final class CanvasDisplayTarget: NSObject {
    weak var view: DrawingView?
    @objc func update() { if let view, !view.samples.isEmpty { view.setNeedsDisplay() } }
  }
#endif

extension DrawingView {
  func paint(_ configuration: CanvasConfiguration, _ c: CGContext) {
    let scale = bounds.width / configuration.page.dimensions.x
    c.saveGState()
    c.scaleBy(x: scale, y: scale)
    // Cache at the effective display resolution so zoom and Retina scaling do not soften retained ink.
    let dimensions = configuration.page.dimensions
    let resolution = min(hypot(c.ctm.a, c.ctm.b), 4096 / max(dimensions.x, dimensions.y))
    if abs(resolution - cachedResolution) > 0.001 { cachedPage = nil }
    if cachedPage == nil,
      let layer = CGLayer(
        c, size: CGSize(width: dimensions.x * resolution, height: dimensions.y * resolution),
        auxiliaryInfo: nil),
      let context = layer.context
    {
      context.scaleBy(x: resolution, y: resolution)
      PageRenderer.render(configuration.page, assets: configuration.assets, in: context)
      cachedPage = layer
      cachedResolution = resolution
    }
    if let cachedPage {
      c.draw(cachedPage, in: CGRect(x: 0, y: 0, width: dimensions.x, height: dimensions.y))
    }
    if !samples.isEmpty {
      if configuration.tool == .lasso {
        c.setStrokeColor(PageRenderer.color(.blue))
        c.setLineWidth(1)
        c.setLineDash(phase: 0, lengths: [5, 4])
        c.addLines(between: samples.map { CGPoint(x: $0.point.x, y: $0.point.y) })
        c.strokePath()
      } else if [.pen, .highlighter, .shapes].contains(configuration.tool) {
        PageRenderer.stroke(
          Stroke(
            samples: samples + predictedSamples, color: configuration.color,
            width: configuration.width, tool: configuration.tool, style: configuration.style), in: c
        )
      }
    }
    c.setLineDash(phase: 0, lengths: [4, 3])
    c.setStrokeColor(PageRenderer.color(.blue))
    c.setLineWidth(1)
    for stroke in configuration.page.strokes where configuration.selection.contains(stroke.id) {
      let b = stroke.bounds
      c.stroke(CGRect(x: b.x - 4, y: b.y - 4, width: b.width + 8, height: b.height + 8))
    }
    for image in configuration.page.images where configuration.selection.contains(image.id) {
      let b = image.frame
      c.stroke(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
    }
    for text in configuration.page.texts where configuration.selection.contains(text.id) {
      let b = text.bounds
      c.stroke(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
    }
    c.restoreGState()
  }
  func finish() {
    guard let configuration, let first = samples.first else {
      samples = []
      return
    }
    switch configuration.tool {
    case .pen, .highlighter, .shapes:
      configuration.onStroke(
        Stroke(
          samples: samples, color: configuration.color, width: configuration.width,
          tool: configuration.tool, style: configuration.style))
    case .eraser, .lasso: configuration.onGesture(samples.map(\.point))
    case .text, .image, .elements: configuration.onTap(first.point)
    case .readOnly:
      if let last = samples.last, first.point.distance(to: last.point) < 5 {
        configuration.onTap(first.point)
      }
    }
    samples = []
    predictedSamples = []
  }
}
