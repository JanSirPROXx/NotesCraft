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
  var horizontalPages = false
  var onScrollActivity: (() -> Void)? = nil
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
    }
  }
  @MainActor final class DrawingView: NSView {
    var configuration: CanvasConfiguration? {
      didSet {
        updatePageCache(from: oldValue, to: configuration)
        if Self.affectsPixels(oldValue, configuration) { needsDisplay = true }
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
      paint(configuration, c, dirty: dirtyRect)
    }
    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      resetInput()
      append(event)
      needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
      append(event)
      invalidateInk()
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
        let horizontal = configuration?.horizontalPages == true
        let bottom =
          horizontal
          ? scroll.contentView.bounds.maxX >= content.bounds.maxX - 2
          : scroll.contentView.bounds.maxY >= content.bounds.maxY - 2
        let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        if bottom && delta < 0 && !pullTriggered && event.momentumPhase.isEmpty {
          pullDistance -= delta
          let now = ProcessInfo.processInfo.systemUptime
          if pullStarted == nil { pullStarted = now }
          let progress = min(1, min(pullDistance / 100, (now - (pullStarted ?? now)) / 0.45))
          configuration?.onPagePull?(progress)
          if progress >= 1 {
            pullTriggered = true
            configuration?.onAppendPage?()
          }
        } else if !bottom || delta > 0 {
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
      view.isOpaque = true
      view.clearsContextBeforeDrawing = false
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
    }
  }
  @MainActor
  final class DrawingView: UIView, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
    var configuration: CanvasConfiguration? {
      didSet {
        updatePageCache(from: oldValue, to: configuration)
        if Self.affectsPixels(oldValue, configuration) { setNeedsDisplay() }
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
      paint(configuration, c, dirty: rect)
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
        if !pencilSeen {
          pencilSeen = true
          configuration.onPencilDetected?()
        }
        resetInput()
        activeTouch = pencil
        configureScrolling()
      } else {
        // A finger never inks while Pencil-only is on, but it must still operate objects:
        // tapping images/text/elements and dragging an existing lasso selection.
        guard activeTouch == nil,
          let touch = touches.first(where: { $0.type == .direct && $0.majorRadius < 60 })
        else { return }
        let operatesObjects =
          [.readOnly, .image, .text, .elements].contains(configuration.tool)
          || (configuration.tool == .lasso
            && selectionHit(at: sample(touch).point, configuration) != nil)
        guard operatesObjects || (!pencilSeen && !configuration.pencilOnly) else { return }
        resetInput()
        activeTouch = touch
      }
      if let activeTouch { append(activeTouch) }
      // A finger that grabbed a selection handle must move it instead of scrolling the page.
      if input.moveStart != nil { configureScrolling() }
      updateDisplayLink()
      setNeedsDisplay()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let touch = activeTouch, touches.contains(touch) else { return }
      for sample in event?.coalescedTouches(for: touch) ?? [touch] { append(sample) }
      predictedSamples =
        input.held == nil && input.moveStart == nil
        ? (event?.predictedTouches(for: touch) ?? []).map { sample($0) } : []
      invalidateInk()
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
      let horizontal = configuration?.horizontalPages == true
      let end =
        horizontal
        ? max(
          -scroll.adjustedContentInset.left,
          scroll.contentSize.width - scroll.bounds.width + scroll.adjustedContentInset.right)
        : max(
          -scroll.adjustedContentInset.top,
          scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
      let overshoot = (horizontal ? scroll.contentOffset.x : scroll.contentOffset.y) - end
      guard overshoot > 60 else {
        pullStarted = nil
        configuration?.onPagePull?(0)
        return
      }
      let now = ProcessInfo.processInfo.systemUptime
      if pullStarted == nil { pullStarted = now }
      let progress = min(1, (now - (pullStarted ?? now)) / 0.2)
      configuration?.onPagePull?(progress)
      if progress >= 1 {
        pullTriggered = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        configuration?.onAppendPage?()
        configuration?.onPagePull?(0)
      }
    }
    @objc private func scrollGesture(_ gesture: UIPanGestureRecognizer) {
      updateDisplayLink()
      if gesture.state == .began {
        pullStarted = nil
        pullTriggered = false
      }
      if gesture.state == .ended || gesture.state == .cancelled {
        pullStarted = nil
        configuration?.onPagePull?(0)
      }
      if gesture.state == .changed,
        abs(gesture.velocity(in: self).x) + abs(gesture.velocity(in: self).y) > 250
      {
        configuration?.onScrollActivity?()
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
      let pencilActive = activeTouch?.type == .pencil || input.moveStart != nil
      boardPan.isEnabled = board && !pencilActive
      boardPinch.isEnabled = board && !pencilActive
      var ancestor = superview
      var paperIsZooming = false
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
          if let paper = scroll as? NotebookZoomScrollView { paperIsZooming = paper.isZooming }
          scroll.panGestureRecognizer.isEnabled =
            !pencilActive
            && (scroll is NotebookZoomScrollView || !paperIsZooming)
          if let paper = scroll as? NotebookZoomScrollView {
            paper.pinchGestureRecognizer?.isEnabled = paper.allowsZoom && !pencilActive
          }
          if !(scroll is NotebookZoomScrollView) {
            // A page swipe should settle quickly onto the target page rather than glide.
            scroll.decelerationRate = .fast
            scroll.alwaysBounceVertical = configuration?.horizontalPages != true
            scroll.alwaysBounceHorizontal = configuration?.horizontalPages == true
          }
          if !(scroll is NotebookZoomScrollView), observedScroll !== scroll {
            observedScroll?.panGestureRecognizer.removeTarget(
              self, action: #selector(scrollGesture(_:)))
            observedScroll = scroll
            scroll.panGestureRecognizer.addTarget(self, action: #selector(scrollGesture(_:)))
          }
        }
        ancestor = view.superview
      }
      updateDisplayLink()
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
    private func updateDisplayLink() {
      displayLink?.isPaused =
        activeTouch == nil
        && !(configuration?.onAppendPage != nil && observedScroll?.isDragging == true)
    }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      displayLink?.invalidate()
      displayLink = nil
      displayTarget = nil
      guard window != nil else {
        activeTouch = nil
        resetInput()
        cachedPage = nil
        observedScroll?.panGestureRecognizer.removeTarget(
          self, action: #selector(scrollGesture(_:)))
        observedScroll = nil
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
      updateDisplayLink()
    }
    func sample(_ touch: UITouch) -> Sample {
      let p = touch.type == .pencil ? touch.preciseLocation(in: self) : touch.location(in: self)
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
    }
  }
#endif

@MainActor final class CanvasInputState {
  var liveLayer: CGLayer?
  var liveRect = CGRect.zero
  var liveResolution = 0.0
  var bakedThrough = 0
  var renderedSegments = 0
  var pendingStroke: Stroke?
  var holdTask: Task<Void, Never>?
  var holdDeadline: ContinuousClock.Instant?
  var holdPoint: Point?
  var held: Stroke?
  var resizeStart: Point?
  var moveStart: Point?
  var moveDelta = Point(0, 0)
  var selectionHandle: SelectionHandle = .move
  var selectionTransform: SelectionTransform?
  var invalidatedSamples = 0
  var lastInkRect = CGRect.null
}
enum SelectionHandle { case move, resize, rotate }

extension DrawingView {
  // SwiftUI re-applies the configuration on every state change, including a color tap.
  // Data equality is a full memcmp, so identical backing storage is checked first to keep
  // those updates from rescanning megabytes of PDF background per visible page.
  static func sameAssets(_ a: [String: Data], _ b: [String: Data]) -> Bool {
    guard a.count == b.count else { return false }
    for (key, left) in a {
      guard let right = b[key], left.count == right.count else { return false }
      let shared = left.withUnsafeBytes { l in
        right.withUnsafeBytes { r in l.baseAddress == r.baseAddress }
      }
      if !shared && left != right { return false }
    }
    return true
  }
  // Color, pen style and width only matter to the next stroke, so they must not repaint.
  static func affectsPixels(_ old: CanvasConfiguration?, _ new: CanvasConfiguration?) -> Bool {
    guard let old, let new else { return true }
    if old.tool != new.tool || old.selection != new.selection || old.viewport != new.viewport
      || old.searchHighlights != new.searchHighlights || old.page != new.page
      || !sameAssets(old.assets, new.assets)
    {
      return true
    }
    return new.tool == .eraser
      && (old.width != new.width || old.eraserMode != new.eraserMode
        || old.highlighterOnly != new.highlighterOnly)
  }
  func updatePageCache(from old: CanvasConfiguration?, to new: CanvasConfiguration?) {
    guard old?.page != new?.page
      || !Self.sameAssets(old?.assets ?? [:], new?.assets ?? [:])
    else { return }
    defer { input.pendingStroke = nil }
    if let old, let new, let pending = input.pendingStroke,
      pending.tool == .pen, Self.sameAssets(old.assets, new.assets),
      old.viewport == new.viewport, input.moveStart == nil,
      new.page.strokes.last == pending, let context = cachedPage?.context
    {
      var previous = new.page
      previous.strokes.removeLast()
      if previous == old.page {
        PageRenderer.stroke(pending, in: context)
        return
      }
    }
    cachedPage = nil
  }
  func invalidateCanvas() {
    #if os(macOS)
      needsDisplay = true
    #else
      setNeedsDisplay()
    #endif
  }
  func viewPoint(_ point: Point) -> CGPoint {
    guard let configuration else { return .zero }
    if let viewport = configuration.viewport {
      return CGPoint(
        x: point.x * viewport.scale + viewport.offset.x,
        y: point.y * viewport.scale + viewport.offset.y)
    }
    let scale = bounds.width / configuration.page.dimensions.x
    return CGPoint(x: point.x * scale, y: point.y * scale)
  }
  // Pen and highlighter strokes only change near the newest samples, so repaint just that
  // neighbourhood plus the previous provisional/predicted tail. Other tools (eraser,
  // lasso, held shapes) change pixels anywhere and keep the full invalidation.
  func invalidateInk() {
    guard let configuration, [.pen, .highlighter].contains(configuration.tool),
      input.held == nil, input.moveStart == nil, input.resizeStart == nil
    else {
      input.invalidatedSamples = samples.count
      input.lastInkRect = .null
      invalidateCanvas()
      return
    }
    let scale = configuration.viewport?.scale ?? bounds.width / configuration.page.dimensions.x
    // Brush tilt and pressure can widen a segment to roughly 3.4x the nominal width.
    let pad = max(8, configuration.width * scale * 4 + 4)
    var rect = CGRect.null
    for sample in samples.suffix(from: max(0, input.invalidatedSamples - 4)) + predictedSamples {
      let p = viewPoint(sample.point)
      rect = rect.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
    }
    let fresh = rect.insetBy(dx: -pad, dy: -pad)
    let dirty = fresh.union(input.lastInkRect)
    input.lastInkRect = fresh
    input.invalidatedSamples = samples.count
    setNeedsDisplay(dirty.isNull ? bounds : dirty.intersection(bounds))
  }
  func resetInput() {
    if input.moveStart != nil || (configuration?.tool == .eraser && !samples.isEmpty) {
      cachedPage = nil
    }
    input.liveLayer = nil
    input.bakedThrough = 0
    input.renderedSegments = 0
    input.holdTask?.cancel()
    input.holdTask = nil
    input.holdDeadline = nil
    input.holdPoint = nil
    input.held = nil
    input.resizeStart = nil
    input.moveStart = nil
    input.moveDelta = Point(0, 0)
    input.selectionHandle = .move
    input.selectionTransform = nil
    input.invalidatedSamples = 0
    input.lastInkRect = .null
    samples = []
    predictedSamples = []
  }
  func selectionHit(at point: Point, _ configuration: CanvasConfiguration) -> (
    handle: SelectionHandle, center: Point
  )? {
    guard
      let bounds = InkGestures.selectionBounds(
        page: configuration.page, ids: configuration.selection)
    else { return nil }
    let scale = configuration.viewport?.scale ?? self.bounds.width / configuration.page.dimensions.x
    let center = Point(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
    // Finger-sized targets: 16 pt keeps Pencil precision, 24 pt lets a fingertip grab a handle.
    let hitRadius = 24 / scale
    let rotate = Point(center.x, bounds.y - 30 / scale)
    let corners = [
      Point(bounds.x, bounds.y), Point(bounds.x + bounds.width, bounds.y),
      Point(bounds.x, bounds.y + bounds.height),
      Point(bounds.x + bounds.width, bounds.y + bounds.height),
    ]
    if point.distance(to: rotate) < hitRadius { return (.rotate, center) }
    if corners.contains(where: { point.distance(to: $0) < hitRadius }) { return (.resize, center) }
    if InkGestures.selectionContains(point, page: configuration.page, ids: configuration.selection)
    {
      return (.move, center)
    }
    return nil
  }
  func accept(_ sample: Sample) {
    guard let configuration else { return }
    if samples.isEmpty, configuration.tool == .lasso,
      let hit = selectionHit(at: sample.point, configuration)
    {
      input.selectionHandle = hit.handle
      input.moveStart = sample.point
      input.selectionTransform = SelectionTransform(center: hit.center)
      cachedPage = nil
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
    input.holdPoint = sample.point
    input.holdDeadline = ContinuousClock.now.advanced(by: .milliseconds(450))
    guard input.holdTask == nil else { return }
    input.holdTask = Task { @MainActor [weak self] in
      while let deadline = self?.input.holdDeadline {
        do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
        guard let self, let configuration = self.configuration else { return }
        guard deadline == self.input.holdDeadline else { continue }
        self.input.holdTask = nil
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
        return
      }
    }
  }
  func paint(_ configuration: CanvasConfiguration, _ c: CGContext, dirty: CGRect? = nil) {
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
    // While inking only a few points change per frame; clipping keeps the page blit and
    // the white fill proportional to the stroke tail instead of the whole screen.
    if let dirty, dirty != bounds { c.clip(to: dirty) }
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
      PageRenderer.render(
        background, assets: configuration.assets, in: context,
        paperBounds: configuration.viewport == nil ? nil : cacheRect)
      cachedPage = layer
      cachedResolution = resolution
      cachedViewport = configuration.viewport
    }
    if let cachedPage { c.draw(cachedPage, in: cacheRect) }
    if let pending = input.pendingStroke {
      if configuration.page.strokes.contains(where: { $0.id == pending.id }) {
        input.pendingStroke = nil
      } else {
        PageRenderer.stroke(pending, in: c)
      }
    }
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
        if configuration.tool == .pen, input.held == nil, samples.count > 5 {
          paintLiveInk(configuration, in: c, rect: cacheRect, resolution: resolution)
        } else {
          PageRenderer.stroke(
            Stroke(
              samples: samples + predictedSamples, color: configuration.color,
              width: configuration.width, tool: configuration.tool, style: configuration.style),
            in: c
          )
        }
      }
    }
    c.setLineDash(phase: 0, lengths: [4, 3])
    c.setStrokeColor(PageRenderer.color(.blue))
    c.setLineWidth(1)
    if !configuration.selection.isEmpty,
      let b = InkGestures.selectionBounds(page: configuration.page, ids: configuration.selection)
    {
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
      let stroke = Stroke(
        samples: samples, color: configuration.color, width: configuration.width,
        tool: configuration.tool, style: configuration.style)
      input.pendingStroke = stroke
      configuration.onStroke(stroke)
    case .eraser, .lasso: configuration.onGesture(samples.map(\.point))
    case .text, .image, .elements: configuration.onTap(first.point)
    case .readOnly:
      if let last = samples.last, first.point.distance(to: last.point) < 5 {
        configuration.onTap(first.point)
      }
    }
    resetInput()
  }
  private func paintLiveInk(
    _ configuration: CanvasConfiguration, in c: CGContext, rect: CGRect, resolution: Double
  ) {
    if input.liveRect != rect || abs(input.liveResolution - resolution) > 0.001 {
      input.liveLayer = nil
      input.bakedThrough = 0
    }
    if input.liveLayer == nil {
      input.liveLayer = CGLayer(
        c, size: CGSize(width: rect.width * resolution, height: rect.height * resolution),
        auxiliaryInfo: nil)
      input.liveRect = rect
      input.liveResolution = resolution
      if let context = input.liveLayer?.context {
        context.scaleBy(x: resolution, y: resolution)
        context.translateBy(x: -rect.minX, y: -rect.minY)
      }
    }
    guard let layer = input.liveLayer, let context = layer.context else {
      PageRenderer.stroke(
        Stroke(
          samples: samples + predictedSamples, color: configuration.color,
          width: configuration.width, tool: .pen, style: configuration.style), in: c)
      return
    }
    let stableEnd = samples.count - 2
    if stableEnd > input.bakedThrough {
      let range = (input.bakedThrough + 1)..<(stableEnd + 1)
      PageRenderer.smoothInkSegments(
        samples, range: range, color: configuration.color,
        width: configuration.width, style: configuration.style, in: context)
      input.renderedSegments += range.count
      input.bakedThrough = stableEnd
    }
    c.draw(layer, in: rect)
    let tail = Array(samples.suffix(3)) + predictedSamples
    // Include one already-baked sample to preserve the tail's midpoint tangent.
    PageRenderer.smoothInkSegments(
      tail, range: 2..<tail.count, color: configuration.color,
      width: configuration.width, style: configuration.style, in: c, finish: true)
    input.renderedSegments += max(0, tail.count - 2)
  }
}

#if os(iOS)
  // Each paper has its own native zoom surface. The outer scroll view remains responsible for paging.
  @MainActor final class NotebookZoomScrollView: UIScrollView {
    var allowsZoom = true
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer === panGestureRecognizer {
        guard zoomScale > minimumZoomScale + 0.01 else { return false }
        let velocity = panGestureRecognizer.velocity(in: self)
        let horizontal = abs(velocity.x) > abs(velocity.y)
        let position = horizontal ? contentOffset.x : contentOffset.y
        let maximum =
          horizontal ? contentSize.width - bounds.width : contentSize.height - bounds.height
        let delta = horizontal ? velocity.x : velocity.y
        // Outward gestures at an edge go to the parent, so paging also works while zoomed.
        if (position <= 1 && delta > 0) || (position >= maximum - 1 && delta < 0) { return false }
      }
      return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
  }

  struct ZoomableNotebookPage<Content: View>: UIViewControllerRepresentable {
    let contentSize: CGSize
    let viewportSize: CGSize
    let pencilOnly: Bool
    let zoomEnabled: Bool
    var initialZoom: Double = 1
    var onZoomChange: (Double) -> Void = { _ in }
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController {
      let controller = UIViewController()
      let scroll = context.coordinator.scroll
      scroll.delegate = context.coordinator
      scroll.minimumZoomScale = 1
      scroll.maximumZoomScale = 6
      scroll.showsHorizontalScrollIndicator = false
      scroll.showsVerticalScrollIndicator = false
      scroll.backgroundColor = .clear
      scroll.bounces = false
      scroll.bouncesZoom = true
      scroll.pinchGestureRecognizer?.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
      ]
      controller.view = scroll
      let host = UIHostingController(rootView: content())
      host.view.backgroundColor = .clear
      controller.addChild(host)
      scroll.addSubview(host.view)
      host.didMove(toParent: controller)
      context.coordinator.host = host
      return controller
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
      let coordinator = context.coordinator
      coordinator.onZoomChange = onZoomChange
      coordinator.updating = true
      defer { coordinator.updating = false }
      coordinator.host?.rootView = content()
      let scroll = coordinator.scroll
      scroll.allowsZoom = zoomEnabled
      scroll.pinchGestureRecognizer?.isEnabled = zoomEnabled
      scroll.panGestureRecognizer.allowedTouchTypes = [
        NSNumber(value: UITouch.TouchType.direct.rawValue)
      ]
      scroll.panGestureRecognizer.minimumNumberOfTouches = pencilOnly ? 1 : 2
      if coordinator.paperSize != contentSize || coordinator.viewportSize != viewportSize {
        let scale = coordinator.paperSize == .zero ? initialZoom : Double(scroll.zoomScale)
        scroll.setZoomScale(1, animated: false)
        coordinator.paperSize = contentSize
        coordinator.viewportSize = viewportSize
        coordinator.host?.view.frame = CGRect(origin: .zero, size: contentSize)
        scroll.contentSize = contentSize
        coordinator.centerPaper()
        scroll.setZoomScale(min(6, max(1, scale)), animated: false)
        scroll.contentOffset = .zero
      }
    }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
      let scroll = NotebookZoomScrollView()
      var host: UIHostingController<Content>?
      var paperSize = CGSize.zero
      var viewportSize = CGSize.zero
      var onZoomChange: (Double) -> Void = { _ in }
      var updating = false
      weak var pagingScroll: UIScrollView?
      var pagingPanEnabled = true
      func viewForZooming(in scrollView: UIScrollView) -> UIView? { host?.view }
      func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard !updating else { return }
        var ancestor = scrollView.superview
        while let view = ancestor {
          if let outer = view as? UIScrollView {
            pagingScroll = outer
            pagingPanEnabled = outer.panGestureRecognizer.isEnabled
            outer.panGestureRecognizer.isEnabled = false
            break
          }
          ancestor = view.superview
        }
      }
      func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerPaper()
        if !updating { onZoomChange(Double(scrollView.zoomScale)) }
      }
      func scrollViewDidEndZooming(
        _ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat
      ) {
        if !updating {
          pagingScroll?.panGestureRecognizer.isEnabled = pagingPanEnabled
          pagingScroll = nil
        }
        func refresh(_ view: UIView) {
          if let canvas = view as? DrawingView {
            canvas.contentScaleFactor = UIScreen.main.scale * min(4, scrollView.zoomScale)
            canvas.cachedPage = nil
            canvas.setNeedsDisplay()
          }
          for child in view.subviews { refresh(child) }
        }
        if let view { refresh(view) }
      }
      func centerPaper() {
        guard let view = host?.view else { return }
        view.center = CGPoint(
          x: max(viewportSize.width, scroll.contentSize.width) / 2,
          y: max(viewportSize.height, scroll.contentSize.height) / 2)
        scroll.accessibilityValue = "Zoom \(Int(scroll.zoomScale * 100)) percent"
        scroll.accessibilityIdentifier = "notebookZoomSurface"
      }
    }
  }
#endif
