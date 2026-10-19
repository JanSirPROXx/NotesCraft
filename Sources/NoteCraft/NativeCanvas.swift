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
  // A long finger press on empty paper (document point), e.g. to offer "Paste" there.
  var onLongPress: ((Point) -> Void)? = nil
  var onTouchDown: (() -> Void)? = nil
  var onPencilDetected: (() -> Void)? = nil
  var onPencilAction: ((PencilAction) -> Void)? = nil
  var onAppendPage: (() -> Void)? = nil
  var onPagePull: ((Double) -> Void)? = nil
  var horizontalPages = false
  var onScrollActivity: (() -> Void)? = nil
  var holdToShape = true
  // Marks the ink a scribble would take away while it is still being drawn.
  var scribblePreview = false
  // Draws the live pen stroke on the GPU (iOS); off falls back to CoreGraphics.
  var gpuInk = true
  var eraserMode: EraserMode = .stroke
  var highlighterOnly = false
  var searchHighlights: [Rect] = []
  var tip: PenTip = .standard
  var stabilization = 0.0
  // With the shapes tool: the shape inserted by tapping or dragging; nil keeps freehand recognition.
  var shapeKind: ShapeKind? = nil
}
// What a Pencil double tap or squeeze should do, as chosen in Settings > Apple Pencil.
enum PencilAction {
  case switchEraser, switchPrevious, showPalette
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
        _ = updatePageCache(from: oldValue, to: configuration)
        if Self.affectsPixels(oldValue, configuration) { needsDisplay = true }
      }
    }
    // Dropping the cache also retires any background rebuild still in flight, and keeps the
    // dropped layer to show until the new one is ready.
    var cachedPage: CGLayer? {
      didSet {
        guard cachedPage == nil else { return }
        input.cacheGeneration += 1
        if let oldValue { input.staleCache = oldValue }
      }
    }
    var cachedResolution = 0.0
    var cachedViewport: ViewTransform?
    let input = CanvasInputState()
    var samples: [Sample] = []
    var predictedSamples: [Sample] = []
    // The live stroke is drawn straight into the view on macOS.
    var drawsInkInOverlay: Bool { false }
    var drawsInkOnGPU: Bool { false }
    func clearGPUInk() {}
    func metalInkClearNow() {}
    func invalidateOverlay(_ rect: CGRect? = nil) {}
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
      // Opaque and never drawn shows black. After the app returns from the background the view
      // can be laid out at a new size without UIKit asking for a redraw, so ask for it always.
      view.contentMode = .redraw
      view.contentScaleFactor = UIScreen.main.scale
      let pencil = UIPencilInteraction()
      pencil.delegate = view
      view.addInteraction(pencil)
      view.addGestureRecognizer(
        UIHoverGestureRecognizer(target: view, action: #selector(DrawingView.hover(_:))))
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
        // A pen stroke that was only appended changes the pixels inside its own box: repainting
        // the whole page for it would re-blit the full cache after every stroke of a word.
        let appended = updatePageCache(from: oldValue, to: configuration)
        if Self.affectsPixels(oldValue, configuration, ignoringPage: appended != nil) {
          setNeedsDisplay()
        } else if let appended {
          setNeedsDisplay(appended)
        }
        #if os(iOS)
          if oldValue?.pencilOnly == true && configuration?.pencilOnly == false {
            pencilSeen = false
          }
        #endif
      }
    }
    // Dropping the cache also retires any background rebuild still in flight, and keeps the
    // dropped layer to show until the new one is ready.
    var cachedPage: CGLayer? {
      didSet {
        guard cachedPage == nil else { return }
        input.cacheGeneration += 1
        if let oldValue { input.staleCache = oldValue }
      }
    }
    var cachedResolution = 0.0
    var cachedViewport: ViewTransform?
    let input = CanvasInputState()
    var samples: [Sample] = []
    var predictedSamples: [Sample] = []
    override func draw(_ rect: CGRect) {
      guard let c = UIGraphicsGetCurrentContext(), let configuration else { return }
      paint(configuration, c, dirty: rect)
    }
    // The stroke being written lives on its own transparent view. Each new sample then repaints
    // only a sliver of ink instead of re-blitting the cached page beneath it, and the compositor
    // blends the two on the GPU. The page view is only touched again when the pen lifts.
    private(set) var inkOverlay: InkOverlayView?
    var drawsInkInOverlay: Bool { inkOverlay != nil }
    private(set) var metalInk: MetalInkView?
    var drawsInkOnGPU: Bool { metalInk != nil && configuration?.gpuInk == true }
    override var contentScaleFactor: CGFloat {
      didSet {
        inkOverlay?.contentScaleFactor = contentScaleFactor
        metalInk?.contentScaleFactor = contentScaleFactor
      }
    }
    override func layoutSubviews() {
      super.layoutSubviews()
      inkOverlay?.frame = bounds
      metalInk?.frame = bounds
    }
    private func installInkOverlay() {
      guard inkOverlay == nil else { return }
      let overlay = InkOverlayView(frame: bounds)
      overlay.owner = self
      overlay.isOpaque = false
      overlay.backgroundColor = .clear
      overlay.isUserInteractionEnabled = false
      overlay.clearsContextBeforeDrawing = true
      overlay.contentScaleFactor = contentScaleFactor
      addSubview(overlay)
      inkOverlay = overlay
      // Above the overlay: the live stroke is the topmost thing on the page.
      if let gpu = MetalInkView.make(frame: bounds) {
        gpu.contentScaleFactor = contentScaleFactor
        addSubview(gpu)
        metalInk = gpu
      }
    }
    func invalidateOverlay(_ rect: CGRect? = nil) {
      guard let inkOverlay else { return }
      if let rect { inkOverlay.setNeedsDisplay(rect) } else { inkOverlay.setNeedsDisplay() }
    }
    // Draws what the pen laid down since the last frame. Samples arrive many times per frame; the
    // work is done once per display frame (and mid-frame while low-latency dispatch is on), and
    // only the new segments plus the unstable tail are handed to the GPU.
    func renderLiveInkIfNeeded() {
      guard input.gpuInkDirty, let metalInk, let configuration, configuration.gpuInk,
        configuration.tool == .pen, input.held == nil, input.moveStart == nil,
        input.resizeStart == nil, !samples.isEmpty, bounds.width > 0
      else { return }
      input.gpuInkDirty = false
      let lost = metalInk.fitDrawable()
      if lost { input.bakedThrough = 0 }
      let pixelScale = metalInk.pixelScale
      let docScale = configuration.viewport?.scale ?? bounds.width / configuration.page.dimensions.x
      let offset = configuration.viewport?.offset ?? Point(0, 0)
      let count = samples.count
      let uniforms = InkUniforms(
        color: SIMD4(
          Float(configuration.color.red), Float(configuration.color.green),
          Float(configuration.color.blue), 1),
        offset: SIMD2(Float(offset.x * pixelScale), Float(offset.y * pixelScale)),
        viewport: SIMD2(Float(metalInk.surface.width), Float(metalInk.surface.height)),
        scale: Float(docScale * pixelScale))
      let fountain = configuration.style == .fountain && input.fountainWidths.count == count
      let widths = fountain ? input.fountainWidths : nil
      var bake: [InkCone] = []
      // Segments up to the second-to-last sample are final; the rest is redrawn every frame.
      let stableEnd = count - 2
      if stableEnd > input.bakedThrough {
        bake = InkTessellator.cones(
          samples, range: (input.bakedThrough + 1)..<(stableEnd + 1), width: configuration.width,
          style: configuration.style, widths: widths, finish: false,
          pixelScale: docScale * pixelScale)
        input.bakedThrough = stableEnd
      }
      let context = min(3, count)
      let tailSamples = Array(samples.suffix(context)) + predictedSamples
      var tailWidths: [Double]?
      if fountain {
        var state = input.fountain
        tailWidths =
          Array(input.fountainWidths.suffix(context))
          + predictedSamples.map {
            FountainInk.advance(
              &state, sample: $0, base: configuration.width, tip: configuration.tip)
          }
      }
      var tail = InkTessellator.cones(
        tailSamples, range: (max(1, count - 1) - (count - context))..<tailSamples.count,
        width: configuration.width, style: configuration.style, widths: tailWidths, finish: true,
        pixelScale: docScale * pixelScale)
      if count == 1, predictedSamples.isEmpty {
        tail = [InkTessellator.dot(at: samples[0], width: configuration.width)]
      }
      metalInk.draw(bake: bake, tail: tail, uniforms: uniforms, reset: lost)
    }
    func metalInkClearNow() { metalInk?.clear() }
    // The page cache gets the committed stroke on the next draw, so the GPU copy stays up a
    // moment (two frames of identical ink) and is only removed once nothing can show through.
    // A stroke that starts first takes over the surface at once.
    func clearGPUInk() {
      guard let metalInk, metalInk.surface.hasContent else { return }
      input.gpuInkDirty = false
      if samples.isEmpty {
        metalInk.clear()
        return
      }
      let generation = input.gpuClearGeneration
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
        guard let self, self.input.gpuClearGeneration == generation else { return }
        self.metalInk?.clear()
      }
    }
    private var activeTouch: UITouch?
    private var pencilSeen = false
    private var pullStarted: TimeInterval?
    private var pullTriggered = false
    private weak var observedScroll: UIScrollView?
    // Pencil hover and pointers show the eraser's reach before anything is touched.
    @objc func hover(_ recognizer: UIHoverGestureRecognizer) {
      guard configuration?.tool == .eraser, activeTouch == nil else { return }
      switch recognizer.state {
      case .began, .changed:
        let p = recognizer.location(in: self)
        let scale = configuration?.viewport?.scale
          ?? bounds.width / (configuration?.page.dimensions.x ?? 1)
        input.cursor = configuration?.viewport?.documentPoint(Point(p.x, p.y))
          ?? Point(p.x / scale, p.y / scale)
      default:
        input.cursor = nil
      }
      invalidateEraser()
    }
    // The system settings decide what a tap or squeeze means; "Off" must really do nothing.
    private func perform(_ preferred: UIPencilPreferredAction) {
      switch preferred {
      case .switchEraser: configuration?.onPencilAction?(.switchEraser)
      case .switchPrevious: configuration?.onPencilAction?(.switchPrevious)
      case .showColorPalette, .showInkAttributes, .showContextualPalette:
        configuration?.onPencilAction?(.showPalette)
      default: break
      }
    }
    // Before iOS 17.5 only the plain tap callback exists; from 17.5 on the system calls the
    // variants below instead.
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
      perform(UIPencilInteraction.preferredTapAction)
    }
    @available(iOS 17.5, *)
    func pencilInteraction(
      _ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap
    ) {
      perform(UIPencilInteraction.preferredTapAction)
    }
    // The squeeze of Apple Pencil Pro fires when it is released, not while it is pressed.
    @available(iOS 17.5, *)
    func pencilInteraction(
      _ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
      guard squeeze.phase == .ended else { return }
      perform(UIPencilInteraction.preferredSqueezeAction)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let configuration else { return }
      configuration.onTouchDown?()
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
          || (Self.manipulatingTools.contains(configuration.tool)
            && !configuration.selection.isEmpty
            && selectionHit(at: sample(touch).point, configuration) != nil)
        guard operatesObjects || (!pencilSeen && !configuration.pencilOnly) else { return }
        resetInput()
        activeTouch = touch
      }
      if let activeTouch { append(activeTouch) }
      if configuration.tool == .pen { invalidateInk() }
      // A finger that grabbed a selection handle must move it instead of scrolling the page.
      if input.moveStart != nil { configureScrolling() }
      updateDisplayLink()
      // Plain pen ink lives on the GPU/overlay layer: repainting the page at the moment the first
      // ink should appear would only delay it.
      if !(configuration.tool == .pen && input.moveStart == nil) { setNeedsDisplay() }
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
      // Measured before `finish` empties the samples. The committed stroke is drawn into the page
      // cache by the model update, which repaints the same box; this covers the moment before.
      var inkRect: CGRect?
      if let configuration, configuration.tool == .pen, input.held == nil,
        input.moveStart == nil, input.resizeStart == nil, input.selectionTransform == nil
      {
        inkRect = viewRect(of: samples, width: configuration.width, in: configuration)
      }
      finish()
      activeTouch = nil
      configureScrolling()
      if let inkRect { setNeedsDisplay(inkRect) } else { setNeedsDisplay() }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard let touch = activeTouch, touches.contains(touch) else { return }
      // What the eraser already wiped from the screen has to stay gone; dropping the gesture would
      // bring the ink back as soon as the page is redrawn.
      if configuration?.tool == .eraser, input.moveStart == nil, !samples.isEmpty {
        finish()
      } else {
        resetInput()
      }
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
    // A finger tap on the page selects the object under it while the lasso tool is active; a
    // finger cannot draw a lasso without also fighting the page scroll.
    private lazy var fingerTap = UITapGestureRecognizer(
      target: self, action: #selector(fingerTapped(_:)))
    @objc private func fingerTapped(_ gesture: UITapGestureRecognizer) {
      guard gesture.state == .ended, let configuration, configuration.tool == .lasso,
        activeTouch == nil
      else { return }
      let p = gesture.location(in: self)
      let scale = bounds.width / configuration.page.dimensions.x
      configuration.onTap(
        configuration.viewport?.documentPoint(Point(p.x, p.y)) ?? Point(p.x / scale, p.y / scale))
    }
    private lazy var fingerHold = UILongPressGestureRecognizer(
      target: self, action: #selector(fingerHeld(_:)))
    @objc private func fingerHeld(_ gesture: UILongPressGestureRecognizer) {
      guard gesture.state == .began, let configuration, let onLongPress = configuration.onLongPress
      else { return }
      let p = gesture.location(in: self)
      let scale = bounds.width / configuration.page.dimensions.x
      let point =
        configuration.viewport?.documentPoint(Point(p.x, p.y)) ?? Point(p.x / scale, p.y / scale)
      // Holding on a selection is the start of dragging it, not a request for a menu.
      if Self.manipulatingTools.contains(configuration.tool), !configuration.selection.isEmpty,
        selectionHit(at: point, configuration) != nil
      {
        return
      }
      // A finger that is allowed to ink would otherwise leave a dot behind the menu.
      if activeTouch?.type == .direct {
        resetInput()
        activeTouch = nil
        setNeedsDisplay()
      }
      onLongPress(point)
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
        fingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fingerTap.cancelsTouchesInView = false
        fingerTap.delegate = self
        addGestureRecognizer(fingerTap)
        fingerHold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fingerHold.minimumPressDuration = 0.6
        fingerHold.allowableMovement = 12
        fingerHold.cancelsTouchesInView = false
        fingerHold.delegate = self
        addGestureRecognizer(fingerHold)
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
            // A page swipe should settle quickly onto the target page rather than glide, and a
            // mostly vertical drag must not slide the notebook sideways.
            scroll.isDirectionalLockEnabled = true
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
    // iOS 18's UIUpdateLink can deliver Pencil events in the middle of a frame instead of at its
    // start, which leaves the draw twice as long to reach the display. It is only requested while
    // ink is actually being laid down: the eraser and shape hold do heavier work per event, and an
    // opted-in app that overruns its half frame drops frames. Older systems keep the CADisplayLink.
    private var updateLink: AnyObject?
    private func updateLowLatencyDispatch() {
      guard #available(iOS 18.0, *), let link = updateLink as? UIUpdateLink else { return }
      let inking =
        activeTouch?.type == .pencil
        && [.pen, .highlighter].contains(configuration?.tool)
        && input.moveStart == nil
      link.wantsLowLatencyEventDispatch = inking
      link.requiresContinuousUpdates = inking
      link.isEnabled = inking
    }
    private func updateDisplayLink() {
      displayLink?.isPaused =
        activeTouch == nil
        && !(configuration?.onAppendPage != nil && observedScroll?.isDragging == true)
      updateLowLatencyDispatch()
    }
    override func didMoveToWindow() {
      super.didMoveToWindow()
      displayLink?.invalidate()
      displayLink = nil
      displayTarget = nil
      if #available(iOS 18.0, *), let link = updateLink as? UIUpdateLink { link.isEnabled = false }
      updateLink = nil
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
      installInkOverlay()
      // The cache was dropped when the view left its window; repaint instead of waiting for
      // a configuration change that may never come.
      setNeedsDisplay()
      let target = CanvasDisplayTarget()
      target.view = self
      displayTarget = target
      let link = CADisplayLink(target: target, selector: #selector(CanvasDisplayTarget.update))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
      link.add(to: .main, forMode: .common)
      displayLink = link
      if #available(iOS 18.0, *) {
        let update = UIUpdateLink(view: self)
        // Low-latency dispatch hands the freshest Pencil samples to this action in the middle of
        // the frame; drawing here is what gets them on screen a frame earlier.
        update.addAction { [weak self] _, _ in
          MainActor.assumeIsolated { self?.renderLiveInkIfNeeded() }
        }
        updateLink = update
      }
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
      view.renderLiveInkIfNeeded()
    }
  }
#endif

#if os(iOS)
  final class InkOverlayView: UIView {
    weak var owner: DrawingView?
    override func draw(_ rect: CGRect) {
      guard let c = UIGraphicsGetCurrentContext() else { return }
      owner?.paintOverlay(c)
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
  // The held shape after the pen dragged it to a new size; this is what lifts off the screen.
  var heldResized: Stroke?
  var resizeStart: Point?
  var moveStart: Point?
  var moveDelta = Point(0, 0)
  var selectionHandle: SelectionHandle = .move
  var selectionTransform: SelectionTransform?
  var frame: InkGestures.ObjectFrame?
  var invalidatedSamples = 0
  var lastInkRect = CGRect.null
  var fountain = FountainInk.State()
  var fountainWidths: [Double] = []
  var lastRaw: Point?
  // Strokes with the eraser path applied so far; each new sample only erases incrementally.
  var erased: [Stroke]?
  var eraseDirty = CGRect.null
  var cursor: Point?
  var cursorRect = CGRect.null
  var cacheRect = CGRect.zero
  // The page cache of a heavy page is rebuilt on a worker (`DrawingView.startCacheBuild`). The
  // generation moves on whenever the cache is dropped, so a late result can tell it is outdated.
  var cacheGeneration = 0
  var cacheBuilding = false
  // Pages lighter than this many samples are rebuilt in place: the hop to a worker would cost
  // more than it saves. About 12 000 is half a page of handwriting; a photo or a PDF page counts
  // as a lot, since decoding and drawing them takes longer than their size suggests.
  var backgroundCacheThreshold = 12_000
  var readyCache: ReadyCache?
  var staleCache: CGLayer?
  // Whether the ink overlay currently shows a stroke, so only then does it need clearing.
  var overlayInked = false
  // Ink the running scribble would erase, and when it is next worth asking again.
  var scratchPreview: [Stroke] = []
  var nextScratchCheck: ContinuousClock.Instant?
  // A background pass is in flight; the generation lets its late result notice that the stroke
  // it was asked about is gone.
  var scratchRunning = false
  var scratchGeneration = 0
  // New samples the GPU has not drawn yet, and a counter that lets a late clear notice that
  // another stroke has started in the meantime.
  var gpuInkDirty = false
  var gpuClearGeneration = 0
}
struct ReadyCache {
  let image: CGImage
  let rect: CGRect
  let resolution: Double
  let viewport: ViewTransform?
  let generation: Int
}
enum SelectionHandle: Equatable {
  case move, resize, rotate
  // Frame handles of a single object, as signs in the object's own axes: a corner scales
  // proportionally about the opposite corner, an edge stretches along one axis.
  case corner(Double, Double)
  case edge(Double, Double)
}

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
  static func affectsPixels(
    _ old: CanvasConfiguration?, _ new: CanvasConfiguration?, ignoringPage: Bool = false
  ) -> Bool {
    guard let old, let new else { return true }
    if old.tool != new.tool || old.selection != new.selection || old.viewport != new.viewport
      || old.searchHighlights != new.searchHighlights || (!ignoringPage && old.page != new.page)
      || !sameAssets(old.assets, new.assets)
    {
      return true
    }
    return new.tool == .eraser
      && (old.width != new.width || old.eraserMode != new.eraserMode
        || old.highlighterOnly != new.highlighterOnly)
  }
  // Returns the area of the view the stroke covers when it went straight into the cache.
  @discardableResult
  func updatePageCache(from old: CanvasConfiguration?, to new: CanvasConfiguration?) -> CGRect? {
    guard old?.page != new?.page
      || !Self.sameAssets(old?.assets ?? [:], new?.assets ?? [:])
    else { return nil }
    defer { input.pendingStroke = nil }
    if let old, let new, let pending = input.pendingStroke,
      pending.tool == .pen || pending.tool == .shapes, Self.sameAssets(old.assets, new.assets),
      old.viewport == new.viewport, input.moveStart == nil,
      new.page.strokes.last == pending, let context = cachedPage?.context
    {
      var previous = new.page
      previous.strokes.removeLast()
      if previous == old.page {
        PageRenderer.stroke(pending, in: context)
        // Shapes bring handles and fills of their own; only plain ink has a tight box.
        guard pending.tool == .pen, pending.shape == nil else { return nil }
        return viewRect(of: pending.samples, width: pending.width, in: new)
      }
    }
    cachedPage = nil
    return nil
  }
  // The view area ink laid down along `samples` can touch. Brush tilt and pressure can widen a
  // segment to roughly 3.4x the nominal width.
  func viewRect(of samples: [Sample], width: Double, in configuration: CanvasConfiguration) -> CGRect?
  {
    guard !samples.isEmpty else { return nil }
    let scale = configuration.viewport?.scale ?? bounds.width / configuration.page.dimensions.x
    var rect = CGRect.null
    for sample in samples {
      let p = viewPoint(sample.point)
      rect = rect.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
    }
    let pad = max(8, width * scale * 4 + 4)
    return rect.insetBy(dx: -pad, dy: -pad).intersection(bounds)
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
  // The eraser changes a small area at a time: redraw just that area of the cached page instead
  // of rebuilding the whole page for every sample.
  func patchCache(page area: Rect) {
    guard let configuration, let erased = input.erased, let context = cachedPage?.context,
      cachedViewport == configuration.viewport
    else {
      cachedPage = nil
      return
    }
    var page = configuration.page
    page.strokes = erased
    let rect = CGRect(x: area.x, y: area.y, width: area.width, height: area.height)
    context.saveGState()
    context.clip(to: rect)
    PageRenderer.render(
      page, assets: configuration.assets, in: context,
      paperBounds: configuration.viewport == nil ? nil : input.cacheRect, cull: rect)
    context.restoreGState()
  }
  func cursorViewRect() -> CGRect {
    guard let configuration, let cursor = input.cursor, configuration.tool == .eraser else {
      return .null
    }
    let scale = configuration.viewport?.scale ?? bounds.width / configuration.page.dimensions.x
    let center = viewPoint(cursor)
    let radius = max(8, configuration.width) * scale + 3
    return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
  }
  func invalidateEraser() {
    let cursor = cursorViewRect()
    let dirty = input.eraseDirty.union(cursor).union(input.cursorRect)
    input.cursorRect = cursor
    input.eraseDirty = .null
    setNeedsDisplay(dirty.isNull ? bounds : dirty.insetBy(dx: -2, dy: -2).intersection(bounds))
  }
  func invalidateInk() {
    if configuration?.tool == .eraser, input.moveStart == nil {
      invalidateEraser()
      return
    }
    guard let configuration, [.pen, .highlighter].contains(configuration.tool),
      input.held == nil, input.moveStart == nil, input.resizeStart == nil
    else {
      input.invalidatedSamples = samples.count
      input.lastInkRect = .null
      invalidateCanvas()
      return
    }
    if configuration.tool == .pen, drawsInkOnGPU {
      // The GPU draws the stroke once per frame; nothing is repainted here.
      input.gpuInkDirty = true
      input.invalidatedSamples = samples.count
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
    let area = dirty.isNull ? bounds : dirty.intersection(bounds)
    if configuration.tool == .pen, drawsInkInOverlay {
      invalidateOverlay(area)
    } else {
      setNeedsDisplay(area)
    }
  }
  // While a scribble is being drawn, the ink it would take away is tinted red. The question is
  // only asked a few times a second, and only costs anything once the path looks like a scribble.
  func updateScratchPreview() {
    guard let configuration, configuration.scribblePreview, configuration.tool == .pen,
      input.held == nil, samples.count >= 6
    else { return }
    let now = ContinuousClock.now
    if let next = input.nextScratchCheck, now < next { return }
    // Judging a big scribble against a page of handwriting takes milliseconds, which would
    // drop a frame of the very stroke being drawn, so it runs off the main thread. One pass at
    // a time; a result that arrives after the stroke ended or restarted is dropped.
    guard !input.scratchRunning else { return }
    input.scratchRunning = true
    input.nextScratchCheck = now.advanced(by: .milliseconds(80))
    let points = samples.map(\.point)
    let strokes = configuration.page.strokes
    let generation = input.scratchGeneration
    Task { @MainActor [weak self] in
      let affected = await Task.detached(priority: .userInitiated) {
        InkGestures.scratchOutcome(points, strokes: strokes)?.affected ?? []
      }.value
      guard let self, input.scratchGeneration == generation else { return }
      input.scratchRunning = false
      guard affected != input.scratchPreview else { return }
      input.scratchPreview = affected
      if drawsInkInOverlay { invalidateOverlay() } else { invalidateCanvas() }
    }
  }
  func drawScratchPreview(_ c: CGContext) {
    guard !input.scratchPreview.isEmpty else { return }
    c.saveGState()
    c.setAlpha(0.55)
    // Only what is inside the dirty rect: a scribble over a full page marks thousands of strokes.
    let clip = c.boundingBoxOfClipPath
    for var stroke in input.scratchPreview {
      let box = stroke.bounds
      guard CGRect(x: box.x, y: box.y, width: box.width, height: box.height).intersects(clip)
      else { continue }
      stroke.color = .red
      stroke.width += 3
      stroke.tool = .pen
      stroke.style = .ballpoint
      stroke.tip = nil
      stroke.shape = nil
      stroke.fillColor = nil
      PageRenderer.stroke(stroke, in: c)
    }
    c.restoreGState()
  }
  func resetInput() {
    if input.moveStart != nil || (configuration?.tool == .eraser && !samples.isEmpty) {
      cachedPage = nil
    }
    // Before `samples` is emptied: a stroke that just ended leaves the GPU copy up for a moment,
    // a stroke that is about to start removes the previous one at once.
    if samples.isEmpty { input.gpuClearGeneration += 1 }
    clearGPUInk()
    input.liveLayer = nil
    input.bakedThrough = 0
    input.renderedSegments = 0
    input.holdTask?.cancel()
    input.holdTask = nil
    input.holdDeadline = nil
    input.holdPoint = nil
    input.held = nil
    input.heldResized = nil
    input.resizeStart = nil
    input.moveStart = nil
    input.moveDelta = Point(0, 0)
    input.selectionHandle = .move
    input.selectionTransform = nil
    input.frame = nil
    input.invalidatedSamples = 0
    input.lastInkRect = .null
    input.erased = nil
    input.cursor = nil
    input.eraseDirty = .null
    input.cursorRect = .null
    input.scratchPreview = []
    input.nextScratchCheck = nil
    input.scratchRunning = false
    input.scratchGeneration += 1
    samples = []
    predictedSamples = []
    if input.overlayInked { invalidateOverlay() }
  }
  // Tools whose selection can be moved, stretched and rotated in place.
  static let manipulatingTools: [InkTool] = [.lasso, .shapes, .image, .elements]

  func handlePoints(_ frame: InkGestures.ObjectFrame, scale: Double) -> [(SelectionHandle, Point)] {
    func world(_ sx: Double, _ sy: Double) -> Point {
      let x = sx * frame.width / 2
      let y = sy * frame.height / 2
      return Point(
        frame.center.x + x * cos(frame.rotation) - y * sin(frame.rotation),
        frame.center.y + x * sin(frame.rotation) + y * cos(frame.rotation))
    }
    var handles: [(SelectionHandle, Point)] = []
    // A line has no height, so its rotate handle sits off to the side.
    let lift = frame.stretchesVertically ? frame.height / 2 + 30 / scale : 30 / scale
    handles.append(
      (
        .rotate,
        Point(
          frame.center.x + lift * sin(frame.rotation),
          frame.center.y - lift * cos(frame.rotation))
      ))
    if frame.stretchesVertically || frame.height > 0 {
      for (sx, sy) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
        handles.append((.corner(sx, sy), world(sx, sy)))
      }
    }
    handles.append((.edge(1, 0), world(1, 0)))
    handles.append((.edge(-1, 0), world(-1, 0)))
    if frame.stretchesVertically {
      handles.append((.edge(0, -1), world(0, -1)))
      handles.append((.edge(0, 1), world(0, 1)))
    }
    return handles
  }
  // With the shapes tool only a handle grabs the selection. The body of a shape that was just
  // drawn (a long wire, say) must stay free to draw on, or a rectangle started on it would drag
  // the wire away instead of being drawn. Moving a shape as a whole is the lasso's job.
  func selectionHit(at point: Point, _ configuration: CanvasConfiguration) -> (
    handle: SelectionHandle, center: Point
  )? {
    guard let hit = bodyOrHandleHit(at: point, configuration) else { return nil }
    return configuration.tool == .shapes && hit.handle == .move ? nil : hit
  }
  private func bodyOrHandleHit(at point: Point, _ configuration: CanvasConfiguration) -> (
    handle: SelectionHandle, center: Point
  )? {
    let scale = configuration.viewport?.scale ?? self.bounds.width / configuration.page.dimensions.x
    // A handle is only grabbed right at its dot, and never by more than a third of the shorter
    // side of the selection: on a small selection a fixed 24 pt radius used to cover almost all
    // of it, so a drag meant to move it resized it instead. Everything else inside moves it.
    func reach(_ width: Double, _ height: Double, _ points: Double) -> Double {
      let side = height > 0 ? min(width, height) : width
      return min(points / scale, max(8 / scale, side / 3))
    }
    if let frame = InkGestures.objectFrame(page: configuration.page, ids: configuration.selection) {
      let cornerReach = reach(frame.width, frame.height, 20)
      let hit = handlePoints(frame, scale: scale)
        .compactMap { handle -> (SelectionHandle, Point, Double)? in
          let limit: Double
          switch handle.0 {
          case .edge: limit = reach(frame.width, frame.height, 12)
          case .rotate: limit = 24 / scale
          default: limit = cornerReach
          }
          let distance = point.distance(to: handle.1)
          return distance < limit ? (handle.0, handle.1, distance) : nil
        }
        .min { $0.2 < $1.2 }
      if let hit { return (hit.0, frame.center) }
      let dx = point.x - frame.center.x
      let dy = point.y - frame.center.y
      let lx = dx * cos(frame.rotation) + dy * sin(frame.rotation)
      let ly = -dx * sin(frame.rotation) + dy * cos(frame.rotation)
      let slack = frame.height > 0 ? 8 / scale : 16 / scale
      if abs(lx) <= frame.width / 2 + slack, abs(ly) <= frame.height / 2 + slack {
        return (.move, frame.center)
      }
      return nil
    }
    guard
      let bounds = InkGestures.selectionBounds(
        page: configuration.page, ids: configuration.selection)
    else { return nil }
    let center = Point(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2)
    let rotate = Point(center.x, bounds.y - 30 / scale)
    let corners = [
      Point(bounds.x, bounds.y), Point(bounds.x + bounds.width, bounds.y),
      Point(bounds.x, bounds.y + bounds.height),
      Point(bounds.x + bounds.width, bounds.y + bounds.height),
    ]
    let cornerReach = reach(bounds.width, bounds.height, 20)
    if point.distance(to: rotate) < 24 / scale { return (.rotate, center) }
    if corners.contains(where: { point.distance(to: $0) < cornerReach }) { return (.resize, center) }
    if InkGestures.selectionContains(point, page: configuration.page, ids: configuration.selection)
    {
      return (.move, center)
    }
    return nil
  }
  func accept(_ sample: Sample) {
    guard let configuration else { return }
    if samples.isEmpty, Self.manipulatingTools.contains(configuration.tool),
      !configuration.selection.isEmpty,
      let hit = selectionHit(at: sample.point, configuration)
    {
      input.selectionHandle = hit.handle
      input.moveStart = sample.point
      input.frame = InkGestures.objectFrame(page: configuration.page, ids: configuration.selection)
      input.selectionTransform = SelectionTransform(
        center: hit.center, axis: input.frame?.rotation ?? 0)
      cachedPage = nil
    }
    if let start = input.moveStart, var transform = input.selectionTransform {
      let frame = input.frame
      let center = transform.center
      let rotation = frame?.rotation ?? 0
      // Pointer in the object's own axes (origin at its center).
      func local(_ p: Point) -> Point {
        let dx = p.x - center.x
        let dy = p.y - center.y
        return Point(
          dx * cos(rotation) + dy * sin(rotation), -dx * sin(rotation) + dy * cos(rotation))
      }
      func world(_ p: Point) -> Point {
        Point(
          center.x + p.x * cos(rotation) - p.y * sin(rotation),
          center.y + p.x * sin(rotation) + p.y * cos(rotation))
      }
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
        var angle =
          atan2(sample.point.y - transform.center.y, sample.point.x - transform.center.x)
          - atan2(start.y - transform.center.y, start.x - transform.center.x)
        // Snap the object's final angle to 15° steps when it is within about 3° of one.
        let step = Double.pi / 12
        let target = rotation + angle
        let nearest = (target / step).rounded() * step
        if abs(target - nearest) < 0.05 { angle = nearest - rotation }
        transform.angle = angle
      case .corner(let sx, let sy):
        if let frame, frame.width > 0, frame.height > 0 {
          let anchor = Point(-sx * frame.width / 2, -sy * frame.height / 2)
          let corner = Point(sx * frame.width / 2, sy * frame.height / 2)
          let v = Point(corner.x - anchor.x, corner.y - anchor.y)
          let p = local(sample.point)
          let factor =
            ((p.x - anchor.x) * v.x + (p.y - anchor.y) * v.y) / (v.x * v.x + v.y * v.y)
          transform.scale = max(0.05, min(20, factor))
          // Keep the opposite corner where it was.
          let anchored = world(anchor)
          transform.translation = Point(
            (anchored.x - center.x) * (1 - transform.scale),
            (anchored.y - center.y) * (1 - transform.scale))
        }
      case .edge(let sx, let sy):
        if let frame {
          let p = local(sample.point)
          var shift = Point(0, 0)
          if sx != 0, frame.width > 0 {
            let width = max(12, sx * p.x + frame.width / 2)
            transform.stretch.x = width / frame.width
            shift.x = sx * (width - frame.width) / 2
          }
          if sy != 0, frame.height > 0 {
            let height = max(12, sy * p.y + frame.height / 2)
            transform.stretch.y = height / frame.height
            shift.y = sy * (height - frame.height) / 2
          }
          let moved = world(shift)
          transform.translation = Point(moved.x - center.x, moved.y - center.y)
        }
      }
      input.selectionTransform = transform
      samples = [sample]
      return
    }
    if let held = input.held, let start = input.resizeStart {
      let resized = InkGestures.resizeHeldShape(held, from: start, to: sample.point)
      input.heldResized = resized
      samples = resized.samples
      predictedSamples = []
      return
    }
    var sample = sample
    input.lastRaw = sample.point
    // Stabilization trails the pen through an exponential filter; the true end point is
    // restored in finish() so the stroke still lands where the tip lifted.
    if configuration.tool == .pen, configuration.stabilization > 0, let last = samples.last {
      let follow = 1 - 0.9 * configuration.stabilization
      sample.point = Point(
        last.point.x + (sample.point.x - last.point.x) * follow,
        last.point.y + (sample.point.y - last.point.y) * follow)
    }
    samples.append(sample)
    if configuration.tool == .pen, configuration.style == .fountain {
      input.fountainWidths.append(
        FountainInk.advance(
          &input.fountain, sample: sample, base: configuration.width, tip: configuration.tip))
    }
    if configuration.tool == .eraser {
      var strokes = input.erased ?? configuration.page.strokes
      let radius = max(8, configuration.width)
      // Fill the gap to the previous sample so a quick swipe leaves no ink behind.
      let path = samples.count > 1
        ? Editing.sweep([samples[samples.count - 2].point, sample.point], spacing: max(2, radius / 2))
        : [sample.point]
      input.cursor = sample.point
      for point in path.dropFirst(path.count > 1 ? 1 : 0) {
        guard let area = Editing.eraseTracking(
          &strokes, at: point, radius: radius, mode: configuration.eraserMode,
          highlighterOnly: configuration.highlighterOnly)
        else { continue }
        input.erased = strokes
        patchCache(page: area)
        let a = viewPoint(Point(area.x, area.y))
        let b = viewPoint(Point(area.x + area.width, area.y + area.height))
        input.eraseDirty = input.eraseDirty.union(
          CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
      }
      if input.erased == nil { input.erased = strokes }
    }
    updateScratchPreview()
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
          width: configuration.width, tool: configuration.tool, style: configuration.style,
          tip: configuration.tip)
        guard let shape = InkGestures.heldShape(raw) else { return }
        self.input.held = shape
        self.input.gpuInkDirty = false
        self.metalInkClearNow()
        self.invalidateOverlay()
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
  // Moves a view-sized context into page/world coordinates and returns the visible world rect
  // together with the device resolution caches and live layers are rendered at.
  private func canvasSpace(_ c: CGContext, _ configuration: CanvasConfiguration) -> (
    cacheRect: CGRect, resolution: Double
  ) {
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
    let resolution = min(hypot(c.ctm.a, c.ctm.b), 4096 / max(cacheRect.width, cacheRect.height))
    return (cacheRect, resolution)
  }
  // The live pen stroke, drawn into the transparent overlay (iOS). Everything else about the page
  // is painted by `paint`.
  func paintOverlay(_ c: CGContext) {
    guard let configuration, configuration.tool == .pen, input.held == nil,
      input.moveStart == nil, !samples.isEmpty, bounds.width > 0, bounds.height > 0
    else {
      input.overlayInked = false
      return
    }
    input.overlayInked = true
    let (cacheRect, resolution) = canvasSpace(c, configuration)
    drawScratchPreview(c)
    if drawsInkOnGPU {
      // The metal view above draws the stroke itself; this layer only carries the preview.
      input.overlayInked = !input.scratchPreview.isEmpty
      return
    }
    if samples.count > 5 {
      paintLiveInk(configuration, in: c, rect: cacheRect, resolution: resolution)
    } else {
      PageRenderer.stroke(
        Stroke(
          samples: samples + predictedSamples, color: configuration.color,
          width: configuration.width, tool: .pen, style: configuration.style,
          tip: configuration.tip), in: c)
    }
  }
  func buildsCacheInBackground(_ configuration: CanvasConfiguration) -> Bool {
    // A running gesture needs the cache now (the eraser patches it per sample).
    guard samples.isEmpty, input.moveStart == nil, input.selectionTransform == nil,
      configuration.tool != .eraser
    else { return false }
    let page = configuration.page
    var weight = page.images.count * 30_000 + page.texts.count * 500
    if page.backgroundPDF != nil { weight += 40_000 }
    for stroke in page.strokes {
      weight += stroke.samples.count
      if weight >= input.backgroundCacheThreshold { return true }
    }
    return weight >= input.backgroundCacheThreshold
  }
  func startCacheBuild(_ configuration: CanvasConfiguration, rect: CGRect, resolution: Double) {
    guard !input.cacheBuilding else { return }
    input.cacheBuilding = true
    let generation = input.cacheGeneration
    let page = configuration.page
    let assets = configuration.assets
    let viewport = configuration.viewport
    Task { @MainActor [weak self] in
      let rendered = await PageCacheWorker.shared.render(
        page, assets: assets, rect: rect, resolution: resolution, infinitePaper: viewport != nil)
      guard let self else { return }
      input.cacheBuilding = false
      if let rendered, generation == input.cacheGeneration {
        input.readyCache = ReadyCache(
          image: rendered.image, rect: rect, resolution: resolution, viewport: viewport,
          generation: generation)
      }
      // Either installs the result or, if the page changed meanwhile, starts the next build.
      invalidateCanvas()
    }
  }
  private func install(_ ready: ReadyCache, in c: CGContext) {
    let size = CGSize(
      width: ready.rect.width * ready.resolution, height: ready.rect.height * ready.resolution)
    guard let layer = CGLayer(c, size: size, auxiliaryInfo: nil), let context = layer.context
    else { return }
    // The layer context is y-down like the page; a bitmap's first row is its top.
    context.saveGState()
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    context.draw(ready.image, in: CGRect(origin: .zero, size: size))
    context.restoreGState()
    context.scaleBy(x: ready.resolution, y: ready.resolution)
    context.translateBy(x: -ready.rect.minX, y: -ready.rect.minY)
    cachedPage = layer
    input.staleCache = nil
    input.cacheRect = ready.rect
    cachedResolution = ready.resolution
    cachedViewport = ready.viewport
  }
  func paint(_ configuration: CanvasConfiguration, _ c: CGContext, dirty: CGRect? = nil) {
    guard bounds.width > 0, bounds.height > 0 else { return }
    var configuration = configuration
    if let transform = input.selectionTransform {
      configuration.page = InkGestures.transform(
        configuration.page, ids: configuration.selection, by: transform)
    }
    if configuration.tool == .eraser, !samples.isEmpty, let erased = input.erased {
      configuration.page.strokes = erased
    }
    c.saveGState()
    // While inking only a few points change per frame; clipping keeps the page blit and
    // the white fill proportional to the stroke tail instead of the whole screen.
    if let dirty, dirty != bounds { c.clip(to: dirty) }
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fill(bounds)
    let (cacheRect, resolution) = canvasSpace(c, configuration)
    // Cache the visible world at device resolution, including negative coordinates on a whiteboard.
    if cachedPage != nil
      && (abs(resolution - cachedResolution) > 0.001 || cachedViewport != configuration.viewport)
    {
      cachedPage = nil
    }
    if cachedPage == nil, let ready = input.readyCache {
      input.readyCache = nil
      if ready.generation == input.cacheGeneration, ready.rect == cacheRect,
        abs(ready.resolution - resolution) <= 0.001, ready.viewport == configuration.viewport
      {
        install(ready, in: c)
      }
    }
    if cachedPage == nil, buildsCacheInBackground(configuration) {
      startCacheBuild(configuration, rect: cacheRect, resolution: resolution)
      // The previous cache stands in until the new one is ready: a stale page is better than a
      // blank one, and a lower resolution one is just a soft page for a moment.
      if let stale = input.staleCache { c.draw(stale, in: input.cacheRect) }
    } else if cachedPage == nil,
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
      input.staleCache = nil
      input.cacheRect = cacheRect
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
    if !drawsInkInOverlay { drawScratchPreview(c) }
    if !samples.isEmpty {
      if configuration.tool == .lasso && input.moveStart == nil {
        c.setStrokeColor(PageRenderer.color(.blue))
        c.setLineWidth(1)
        c.setLineDash(phase: 0, lengths: [5, 4])
        c.addLines(between: samples.map { CGPoint(x: $0.point.x, y: $0.point.y) })
        c.strokePath()
      } else if configuration.tool == .shapes, let kind = configuration.shapeKind,
        let first = samples.first, let last = samples.last
      {
        // The shape follows the drag, so what lifts off the screen is what was previewed.
        let spec = ShapeSpec.dragged(kind, from: first.point, to: last.point)
        PageRenderer.stroke(
          .shape(
            spec, color: kind.stickerColor?.darkened() ?? configuration.color,
            width: kind.isSticker ? 2.5 : configuration.width, fill: kind.stickerColor,
            fillOpacity: kind.isSticker ? 1 : nil), in: c)
      } else if [.pen, .highlighter, .shapes].contains(configuration.tool) {
        if configuration.tool == .pen, let held = input.heldResized ?? input.held {
          // Preview the committed shape itself so nothing shifts when the pen lifts.
          PageRenderer.stroke(held, in: c)
        } else if configuration.tool == .pen, input.held == nil, drawsInkInOverlay {
          // The overlay view shows the live stroke.
        } else if configuration.tool == .pen, input.held == nil, samples.count > 5 {
          paintLiveInk(configuration, in: c, rect: cacheRect, resolution: resolution)
        } else {
          PageRenderer.stroke(
            Stroke(
              samples: samples + predictedSamples, color: configuration.color,
              width: configuration.width, tool: configuration.tool, style: configuration.style,
              tip: configuration.tip),
            in: c
          )
        }
      }
    }
    if configuration.tool == .eraser, let cursor = input.cursor {
      let scale = configuration.viewport?.scale ?? bounds.width / configuration.page.dimensions.x
      let radius = max(8, configuration.width)
      let ring = CGRect(x: cursor.x - radius, y: cursor.y - radius, width: radius * 2, height: radius * 2)
      c.setFillColor(CGColor(gray: 0.5, alpha: 0.14))
      c.fillEllipse(in: ring)
      c.setStrokeColor(CGColor(gray: 0.25, alpha: 0.75))
      c.setLineWidth(1.2 / scale)
      c.strokeEllipse(in: ring)
    }
    c.setLineDash(phase: 0, lengths: [4, 3])
    c.setStrokeColor(PageRenderer.color(.blue))
    c.setLineWidth(1)
    if !configuration.selection.isEmpty {
      let scale = configuration.viewport?.scale ?? bounds.width / configuration.page.dimensions.x
      c.setLineWidth(1.5 / scale)
      c.setFillColor(CGColor(gray: 1, alpha: 1))
      func dot(_ point: Point, _ diameter: Double) {
        let circle = CGRect(
          x: point.x - diameter / 2 / scale, y: point.y - diameter / 2 / scale,
          width: diameter / scale, height: diameter / scale)
        c.fillEllipse(in: circle)
        c.strokeEllipse(in: circle)
      }
      if let frame = InkGestures.objectFrame(page: configuration.page, ids: configuration.selection)
      {
        c.saveGState()
        c.translateBy(x: frame.center.x, y: frame.center.y)
        c.rotate(by: frame.rotation)
        if frame.height > 0 {
          c.stroke(CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height))
        }
        c.restoreGState()
        c.setLineDash(phase: 0, lengths: [])
        let handles = handlePoints(frame, scale: scale)
        if let rotate = handles.first(where: { $0.0 == .rotate })?.1 {
          let top = Point(
            frame.center.x + (frame.stretchesVertically ? frame.height / 2 : 0) * sin(frame.rotation),
            frame.center.y - (frame.stretchesVertically ? frame.height / 2 : 0) * cos(frame.rotation))
          c.move(to: CGPoint(x: top.x, y: top.y))
          c.addLine(to: CGPoint(x: rotate.x, y: rotate.y))
          c.strokePath()
        }
        for (handle, point) in handles {
          switch handle {
          case .rotate: dot(point, 13)
          case .edge: dot(point, 9)
          default: dot(point, 11)
          }
        }
      } else if let b = InkGestures.selectionBounds(
        page: configuration.page, ids: configuration.selection)
      {
        c.stroke(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
        c.setLineDash(phase: 0, lengths: [])
        let center = Point(b.x + b.width / 2, b.y + b.height / 2)
        let rotate = Point(center.x, b.y - 30 / scale)
        c.move(to: CGPoint(x: center.x, y: b.y))
        c.addLine(to: CGPoint(x: rotate.x, y: rotate.y))
        c.strokePath()
        for point in [
          Point(b.x, b.y), Point(b.x + b.width, b.y), Point(b.x, b.y + b.height),
          Point(b.x + b.width, b.y + b.height), rotate,
        ] { dot(point, 10) }
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
      if abs(transform.scale - 1) > 0.001 || abs(transform.angle) > 0.001 || transform.isStretched
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
      // A held shape is committed exactly as previewed, with its spec so it stays editable. It
      // must not go through the path below: stabilization would append the raw pen-up point and
      // draw a stray line from the end of the shape to wherever the pen was lifted.
      if configuration.tool == .pen, let shape = input.heldResized ?? input.held {
        input.pendingStroke = shape
        configuration.onStroke(shape)
        break
      }
      if configuration.tool == .pen, configuration.stabilization > 0, let raw = input.lastRaw,
        let last = samples.last, raw != last.point
      {
        samples.append(Sample(point: raw, pressure: last.pressure, altitude: last.altitude))
      }
      let stroke = Stroke(
        samples: samples, color: configuration.color, width: configuration.width,
        tool: configuration.tool, style: configuration.style,
        tip: configuration.style == .fountain && configuration.tool == .pen
          ? configuration.tip : nil)
      // An inserted shape is rebuilt by the owner from the drag, so the raw drag is never shown.
      if !(configuration.tool == .shapes && configuration.shapeKind != nil) {
        input.pendingStroke = stroke
      }
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
          width: configuration.width, tool: .pen, style: configuration.style,
          tip: configuration.tip), in: c)
      return
    }
    let stableEnd = samples.count - 2
    if stableEnd > input.bakedThrough {
      let range = (input.bakedThrough + 1)..<(stableEnd + 1)
      PageRenderer.smoothInkSegments(
        samples, range: range, color: configuration.color,
        width: configuration.width, style: configuration.style, in: context,
        widths: input.fountainWidths)
      input.renderedSegments += range.count
      input.bakedThrough = stableEnd
    }
    c.draw(layer, in: rect)
    let tail = Array(samples.suffix(3)) + predictedSamples
    // Include one already-baked sample to preserve the tail's midpoint tangent.
    var tailWidths: [Double]?
    if configuration.style == .fountain, input.fountainWidths.count == samples.count {
      var state = input.fountain
      tailWidths =
        Array(input.fountainWidths.suffix(3))
        + predictedSamples.map {
          FountainInk.advance(
            &state, sample: $0, base: configuration.width, tip: configuration.tip)
        }
    }
    PageRenderer.smoothInkSegments(
      tail, range: 2..<tail.count, color: configuration.color,
      width: configuration.width, style: configuration.style, in: c, finish: true,
      widths: tailWidths)
    input.renderedSegments += max(0, tail.count - 2)
  }
}

#if os(iOS)
  // Each paper has its own native zoom surface. The outer scroll view remains responsible for paging.
  @MainActor final class NotebookZoomScrollView: UIScrollView {
    var allowsZoom = true
    var onBoundsChange: (() -> Void)?
    private var laidOutSize = CGSize.zero
    // SwiftUI only calls `updateUIViewController` when its own state changes. When the app comes
    // back from the background the scroll view can be resized afterwards (rotation, safe area,
    // split view), which would leave the paper off-centre until the next page switch.
    override func layoutSubviews() {
      super.layoutSubviews()
      guard bounds.size != laidOutSize else { return }
      laidOutSize = bounds.size
      onBoundsChange?()
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      if gestureRecognizer === panGestureRecognizer {
        guard zoomScale > minimumZoomScale + 0.01 else { return false }
        let velocity = panGestureRecognizer.velocity(in: self)
        let horizontal = abs(velocity.x) > abs(velocity.y)
        let lowEdge = horizontal ? -contentInset.left : -contentInset.top
        let highEdge =
          horizontal
          ? contentSize.width - bounds.width + contentInset.right
          : contentSize.height - bounds.height + contentInset.bottom
        let position = horizontal ? contentOffset.x : contentOffset.y
        let delta = horizontal ? velocity.x : velocity.y
        // Outward gestures at an edge go to the parent, so paging also works while zoomed.
        if (position <= lowEdge + 1 && delta > 0) || (position >= highEdge - 1 && delta < 0) {
          return false
        }
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
      scroll.onBoundsChange = { [weak coordinator = context.coordinator] in
        coordinator?.centerPaper()
      }
      scroll.minimumZoomScale = 1
      scroll.maximumZoomScale = 6
      scroll.showsHorizontalScrollIndicator = false
      scroll.showsVerticalScrollIndicator = false
      scroll.backgroundColor = .clear
      scroll.bounces = false
      scroll.bouncesZoom = true
      scroll.contentInsetAdjustmentBehavior = .never
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
        scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
        coordinator.centerPaper()
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
      // The paper is centred with content insets rather than by moving the view: the inset
      // grows smoothly from "centred" to a fixed margin as the page outgrows the screen, so
      // zooming never jumps, and a margin stays around the page so its top edge can be pulled
      // out from under the toolbar and zoomed at like any other part.
      func centerPaper() {
        let size = scroll.bounds.size == .zero ? viewportSize : scroll.bounds.size
        let content = scroll.contentSize
        guard size.width > 0, size.height > 0 else { return }
        let sideMargin: CGFloat = 28
        let topMargin: CGFloat = 64
        let bottomMargin: CGFloat = 28
        let insetX = max(sideMargin, (size.width - content.width) / 2)
        let spareY = (size.height - content.height) / 2
        let inset = UIEdgeInsets(
          top: max(topMargin, spareY), left: insetX, bottom: max(bottomMargin, spareY),
          right: insetX)
        if scroll.contentInset != inset { scroll.contentInset = inset }
        // A page that fits stays exactly centred; a larger one keeps the offset UIKit chose.
        var offset = scroll.contentOffset
        if content.width <= size.width { offset.x = -insetX }
        if content.height <= size.height { offset.y = -spareY }
        if offset != scroll.contentOffset { scroll.contentOffset = offset }
        scroll.accessibilityValue = "Zoom \(Int(scroll.zoomScale * 100)) percent"
        scroll.accessibilityIdentifier = "notebookZoomSurface"
      }
    }
  }
#endif
