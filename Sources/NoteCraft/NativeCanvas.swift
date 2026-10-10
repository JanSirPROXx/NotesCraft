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
  var viewport: ViewTransform? = nil
  var onViewportChange: ((ViewTransform) -> Void)? = nil
  var onTranslateSelection: ((Point) -> Void)? = nil
  var onTransformSelection: ((SelectionTransform) -> Void)? = nil
  var onSelectionMenu: (() -> Void)? = nil
  var onPencilDetected: (() -> Void)? = nil
  var onToggleEraser: (() -> Void)? = nil
  var onAppendPage: (() -> Void)? = nil
  var onPagePull: ((Double) -> Void)? = nil
  var holdToShape = true
  var eraserMode: EraserMode = .stroke
  var highlighterOnly = false
  var searchHighlights: [Rect] = []
}
#if os(macOS)
  struct NativeCanvas: NSViewRepresentable {
    var configuration: CanvasConfiguration
    func makeNSView(context: Context) -> DrawingView { DrawingView() }
    func updateNSView(_ view: DrawingView, context: Context) {
      view.configuration = configuration
      view.setAccessibilityElement(true)
      view.setAccessibilityLabel("Drawing canvas")
      view.setAccessibilityIdentifier("drawingCanvas")
      view.setAccessibilityValue("\(configuration.page.strokes.count) strokes")
      view.needsDisplay = true
    }
  }
  @MainActor final class DrawingView: NSView {
    var configuration: CanvasConfiguration? {
      didSet {
        if oldValue?.page != configuration?.page { cachedPage = nil }
      }
    }
    var cachedPage: CGLayer?
    var cachedResolution = 0.0
    var cachedViewport: ViewTransform?
    let input = CanvasInputState()
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
      resetInput()
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
    private var pullDistance = 0.0
    private var pullStarted: TimeInterval?
    private var pullTriggered = false
    override func scrollWheel(with event: NSEvent) {
      if configuration?.onAppendPage != nil, let scroll = enclosingScrollView,
        let content = scroll.documentView
      {
        if event.phase == .began {
          pullDistance = 0
          pullStarted = nil
          pullTriggered = false
        }
        let bottom = scroll.contentView.bounds.maxY >= content.bounds.maxY - 2
        if bottom && event.scrollingDeltaY < 0 && !pullTriggered && event.momentumPhase.isEmpty {
          pullDistance -= event.scrollingDeltaY
          let now = ProcessInfo.processInfo.systemUptime
          if pullStarted == nil { pullStarted = now }
          let progress = min(1, min(pullDistance / 100, (now - (pullStarted ?? now)) / 0.45))
          configuration?.onPagePull?(progress)
          if progress >= 1 {
            pullTriggered = true
            configuration?.onAppendPage?()
          }
        } else if !bottom || event.scrollingDeltaY > 0 {
          pullDistance = 0
          pullStarted = nil
          configuration?.onPagePull?(0)
        }
        if event.phase == .ended || event.phase == .cancelled { configuration?.onPagePull?(0) }
      }
      guard var viewport = configuration?.viewport else {
        super.scrollWheel(with: event)
        return
      }
      viewport.offset.x += event.scrollingDeltaX
      viewport.offset.y += event.scrollingDeltaY
      configuration?.onViewportChange?(viewport)
    }
    override func magnify(with event: NSEvent) {
      guard let viewport = configuration?.viewport else {
        super.magnify(with: event)
        return
      }
      let p = convert(event.locationInWindow, from: nil)
      let anchor = Point(p.x, p.y)
      let world = viewport.documentPoint(anchor)
      let scale = min(12, max(0.1, viewport.scale * (1 + event.magnification)))
      configuration?.onViewportChange?(
        ViewTransform(
          scale: scale, offset: Point(anchor.x - world.x * scale, anchor.y - world.y * scale)))
    }
    func append(_ event: NSEvent) {
      guard let configuration else { return }
      let p = convert(event.locationInWindow, from: nil)
      let scale = bounds.width / configuration.page.dimensions.x
      accept(
        Sample(
          point: configuration.viewport?.documentPoint(Point(p.x, p.y))
            ?? Point(p.x / scale, p.y / scale),
          pressure: event.pressure > 0 ? Double(event.pressure) : 1))
    }
  }
