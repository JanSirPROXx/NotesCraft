#if os(iOS)
  import NoteCraftCore
  import UIKit

  // A touch that is a Pencil belongs to the page, whatever floats over it.
  private func isPencil(_ event: UIEvent?) -> Bool {
    event?.allTouches?.contains { $0.type == .pencil } == true
  }

  // "125%" with a button that fits the notebook to the width of the view again. It appears while the
  // notebook is being zoomed and goes away a little after. Like the other things that float over the
  // document it is UIKit: a SwiftUI state change per frame of a pinch would redo every page.
  @MainActor final class ZoomIndicator: UIControl {
    var onFit: (() -> Void)?
    private let label = UILabel()
    private let icon = UIImageView(
      image: UIImage(
        systemName: "arrow.up.left.and.arrow.down.right",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
    private var hideDeadline = ContinuousClock.Instant.now
    private var hideTask: Task<Void, Never>?
    private var shownPercent = -1

    override init(frame: CGRect) {
      super.init(frame: frame)
      let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
      blur.frame = bounds
      blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      blur.isUserInteractionEnabled = false
      addSubview(blur)
      label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
      label.textColor = .label
      label.isUserInteractionEnabled = false
      addSubview(label)
      icon.tintColor = .label
      icon.contentMode = .center
      icon.isUserInteractionEnabled = false
      addSubview(icon)
      clipsToBounds = true
      isHidden = true
      alpha = 0
      accessibilityIdentifier = "zoomIndicator"
      accessibilityLabel = "Fit to width"
      accessibilityTraits = .button
      addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func tapped() {
      onFit?()
      // The fit is on its way: the label follows it, and the indicator stays for a moment more.
      keepVisible()
    }

    override var isHighlighted: Bool {
      didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
      !isHidden && alpha > 0.05 && !isPencil(event) && bounds.insetBy(dx: -8, dy: -8).contains(point)
    }

    // Shows the zoom (1 is fit to width, 100%). Called for every frame of a pinch, so the label is
    // only touched when the number changes.
    func show(zoom: Double) {
      let percent = Scrubber.zoomPercent(zoom)
      if percent != shownPercent {
        shownPercent = percent
        label.text = "\(percent)%"
        accessibilityValue = "\(percent)%"
        label.sizeToFit()
        let height: CGFloat = 34
        let width = label.bounds.width + 14 + 16 + 12 + 4
        frame.size = CGSize(width: width, height: height)
        layer.cornerRadius = height / 2
        label.frame = CGRect(
          x: 14, y: (height - label.bounds.height) / 2, width: label.bounds.width,
          height: label.bounds.height)
        icon.frame = CGRect(x: width - 16 - 12, y: 0, width: 16, height: height)
        reposition()
      }
      keepVisible()
    }

    // In the bottom left corner of what it floats over.
    func reposition() {
      guard let superview else { return }
      let insets = superview.safeAreaInsets
      frame.origin = CGPoint(
        x: insets.left + 18, y: superview.bounds.height - bounds.height - 18 - insets.bottom)
    }

    private func keepVisible() {
      hideDeadline = .now.advanced(by: .milliseconds(2500))
      isHidden = false
      if alpha < 1, !isHighlighted { alpha = 1 }
      guard hideTask == nil else { return }
      hideTask = Task { @MainActor [weak self] in
        while let self {
          let deadline = self.hideDeadline
          try? await Task.sleep(until: deadline, clock: .continuous)
          guard !Task.isCancelled else { return }
          // Held down, or asked to stay again meanwhile.
          if self.hideDeadline > deadline || self.isTracking { continue }
          break
        }
        guard let self else { return }
        self.hideTask = nil
        UIView.animate(withDuration: 0.25) { self.alpha = 0 } completion: { _ in
          if self.alpha == 0 { self.isHidden = true }
        }
      }
    }
  }

  // The handle on the edge of the notebook that can be taken hold of to run through it, with the
  // page it is at in a bubble next to it. It appears while the notebook scrolls and goes away a
  // moment after; a finger on it moves the notebook in proportion, the way a scroll bar does.
  @MainActor final class PageScrubber: UIView {
    // 0...1 along the scroll axis, and whether the move is over.
    var onScrub: ((Double, Bool) -> Void)?
    // "12 / 120", asked while the handle is held.
    var bubbleText: (() -> String)?
    var isVertical = true {
      didSet { if isVertical != oldValue { layoutThumb() } }
    }
    private(set) var isScrubbing = false

    private let thumb = UIView()
    private let bubble = UIView()
    private let bubbleLabel = UILabel()
    private var fraction = 0.0
    private var visibleLength = 0.0
    private var contentLength = 0.0
    private var grab = 0.0
    private var hideDeadline = ContinuousClock.Instant.now
    private var hideTask: Task<Void, Never>?

    private static let thickness: CGFloat = 5
    private static let grabbedThickness: CGFloat = 9
    private static let edgeGap: CGFloat = 3

    override init(frame: CGRect) {
      super.init(frame: frame)
      thumb.backgroundColor = UIColor(white: 0.2, alpha: 0.62)
      thumb.layer.borderColor = UIColor(white: 1, alpha: 0.55).cgColor
      thumb.layer.borderWidth = 0.5
      thumb.isUserInteractionEnabled = false
      thumb.accessibilityIdentifier = "pageScrubber"
      thumb.isAccessibilityElement = true
      thumb.accessibilityLabel = "Page scrubber"
      addSubview(thumb)
      let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
      blur.isUserInteractionEnabled = false
      blur.frame = bubble.bounds
      blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      bubble.addSubview(blur)
      bubbleLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
      bubbleLabel.textColor = .label
      bubbleLabel.textAlignment = .center
      bubble.addSubview(bubbleLabel)
      bubble.clipsToBounds = true
      bubble.isUserInteractionEnabled = false
      bubble.isHidden = true
      addSubview(bubble)
      isHidden = true
      alpha = 0
      let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
      pan.maximumNumberOfTouches = 1
      pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
      addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: geometry

    // The track the handle runs on, along the scroll axis.
    private var trackStart: CGFloat { 10 }
    private var trackLength: CGFloat {
      isVertical
        ? max(0, bounds.height - 20 - safeAreaInsets.bottom)
        : max(0, bounds.width - 20)
    }
    private var thumbLength: CGFloat {
      CGFloat(
        Scrubber.thumbLength(
          visible: visibleLength, content: contentLength, track: Double(trackLength)))
    }

    private var hitRect: CGRect {
      thumb.frame.insetBy(dx: isVertical ? -34 : -14, dy: isVertical ? -14 : -34)
        .intersection(bounds)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
      !isHidden && alpha > 0.05 && !isPencil(event) && hitRect.contains(point)
    }

    private func layoutThumb() {
      let thickness = isScrubbing ? Self.grabbedThickness : Self.thickness
      let length = thumbLength
      let start = trackStart + CGFloat(
        Scrubber.thumbStart(fraction: fraction, track: Double(trackLength), thumb: Double(length)))
      if isVertical {
        thumb.frame = CGRect(
          x: bounds.width - thickness - Self.edgeGap - safeAreaInsets.right, y: start,
          width: thickness, height: length)
      } else {
        thumb.frame = CGRect(
          x: start, y: bounds.height - thickness - Self.edgeGap - safeAreaInsets.bottom,
          width: length, height: thickness)
      }
      thumb.layer.cornerRadius = thickness / 2
      if isScrubbing { layoutBubble() }
    }

    private func layoutBubble() {
      bubbleLabel.text = bubbleText?() ?? ""
      bubbleLabel.sizeToFit()
      let size = CGSize(width: bubbleLabel.bounds.width + 28, height: 38)
      bubble.layer.cornerRadius = size.height / 2
      bubbleLabel.frame = CGRect(origin: .zero, size: size)
      if isVertical {
        bubble.frame = CGRect(
          x: thumb.frame.minX - size.width - 12,
          y: min(max(8, thumb.frame.midY - size.height / 2), bounds.height - size.height - 8),
          width: size.width, height: size.height)
      } else {
        bubble.frame = CGRect(
          x: min(max(8, thumb.frame.midX - size.width / 2), bounds.width - size.width - 8),
          y: thumb.frame.minY - size.height - 12, width: size.width, height: size.height)
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      layoutThumb()
    }

    // MARK: showing

    // The notebook scrolled: the handle is where the view is in the content. `reveal` is a scroll by
    // the reader, as opposed to the notebook moving by itself, and shows the handle.
    func update(fraction: Double, visible: Double, content: Double, reveal: Bool) {
      guard !isScrubbing else { return }
      self.fraction = fraction
      visibleLength = visible
      contentLength = content
      // A notebook that fits has nothing to run through.
      guard content > visible + 1 else {
        hideNow()
        return
      }
      layoutThumb()
      if reveal { keepVisible() }
    }

    private func keepVisible() {
      hideDeadline = .now.advanced(by: .milliseconds(1800))
      isHidden = false
      if alpha < 1 { UIView.animate(withDuration: 0.12) { self.alpha = 1 } }
      guard hideTask == nil else { return }
      hideTask = Task { @MainActor [weak self] in
        while let self {
          let deadline = self.hideDeadline
          try? await Task.sleep(until: deadline, clock: .continuous)
          guard !Task.isCancelled else { return }
          if self.hideDeadline > deadline || self.isScrubbing { continue }
          break
        }
        guard let self else { return }
        self.hideTask = nil
        UIView.animate(withDuration: 0.3) { self.alpha = 0 } completion: { _ in
          if self.alpha == 0 { self.isHidden = true }
        }
      }
    }

    private func hideNow() {
      hideTask?.cancel()
      hideTask = nil
      alpha = 0
      isHidden = true
    }

    // MARK: scrubbing

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
      let point = gesture.location(in: self)
      let along = Double(isVertical ? point.y : point.x) - Double(trackStart)
      switch gesture.state {
      case .began:
        isScrubbing = true
        let start = isVertical ? thumb.frame.minY : thumb.frame.minX
        // The finger took hold of the handle where it is, or where the hit area around it is.
        let held = Double((isVertical ? point.y : point.x) - start)
        grab = min(max(0, held), Double(thumbLength))
        bubble.isHidden = false
        UIView.animate(withDuration: 0.12) { self.layoutThumb() }
        keepVisible()
        move(to: along)
      case .changed:
        move(to: along)
      case .ended, .cancelled, .failed:
        let finished = gesture.state == .ended
        isScrubbing = false
        bubble.isHidden = true
        let final = Scrubber.fraction(
          position: along, grab: grab, track: Double(trackLength), thumb: Double(thumbLength))
        onScrub?(finished ? final : fraction, true)
        UIView.animate(withDuration: 0.15) { self.layoutThumb() }
        keepVisible()
      default: break
      }
    }

    private func move(to position: Double) {
      fraction = Scrubber.fraction(
        position: position, grab: grab, track: Double(trackLength), thumb: Double(thumbLength))
      layoutThumb()
      onScrub?(fraction, false)
      // The notebook has moved to where the handle says, so the page it shows can be named.
      layoutBubble()
    }
  }
#endif
