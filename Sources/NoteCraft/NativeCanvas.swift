import SwiftUI
import NoteCraftCore

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
    func updateNSView(_ view: DrawingView, context: Context) { view.configuration = configuration; view.needsDisplay = true }
}
@MainActor final class DrawingView: NSView {
    var configuration: CanvasConfiguration? { didSet { if oldValue?.page != configuration?.page { cachedPage = nil } } }
    var cachedPage: CGLayer?
    var samples: [Sample] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) { guard let c = NSGraphicsContext.current?.cgContext, let configuration else { return }; paint(configuration, c) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); samples = []; append(event); needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { append(event); needsDisplay = true }
    override func mouseUp(with event: NSEvent) { append(event); finish(); needsDisplay = true }
    func append(_ event: NSEvent) {
        guard let configuration, configuration.tool != .readOnly else { return }
        let p = convert(event.locationInWindow, from: nil), scale = bounds.width / configuration.page.dimensions.x
        samples.append(Sample(point: Point(p.x / scale, p.y / scale), pressure: event.pressure > 0 ? Double(event.pressure) : 1))
    }
}
#else
struct NativeCanvas: UIViewRepresentable {
    var configuration: CanvasConfiguration
    func makeUIView(context: Context) -> DrawingView { let view = DrawingView(); view.isMultipleTouchEnabled = false; view.backgroundColor = .white; view.contentScaleFactor = UIScreen.main.scale; return view }
    func updateUIView(_ view: DrawingView, context: Context) { view.configuration = configuration; view.setNeedsDisplay() }
}
@MainActor final class DrawingView: UIView {
    var configuration: CanvasConfiguration? { didSet { if oldValue?.page != configuration?.page { cachedPage = nil } } }
    var cachedPage: CGLayer?
    var samples: [Sample] = []
    override func draw(_ rect: CGRect) { guard let c = UIGraphicsGetCurrentContext(), let configuration else { return }; paint(configuration, c) }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let configuration, !configuration.pencilOnly || touch.type == .pencil else { return }
        samples = []; append(touch); setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !samples.isEmpty, let touch = touches.first else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] { append(sample) }; setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { guard !samples.isEmpty else { return }; if let touch = touches.first { append(touch) }; finish(); setNeedsDisplay() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { samples = []; setNeedsDisplay() }
    func append(_ touch: UITouch) {
        guard let configuration, configuration.tool != .readOnly else { return }
        let p = touch.location(in: self), scale = bounds.width / configuration.page.dimensions.x
        samples.append(Sample(point: Point(p.x / scale, p.y / scale), pressure: touch.type == .pencil ? Double(touch.force / max(0.01, touch.maximumPossibleForce)) : 1, altitude: Double(touch.altitudeAngle)))
    }
}
#endif

extension DrawingView {
    func paint(_ configuration: CanvasConfiguration, _ c: CGContext) {
        let scale = bounds.width / configuration.page.dimensions.x
        c.saveGState(); c.scaleBy(x: scale, y: scale)
        // Retained ink is cached so pointer updates only render the active stroke.
        if cachedPage == nil, let layer = CGLayer(c, size: CGSize(width: configuration.page.dimensions.x, height: configuration.page.dimensions.y), auxiliaryInfo: nil), let context = layer.context {
            PageRenderer.render(configuration.page, assets: configuration.assets, in: context)
            cachedPage = layer
        }
        if let cachedPage { c.draw(cachedPage, at: .zero) }
        if !samples.isEmpty {
            if configuration.tool == .lasso {
                c.setStrokeColor(PageRenderer.color(.blue)); c.setLineWidth(1); c.setLineDash(phase: 0, lengths: [5, 4])
                c.addLines(between: samples.map { CGPoint(x: $0.point.x, y: $0.point.y) }); c.strokePath()
            } else if [.pen, .highlighter, .shapes].contains(configuration.tool) {
                PageRenderer.stroke(Stroke(samples: samples, color: configuration.color, width: configuration.width, tool: configuration.tool, style: configuration.style), in: c)
            }
        }
        c.setLineDash(phase: 0, lengths: [4, 3]); c.setStrokeColor(PageRenderer.color(.blue)); c.setLineWidth(1)
        for stroke in configuration.page.strokes where configuration.selection.contains(stroke.id) { let b = stroke.bounds; c.stroke(CGRect(x: b.x - 4, y: b.y - 4, width: b.width + 8, height: b.height + 8)) }
        c.restoreGState()
    }
    func finish() {
        guard let configuration, let first = samples.first else { samples = []; return }
        switch configuration.tool {
        case .pen, .highlighter, .shapes: configuration.onStroke(Stroke(samples: samples, color: configuration.color, width: configuration.width, tool: configuration.tool, style: configuration.style))
        case .eraser, .lasso: configuration.onGesture(samples.map(\.point))
        case .text, .image, .elements: configuration.onTap(first.point)
        case .readOnly: break
        }
        samples = []
    }
}