#else
  struct NativeCanvas: UIViewRepresentable {
    var configuration: CanvasConfiguration
    func makeUIView(context: Context) -> DrawingView {
      let view = DrawingView()
      view.isMultipleTouchEnabled = true
      view.backgroundColor = .white
      view.contentScaleFactor = UIScreen.main.scale
      let pencil = UIPencilInteraction()
      pencil.delegate = view
      view.addInteraction(pencil)
      return view
    }
    func updateUIView(_ view: DrawingView, context: Context) {
      view.configuration = configuration
      view.isAccessibilityElement = true
      view.accessibilityLabel = "Drawing canvas"
      view.accessibilityIdentifier = "drawingCanvas"
      view.accessibilityValue = "\(configuration.page.strokes.count) strokes"
      view.accessibilityTraits = .allowsDirectInteraction
      view.configureScrolling()
      view.setNeedsDisplay()
    }
  }
  @MainActor
  final class DrawingView: UIView, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    var configuration: CanvasConfiguration? {
      didSet {
        if oldValue?.page != configuration?.page { cachedPage = nil }
        #if os(iOS)
          if oldValue?.pencilOnly == true && configuration?.pencilOnly == false {
            pencilSeen = false
          }
        #endif
      }
    }
    var cachedPage: CGLayer?
    var cachedResolution = 0.0
    var cachedViewport: ViewTransform?
    let input = CanvasInputState()
    var samples: [Sample] = []
    var predictedSamples: [Sample] = []
    override func draw(_ rect: CGRect) {
      guard let c = UIGraphicsGetCurrentContext(), let configuration else { return }
      paint(configuration, c)
    }
    private var activeTouch: UITouch?
    private var pencilSeen = false
    private var pullStarted: TimeInterval?
    private var pullTriggered = false
    private weak var observedScroll: UIScrollView?
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
      configuration?.onToggleEraser?()
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let configuration else { return }
      let pencil = touches.first { $0.type == .pencil }
      if let pencil {
        pencilSeen = true
        configuration.onPencilDetected?()
        resetInput()
        activeTouch = pencil
        configureScrolling()
      } else {
        guard activeTouch == nil,
          configuration.tool == .readOnly || (!pencilSeen && !configuration.pencilOnly),
          let touch = touches.first(where: { $0.type == .direct && $0.majorRadius < 60 })
        else { return }
        resetInput()
        activeTouch = touch
      }
      if let activeTouch { append(activeTouch) }
      setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let touch = activeTouch, touches.contains(touch) else { return }
      for sample in event?.coalescedTouches(for: touch) ?? [touch] { append(sample) }
      predictedSamples =
        input.held == nil && input.moveStart == nil
        ? (event?.predictedTouches(for: touch) ?? []).map { sample($0) } : []
      setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let touch = activeTouch, touches.contains(touch) else { return }
      append(touch)
      finish()
      activeTouch = nil
      configureScrolling()
      setNeedsDisplay()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let touch = activeTouch, touches.contains(touch) else { return }
      resetInput()
      activeTouch = nil
      configureScrolling()
      setNeedsDisplay()
    }
    func checkPagePull() {
      guard let scroll = observedScroll, configuration?.onAppendPage != nil,
        !pullTriggered, scroll.isDragging, activeTouch?.type != .pencil
      else { return }
      let bottom = max(
        -scroll.adjustedContentInset.top,
        scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
      let overshoot = scroll.contentOffset.y - bottom
      guard overshoot > 70 else {
        pullStarted = nil
        configuration?.onPagePull?(0)
        return
      }
      let now = ProcessInfo.processInfo.systemUptime
      if pullStarted == nil { pullStarted = now }
      let progress = min(1, (now - (pullStarted ?? now)) / 0.45)
      configuration?.onPagePull?(progress)
      if progress >= 1 {
        pullTriggered = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        configuration?.onAppendPage?()
        configuration?.onPagePull?(0)
      }
    }
    @objc private func scrollGesture(_ gesture: UIPanGestureRecognizer) {
      if gesture.state == .began {
        pullStarted = nil
        pullTriggered = false
      }
      if gesture.state == .ended || gesture.state == .cancelled {
        pullStarted = nil
        configuration?.onPagePull?(0)
      }
      checkPagePull()
    }
    private lazy var boardPan = UIPanGestureRecognizer(
      target: self, action: #selector(panBoard(_:)))
    private lazy var boardPinch = UIPinchGestureRecognizer(
      target: self, action: #selector(pinchBoard(_:)))
    private var panBase: ViewTransform?
    private var pinchBase: ViewTransform?
    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      (gestureRecognizer === boardPan && otherGestureRecognizer === boardPinch)
        || (gestureRecognizer === boardPinch && otherGestureRecognizer === boardPan)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
      -> Bool
    {
      touch.type == .direct && touch.majorRadius < 60 && activeTouch?.type != .pencil
    }
    func configureScrolling() {
      let board = configuration?.viewport != nil
      if boardPan.view == nil {
        boardPan.minimumNumberOfTouches = 2
        boardPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        boardPinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        boardPan.delegate = self
        boardPinch.delegate = self
        addGestureRecognizer(boardPan)
        addGestureRecognizer(boardPinch)
      }
      boardPan.minimumNumberOfTouches = configuration?.pencilOnly == true || pencilSeen ? 1 : 2
      let pencilActive = activeTouch?.type == .pencil
      boardPan.isEnabled = board && !pencilActive
      boardPinch.isEnabled = board && !pencilActive
      var ancestor = superview
      while let view = ancestor {
        if let scroll = view as? UIScrollView {
          // Scroll recognizers must never consume Pencil events or cancel an active Pencil stroke.
          scroll.delaysContentTouches = false
          scroll.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
          ]
          scroll.panGestureRecognizer.minimumNumberOfTouches =
            configuration?.tool == .readOnly || configuration?.pencilOnly == true || pencilSeen
            ? 1 : 2
          scroll.panGestureRecognizer.isEnabled = !pencilActive
          scroll.alwaysBounceVertical = true
          if configuration?.onAppendPage != nil, observedScroll !== scroll {
            observedScroll?.panGestureRecognizer.removeTarget(
              self, action: #selector(scrollGesture(_:)))
            observedScroll = scroll
            scroll.panGestureRecognizer.addTarget(self, action: #selector(scrollGesture(_:)))
          }
        }
        ancestor = view.superview
      }
    }
    @objc private func panBoard(_ gesture: UIPanGestureRecognizer) {
      if gesture.state == .began { panBase = configuration?.viewport }
      guard boardPinch.state != .began && boardPinch.state != .changed,
        let base = panBase
      else { return }
      let delta = gesture.translation(in: self)
      configuration?.onViewportChange?(
        ViewTransform(
          scale: base.scale, offset: Point(base.offset.x + delta.x, base.offset.y + delta.y)))
      if gesture.state == .ended || gesture.state == .cancelled { panBase = nil }
    }
    @objc private func pinchBoard(_ gesture: UIPinchGestureRecognizer) {
      if gesture.state == .began { pinchBase = configuration?.viewport }
      guard let base = pinchBase else { return }
      let center = gesture.location(in: self)
      let anchor = Point(center.x, center.y)
      let world = base.documentPoint(anchor)
      let scale = min(12, max(0.1, base.scale * gesture.scale))
      configuration?.onViewportChange?(
        ViewTransform(
          scale: scale, offset: Point(anchor.x - world.x * scale, anchor.y - world.y * scale)))
      if gesture.state == .ended || gesture.state == .cancelled {
        pinchBase = nil
        panBase = configuration?.viewport
        boardPan.setTranslation(.zero, in: self)
      }
    }
    private var displayLink: CADisplayLink?
    private var displayTarget: CanvasDisplayTarget?
    override func didMoveToWindow() {
      super.didMoveToWindow()
      displayLink?.invalidate()
      displayLink = nil
      displayTarget = nil
      guard window != nil else {
        resetInput()
        return
      }
      configureScrolling()
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
        point: configuration?.viewport?.documentPoint(Point(p.x, p.y))
          ?? Point(p.x / scale, p.y / scale),
        pressure: touch.type == .pencil
          ? min(1, Double(touch.force / max(0.01, touch.maximumPossibleForce))) : 1,
        altitude: Double(touch.altitudeAngle))
    }
    func append(_ touch: UITouch) {
      guard configuration != nil else { return }
      accept(sample(touch))
    }
  }
  @MainActor private final class CanvasDisplayTarget: NSObject {
    weak var view: DrawingView?
    @objc func update() {
      guard let view else { return }
      view.checkPagePull()
      if !view.samples.isEmpty { view.setNeedsDisplay() }
    }
  }
#endif

@MainActor final class CanvasInputState {
  var holdTask: Task<Void, Never>?
  var holdPoint: Point?
  var held: Stroke?
  var resizeStart: Point?
  var moveStart: Point?
  var moveDelta = Point(0, 0)
  var selectionHandle: SelectionHandle = .move
  var selectionTransform: SelectionTransform?
}
enum SelectionHandle { case move, resize, rotate }

extension DrawingView {
  func invalidateCanvas() {
    #if os(macOS)
      needsDisplay = true
    #else
      setNeedsDisplay()
    #endif
  }
  func resetInput() {
    input.holdTask?.cancel()
    input.holdTask = nil
    input.holdPoint = nil
    input.held = nil
    input.resizeStart = nil
    input.moveStart = nil
    input.moveDelta = Point(0, 0)
    input.selectionHandle = .move
    input.selectionTransform = nil
    samples = []
    predictedSamples = []
    cachedPage = nil
  }
  func accept(_ sample: Sample) {
    guard let configuration else { return }
    if samples.isEmpty, configuration.tool == .lasso,
      let bounds = InkGestures.selectionBounds(
        page: configuration.page, ids: configuration.selection)
    {
      let scale =
        configuration.viewport?.scale ?? self.bounds.width / configuration.page.dimensions.x
      let center = Point(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
      let hitRadius = 16 / scale
      let rotate = Point(center.x, bounds.y - 30 / scale)
      let corners = [
        Point(bounds.x, bounds.y), Point(bounds.x + bounds.width, bounds.y),
        Point(bounds.x, bounds.y + bounds.height),
        Point(bounds.x + bounds.width, bounds.y + bounds.height),
      ]
      if sample.point.distance(to: rotate) < hitRadius {
        input.selectionHandle = .rotate
        input.moveStart = sample.point
      } else if corners.contains(where: { sample.point.distance(to: $0) < hitRadius }) {
        input.selectionHandle = .resize
        input.moveStart = sample.point
      } else if InkGestures.selectionContains(
        sample.point, page: configuration.page, ids: configuration.selection)
      {
        input.selectionHandle = .move
        input.moveStart = sample.point
      }
      if input.moveStart != nil { input.selectionTransform = SelectionTransform(center: center) }
    }
    if let start = input.moveStart, var transform = input.selectionTransform {
      switch input.selectionHandle {
      case .move:
        input.moveDelta = Point(sample.point.x - start.x, sample.point.y - start.y)
        transform.translation = input.moveDelta
      case .resize:
        transform.scale = max(
          0.1,
          min(
            10,
            sample.point.distance(to: transform.center)
              / max(1, start.distance(to: transform.center))))
      case .rotate:
        transform.angle =
          atan2(sample.point.y - transform.center.y, sample.point.x - transform.center.x)
          - atan2(start.y - transform.center.y, start.x - transform.center.x)
      }
      input.selectionTransform = transform
      samples = [sample]
      return
    }
    if let held = input.held, let start = input.resizeStart {
      samples = InkGestures.resizeHeldShape(held, from: start, to: sample.point).samples
      predictedSamples = []
      return
    }
    samples.append(sample)
    if configuration.tool == .eraser { cachedPage = nil }
    guard configuration.holdToShape, [.pen, .shapes].contains(configuration.tool) else { return }
    if let anchor = input.holdPoint, anchor.distance(to: sample.point) < 3 { return }
    input.holdTask?.cancel()
    input.holdPoint = sample.point
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(450))
    input.holdTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
      guard let self, let configuration = self.configuration else { return }
      let raw = Stroke(
        samples: self.samples, color: configuration.color,
        width: configuration.width, tool: configuration.tool, style: configuration.style)
      guard let shape = InkGestures.heldShape(raw) else { return }
      self.input.held = shape
      self.input.resizeStart = self.samples.last?.point
      self.samples = shape.samples
      self.predictedSamples = []
      self.invalidateCanvas()
      #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
      #endif
    }
  }
  func paint(_ configuration: CanvasConfiguration, _ c: CGContext) {
    guard bounds.width > 0, bounds.height > 0 else { return }
    var configuration = configuration
    if let transform = input.selectionTransform {
      configuration.page = InkGestures.transform(
        configuration.page, ids: configuration.selection, by: transform)
    }
    if configuration.tool == .eraser, !samples.isEmpty {
      for sample in samples {
        configuration.page.strokes = Editing.erase(
          strokes: configuration.page.strokes,
          at: sample.point, radius: max(8, configuration.width), mode: configuration.eraserMode,
          highlighterOnly: configuration.highlighterOnly)
      }
    }
    c.saveGState()
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fill(bounds)
    let cacheRect: CGRect
    if let viewport = configuration.viewport {
      c.translateBy(x: viewport.offset.x, y: viewport.offset.y)
      c.scaleBy(x: viewport.scale, y: viewport.scale)
      let origin = viewport.documentPoint(Point(0, 0))
      cacheRect = CGRect(
        x: origin.x, y: origin.y, width: bounds.width / viewport.scale,
        height: bounds.height / viewport.scale)
    } else {
      let scale = bounds.width / configuration.page.dimensions.x
      c.scaleBy(x: scale, y: scale)
      cacheRect = CGRect(
        x: 0, y: 0, width: configuration.page.dimensions.x, height: configuration.page.dimensions.y)
    }
    // Cache the visible world at device resolution, including negative coordinates on a whiteboard.
    let resolution = min(hypot(c.ctm.a, c.ctm.b), 4096 / max(cacheRect.width, cacheRect.height))
    if abs(resolution - cachedResolution) > 0.001 || cachedViewport != configuration.viewport {
      cachedPage = nil
    }
    if cachedPage == nil,
      let layer = CGLayer(
        c, size: CGSize(width: cacheRect.width * resolution, height: cacheRect.height * resolution),
        auxiliaryInfo: nil), let context = layer.context
    {
      context.scaleBy(x: resolution, y: resolution)
      context.translateBy(x: -cacheRect.minX, y: -cacheRect.minY)
      var background = configuration.page
      if input.moveStart != nil {
        background.strokes.removeAll { configuration.selection.contains($0.id) }
        background.images.removeAll { configuration.selection.contains($0.id) }
        background.texts.removeAll { configuration.selection.contains($0.id) }
      }
      PageRenderer.render(background, assets: configuration.assets, in: context)
      cachedPage = layer
      cachedResolution = resolution
      cachedViewport = configuration.viewport
    }
    if let cachedPage { c.draw(cachedPage, in: cacheRect) }
    c.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 0.25))
    for r in configuration.searchHighlights {
      c.fill(CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
    }
    if input.moveStart != nil {
      var moving = configuration.page
      moving.strokes.removeAll { !configuration.selection.contains($0.id) }
      moving.images.removeAll { !configuration.selection.contains($0.id) }
      moving.texts.removeAll { !configuration.selection.contains($0.id) }
      PageRenderer.render(moving, assets: configuration.assets, in: c, includeBackground: false)
    }
    if !samples.isEmpty {
      if configuration.tool == .lasso && input.moveStart == nil {
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
    if let b = InkGestures.selectionBounds(page: configuration.page, ids: configuration.selection) {
      let scale = configuration.viewport?.scale ?? bounds.width / configuration.page.dimensions.x
      c.setLineWidth(1.5 / scale)
      c.stroke(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
      c.setLineDash(phase: 0, lengths: [])
      let center = Point(b.x + b.width / 2, b.y + b.height / 2)
      let rotate = Point(center.x, b.y - 30 / scale)
      c.move(to: CGPoint(x: center.x, y: b.y))
      c.addLine(to: CGPoint(x: rotate.x, y: rotate.y))
      c.strokePath()
      c.setFillColor(CGColor(gray: 1, alpha: 1))
      for point in [
        Point(b.x, b.y), Point(b.x + b.width, b.y), Point(b.x, b.y + b.height),
        Point(b.x + b.width, b.y + b.height), rotate,
      ] {
        let circle = CGRect(
          x: point.x - 5 / scale, y: point.y - 5 / scale, width: 10 / scale, height: 10 / scale)
        c.fillEllipse(in: circle)
        c.strokeEllipse(in: circle)
      }
    }
    c.restoreGState()
  }
  func finish() {
    guard let configuration, let first = samples.first else {
      samples = []
      return
    }
    input.holdTask?.cancel()
    if let transform = input.selectionTransform {
      if abs(transform.scale - 1) > 0.001 || abs(transform.angle) > 0.001
        || hypot(transform.translation.x, transform.translation.y) > 0.5
      {
        if let onTransform = configuration.onTransformSelection {
          onTransform(transform)
        } else {
          configuration.onTranslateSelection?(transform.translation)
        }
      } else {
        configuration.onSelectionMenu?()
      }
      resetInput()
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
    resetInput()
  }
}
