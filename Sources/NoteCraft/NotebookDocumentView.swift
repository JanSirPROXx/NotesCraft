#if os(iOS)
  import NoteCraftCore
  import SwiftUI
  import UIKit

  // The scroll views that zoom the paper. The canvas needs to treat them alike: Pencil never moves
  // them, and a pinch is theirs.
  @MainActor protocol ZoomingSurface: UIScrollView { var allowsZoom: Bool { get } }
  extension NotebookZoomScrollView: ZoomingSurface {}

  // One scroll view for the whole notebook, so the pages scroll and zoom together as one document
  // instead of each page zooming inside its own frame.
  @MainActor final class DocumentScrollView: UIScrollView, ZoomingSurface {
    var allowsZoom = true
    var onBoundsChange: (() -> Void)?
    private var laidOutSize = CGSize.zero

    override func layoutSubviews() {
      super.layoutSubviews()
      guard bounds.size != laidOutSize else { return }
      laidOutSize = bounds.size
      onBoundsChange?()
    }
  }

  // "3 / 12", shown in a corner while the notebook scrolls or changes page. It lives here, not in
  // the SwiftUI view above, because every SwiftUI state change while a finger is scrolling costs
  // a pass over every page that is on screen.
  @MainActor private final class PageIndicator: UIView {
    private let label = UILabel()
    private var hideTask: Task<Void, Never>?
    private var shownAt = 0.0

    override init(frame: CGRect) {
      super.init(frame: frame)
      let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
      blur.frame = bounds
      blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      blur.isUserInteractionEnabled = false
      addSubview(blur)
      label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
      label.textColor = .label
      label.textAlignment = .center
      label.accessibilityIdentifier = "pageIndicator"
      addSubview(label)
      clipsToBounds = true
      isUserInteractionEnabled = false
      isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    func show(page: Int, of count: Int, force: Bool = false) {
      let now = ProcessInfo.processInfo.systemUptime
      // Scrolling asks every frame; the timer only needs restarting now and then.
      guard force || isHidden || now - shownAt > 0.4 else { return }
      shownAt = now
      label.text = "\(page) / \(count)"
      label.sizeToFit()
      let size = CGSize(width: label.bounds.width + 24, height: 34)
      if let superview {
        frame = CGRect(
          x: superview.bounds.width - size.width - 18,
          y: superview.bounds.height - size.height - 18 - superview.safeAreaInsets.bottom,
          width: size.width, height: size.height)
      }
      layer.cornerRadius = size.height / 2
      label.frame = bounds
      isHidden = false
      alpha = 1
      hideTask?.cancel()
      hideTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(1500))
        guard !Task.isCancelled, let self else { return }
        UIView.animate(withDuration: 0.25) { self.alpha = 0 } completion: { _ in
          if self.alpha == 0 { self.isHidden = true }
        }
      }
    }
  }

  struct NotebookDocumentView: UIViewControllerRepresentable {
    var ids: [UUID]
    var sizes: [Point]
    var axis: NotebookLayout.Axis
    var infinite: Bool
    var selectedIndex: Int
    // The blank page after the last one that is not part of the notebook yet: scrolling onto it
    // makes it a real page.
    var trailingIndex: Int?
    // Pulling past the end of a column adds a page.
    var canPull: Bool
    // Reported when the paper has come to rest, not while it moves: a state change in the view
    // above while a finger is scrolling makes every page on screen redo its work.
    var onCurrentPage: (Int) -> Void
    var onZoom: (Double) -> Void
    var onPull: (Double) -> Void
    var onAppend: () -> Void
    var onTrailingReached: () -> Void
    var content: (Int, CGSize) -> AnyView

    func makeUIViewController(context: Context) -> NotebookDocumentController {
      NotebookDocumentController()
    }
    func updateUIViewController(_ controller: NotebookDocumentController, context: Context) {
      controller.update(self)
    }
  }

  @MainActor final class NotebookDocumentController: UIViewController, UIScrollViewDelegate {
    private let scroll = DocumentScrollView()
    // The zoomed surface: every page sits on it at fit size, and the scroll view scales it.
    private let surface = UIView()
    private let indicator = PageIndicator()
    private var hosts: [UUID: UIHostingController<AnyView>] = [:]
    // What a page that is still being built shows in its place.
    private var placeholders: [UUID: UIView] = [:]
    // The pixel density each page was last given; see `NativeCanvas`.
    private var scales: [UUID: CanvasDensity] = [:]
    private var props: NotebookDocumentView?
    private var layout = NotebookLayout(pageSizes: [], viewport: Point(0, 0), axis: .vertical)
    // The place the reader is at, as a page and how far through it, so a change of layout puts the
    // view back on the same part of the same page.
    private var place: (id: UUID, anchor: NotebookLayout.Anchor)?
    private var laidOut = false
    // The page the paper is on, as far as scrolling is concerned, and the last one told to the
    // view above.
    private var reportedIndex = -1
    private var deliveredIndex = -1
    private var animatingTo: Int?
    private var restoring = false
    private var syncScheduled = false
    private var dragStartOffset = 0.0
    private var pullStarted: TimeInterval?
    private var pullTriggered = false
    private var lastSelected = -1

    private var zoom: CGFloat { scroll.zoomScale }
    private var columns: Bool { props?.axis != .horizontal }
    private var realPageCount: Int { props?.trailingIndex ?? props?.ids.count ?? 0 }

    override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = UIColor(red: 0.105, green: 0.11, blue: 0.115, alpha: 1)
      scroll.frame = view.bounds
      scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      scroll.delegate = self
      scroll.backgroundColor = .clear
      scroll.contentInsetAdjustmentBehavior = .never
      scroll.bouncesZoom = true
      scroll.delaysContentTouches = false
      scroll.showsHorizontalScrollIndicator = false
      scroll.accessibilityIdentifier = "notebookScrollView"
      scroll.minimumZoomScale = 0.5
      scroll.maximumZoomScale = 6
      configureGestures()
      scroll.onBoundsChange = { [weak self] in self?.applyLayout() }
      scroll.addSubview(surface)
      view.addSubview(scroll)
      view.addSubview(indicator)
    }

    // Only a finger moves or zooms the paper; Pencil draws. The canvas keeps the pan up to date while
    // a stroke is under way (`configureScrolling`). The pinch recognizer only exists while the zoom
    // range is a range, so this is repeated whenever that changes.
    private func configureGestures() {
      let finger = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
      if scroll.panGestureRecognizer.allowedTouchTypes != finger {
        scroll.panGestureRecognizer.allowedTouchTypes = finger
      }
      if let pinch = scroll.pinchGestureRecognizer, pinch.allowedTouchTypes != finger {
        pinch.allowedTouchTypes = finger
      }
    }

    // MARK: updates from SwiftUI

    func update(_ new: NotebookDocumentView) {
      let old = props
      props = new
      let structural =
        old == nil || old?.ids != new.ids || old?.sizes != new.sizes || old?.axis != new.axis
        || old?.infinite != new.infinite
      if old == nil {
        // The notebook opens on the page that was current.
        lastSelected = new.selectedIndex
        reportedIndex = new.selectedIndex
        deliveredIndex = new.selectedIndex
      }
      if structural {
        applyLayout()
      } else {
        refreshHosts()
      }
      // The page was chosen somewhere else (sidebar, page number, a new page): go there. A page
      // the scroll view itself reported is where it already is.
      if new.selectedIndex != lastSelected {
        lastSelected = new.selectedIndex
        deliveredIndex = new.selectedIndex
        if new.selectedIndex != reportedIndex, laidOut, new.ids.indices.contains(new.selectedIndex) {
          let distance = abs(new.selectedIndex - max(0, reportedIndex))
          show(new.selectedIndex, animated: distance <= 1 && reportedIndex >= 0)
        }
        if new.selectedIndex < realPageCount {
          indicator.show(page: new.selectedIndex + 1, of: realPageCount, force: true)
        }
      }
    }

    // MARK: layout

    private func visibleRect() -> Rect {
      let z = max(0.0001, Double(zoom))
      return Rect(
        x: Double(scroll.contentOffset.x) / z, y: Double(scroll.contentOffset.y) / z,
        width: Double(scroll.bounds.width) / z, height: Double(scroll.bounds.height) / z)
    }

    // The place at the leading edge of the view in the current layout.
    private func currentPlace() -> (id: UUID, anchor: NotebookLayout.Anchor)? {
      guard laidOut, let props, !props.ids.isEmpty, layout.count == props.ids.count else {
        return place
      }
      let z = Double(zoom)
      let edge = (columns ? Double(scroll.contentOffset.y) : Double(scroll.contentOffset.x)) / z
      let anchor = layout.anchor(leadingEdge: edge)
      return (props.ids[min(anchor.index, props.ids.count - 1)], anchor)
    }

    private func applyLayout() {
      guard let props, scroll.bounds.width > 1, scroll.bounds.height > 1 else { return }
      var oldPlace = currentPlace() ?? place
      let oldCenterX =
        scroll.contentSize.width > 0
        ? (scroll.contentOffset.x + scroll.bounds.width / 2) / scroll.contentSize.width : 0.5
      let targetZoom = zoom
      layout = NotebookLayout(
        pageSizes: props.sizes,
        viewport: Point(Double(scroll.bounds.width), Double(scroll.bounds.height)),
        axis: props.axis, infinite: props.infinite)
      restoring = true
      defer { restoring = false }
      scroll.minimumZoomScale = props.infinite ? 1 : (props.axis == .horizontal ? 1 : 0.5)
      scroll.maximumZoomScale = props.infinite ? 1 : 6
      configureGestures()
      scroll.allowsZoom = !props.infinite
      scroll.decelerationRate = props.axis == .horizontal ? .fast : .normal
      scroll.alwaysBounceVertical = props.axis == .vertical
      scroll.alwaysBounceHorizontal = props.axis == .horizontal
      scroll.showsVerticalScrollIndicator = props.axis == .vertical
      // The frame of the surface is only meaningful at a zoom of 1.
      scroll.setZoomScale(1, animated: false)
      surface.frame = CGRect(
        x: 0, y: 0, width: layout.contentSize.x, height: layout.contentSize.y)
      scroll.contentSize = surface.frame.size
      scroll.setZoomScale(
        min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, targetZoom)), animated: false)
      updateInsets()
      // The first time, the top of the page that was current.
      if oldPlace == nil, !props.ids.isEmpty {
        let index = min(max(0, props.selectedIndex), props.ids.count - 1)
        oldPlace = (props.ids[index], layout.anchor(leadingEdge: layout.offset(toShow: index)))
      }
      // Back to the same place on the same page, also when the view has become wider or narrower.
      var offset = scroll.contentOffset
      if let oldPlace, let index = props.ids.firstIndex(of: oldPlace.id) {
        var anchor = oldPlace.anchor
        anchor.index = index
        let edge = CGFloat(layout.leadingEdge(of: anchor)) * zoom
        if columns {
          offset.y = edge
          offset.x = oldCenterX * scroll.contentSize.width - scroll.bounds.width / 2
        } else {
          offset.x = edge
        }
      } else if let oldPlace, !props.ids.isEmpty {
        // The page is gone: the one that took its place.
        let index = min(oldPlace.anchor.index, props.ids.count - 1)
        offset = columns
          ? CGPoint(x: offset.x, y: CGFloat(layout.offset(toShow: index)) * zoom)
          : CGPoint(x: CGFloat(layout.offset(toShow: index)) * zoom, y: offset.y)
      }
      scroll.contentOffset = clamped(offset)
      laidOut = true
      scroll.accessibilityValue = "Zoom \(Int((zoom * 100).rounded())) percent"
      // The pages are drawn at the size they now have, not the one they had.
      refreshHosts()
      place = currentPlace()
    }

    // A column keeps the same margin between a page and the edge of the screen however far it is
    // zoomed, as Goodnotes does: the margins grow with the zoom like everything else on the
    // surface, so they are trimmed again, and the page edge is where panning ends. Zoomed out, a
    // column that is narrower than the view is centred.
    private func updateInsets() {
      let z = zoom
      let width = scroll.contentSize.width
      let height = scroll.contentSize.height
      var inset = UIEdgeInsets.zero
      if columns, z > 1 {
        // Never more than there is to scroll, so trimming cannot make the surface smaller than the view.
        let spareX = max(0, (width - scroll.bounds.width) / 2)
        let spareY = max(0, (height - scroll.bounds.height) / 2)
        let side = min(CGFloat(NotebookLayout.sideMargin) * (z - 1), spareX)
        let top = min(CGFloat(NotebookLayout.topInset) * (z - 1), spareY)
        let bottom = min(CGFloat(NotebookLayout.bottomInset) * (z - 1), spareY)
        inset = UIEdgeInsets(top: -top, left: -side, bottom: -bottom, right: -side)
      } else {
        let x = max(0, (scroll.bounds.width - width) / 2)
        let y = columns ? 0 : max(0, (scroll.bounds.height - height) / 2)
        inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
      }
      if scroll.contentInset != inset { scroll.contentInset = inset }
    }

    private func clamped(_ offset: CGPoint) -> CGPoint {
      let inset = scroll.contentInset
      let minX = -inset.left
      let minY = -inset.top
      let maxX = max(minX, scroll.contentSize.width - scroll.bounds.width + inset.right)
      let maxY = max(minY, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
      return CGPoint(x: min(max(offset.x, minX), maxX), y: min(max(offset.y, minY), maxY))
    }

    // MARK: pages

    // The densities a page is drawn at. The page itself is cut into tiles at exactly the density it
    // is seen at, which is the screen's times the zoom. The views as large as the page above it
    // are capped so that their backing store does not pass the 4096 pixels a page was drawn at
    // before tiles.
    private func canvasDensity(for frame: CGRect) -> CanvasDensity {
      let screen = UIScreen.main.scale
      let capped = screen * min(4, max(0.25, zoom))
      return CanvasDensity(
        overlay: max(1, min(capped, 4096 / max(1, max(frame.width, frame.height)))),
        tiles: max(1, screen * zoom))
    }

    private func rootView(_ index: Int, _ id: UUID, _ size: CGSize) -> AnyView {
      guard let props else { return AnyView(EmptyView()) }
      return AnyView(props.content(index, size).environment(\.canvasDensity, scales[id]))
    }

    // Builds the pages near the view. Building a page costs a good part of a frame, so a scroll that
    // brings several into range builds one per frame and shows a blank sheet for the others: a
    // stutter in the scroll is worse than a page that fills in a moment later.
    private func syncHosts() {
      guard let props, layout.count == props.ids.count else { return }
      let rect = visibleRect()
      let range = layout.indexes(visibleIn: rect, margin: 1)
      let wanted = Set(range.map { props.ids[$0] })
      for (id, host) in hosts where !wanted.contains(id) {
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        hosts[id] = nil
        scales[id] = nil
      }
      for (id, view) in placeholders where !wanted.contains(id) || hosts[id] != nil {
        view.removeFromSuperview()
        placeholders[id] = nil
      }
      // Pages on screen before the ones that are only close.
      let centreY = rect.y + rect.height / 2
      let centreX = rect.x + rect.width / 2
      let across = columns
      let frames = layout.frames
      let ordered = range.sorted { a, b in
        func distance(_ i: Int) -> Double {
          let f = frames[i]
          return across ? abs(f.y + f.height / 2 - centreY) : abs(f.x + f.width / 2 - centreX)
        }
        return distance(a) < distance(b)
      }
      var built = 0
      var deferred = false
      for index in ordered {
        let id = props.ids[index]
        let f = layout.frames[index]
        let frame = CGRect(x: f.x, y: f.y, width: f.width, height: f.height)
        if let host = hosts[id] {
          if host.view.frame != frame { host.view.frame = frame }
          // A page that has come into view is drawn for the zoom it is seen at now.
          let wantedScale = canvasDensity(for: frame)
          if scales[id] != wantedScale, !scroll.isZooming, intersectsVisible(f, rect) {
            scales[id] = wantedScale
            host.rootView = rootView(index, id, frame.size)
          }
          continue
        }
        if built >= 1 {
          deferred = true
          let placeholder = placeholders[id] ?? makePlaceholder(id)
          placeholder.frame = frame
          continue
        }
        built += 1
        scales[id] = canvasDensity(for: frame)
        let host = UIHostingController(rootView: rootView(index, id, frame.size))
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.frame = frame
        addChild(host)
        surface.addSubview(host.view)
        host.didMove(toParent: self)
        hosts[id] = host
        if let placeholder = placeholders[id] {
          placeholder.removeFromSuperview()
          placeholders[id] = nil
        }
      }
      if deferred { scheduleSync() }
    }

    private func intersectsVisible(_ frame: Rect, _ rect: Rect) -> Bool {
      frame.x <= rect.x + rect.width && frame.x + frame.width >= rect.x
        && frame.y <= rect.y + rect.height && frame.y + frame.height >= rect.y
    }

    private func makePlaceholder(_ id: UUID) -> UIView {
      let sheet = UIView()
      sheet.backgroundColor = .white
      if props?.infinite != true {
        sheet.layer.shadowColor = UIColor.black.cgColor
        sheet.layer.shadowOpacity = 0.10
        sheet.layer.shadowRadius = 6
        sheet.layer.shadowOffset = CGSize(width: 0, height: 2)
      }
      surface.addSubview(sheet)
      placeholders[id] = sheet
      return sheet
    }

    private func scheduleSync() {
      guard !syncScheduled else { return }
      syncScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.syncScheduled = false
        self.syncHosts()
      }
    }

    private func refreshHosts() {
      guard let props, layout.count == props.ids.count else { return }
      for (index, id) in props.ids.enumerated() {
        guard let host = hosts[id] else { continue }
        host.rootView = rootView(index, id, host.view.frame.size)
      }
      syncHosts()
    }

    // MARK: navigation

    private func show(_ index: Int, animated: Bool) {
      guard let props, props.ids.indices.contains(index), layout.count == props.ids.count else {
        return
      }
      // A column puts the page a fixed distance below the top of the view at any zoom; a row puts
      // its cell at the left.
      let edge =
        columns
        ? CGFloat(layout.frames[index].y) * zoom - CGFloat(NotebookLayout.topInset)
        : CGFloat(layout.offset(toShow: index)) * zoom
      var target = scroll.contentOffset
      if columns { target.y = edge } else { target.x = edge }
      target = clamped(target)
      animatingTo = animated ? index : nil
      reportedIndex = index
      restoring = !animated
      scroll.setContentOffset(target, animated: animated)
      if !animated {
        restoring = false
        syncHosts()
        place = currentPlace()
      }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      props?.infinite == true ? nil : surface
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
      guard !restoring else { return }
      updateInsets()
      syncHosts()
      scroll.accessibilityValue = "Zoom \(Int((zoom * 100).rounded())) percent"
    }

    // Everything that has to redo work for the new zoom waits until the fingers have lifted: the
    // pinch itself is only a scale of what is already drawn.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
      guard !restoring else { return }
      props?.onZoom(Double(scale))
      syncHosts()
      place = currentPlace()
      settled()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      dragStartOffset = Double(scrollView.contentOffset.x)
      animatingTo = nil
    }

    // In a row the paper settles on one page at a time while it is not zoomed.
    func scrollViewWillEndDragging(
      _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
      targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
      guard props?.axis == .horizontal, zoom < 1.02 else { return }
      targetContentOffset.pointee.x = CGFloat(
        NotebookPaging.target(
          origin: dragStartOffset, projected: Double(targetContentOffset.pointee.x),
          velocity: Double(velocity.x) * 1000, pageWidth: Double(scrollView.bounds.width),
          contentWidth: Double(scrollView.contentSize.width)))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      guard !restoring, laidOut, let props, layout.count == props.ids.count else { return }
      syncHosts()
      place = currentPlace()
      if animatingTo == nil {
        let index = layout.currentIndex(visibleIn: visibleRect())
        if index != reportedIndex { reportedIndex = index }
        if scrollView.isDragging || scrollView.isDecelerating, index < realPageCount {
          indicator.show(page: index + 1, of: realPageCount)
        }
      }
      checkPull(scrollView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
      if !decelerate { settled() }
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
      animatingTo = nil
      settled()
    }

    // The paper has come to rest: now the view above is told where it is.
    private func settled() {
      place = currentPlace()
      guard let props, layout.count == props.ids.count else { return }
      let index = layout.currentIndex(visibleIn: visibleRect())
      reportedIndex = index
      if index != deliveredIndex {
        deliveredIndex = index
        props.onCurrentPage(index)
      }
      if let trailing = props.trailingIndex, index == trailing { props.onTrailingReached() }
    }

    // Pulling past the end of a column and holding it adds a page.
    private func checkPull(_ scrollView: UIScrollView) {
      guard let props, props.canPull, columns, !props.infinite, scrollView.isDragging,
        !pullTriggered
      else {
        if !scrollView.isDragging {
          pullTriggered = false
          if pullStarted != nil {
            pullStarted = nil
            self.props?.onPull(0)
          }
        }
        return
      }
      let end = max(
        -scrollView.contentInset.top,
        scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
      let overshoot = scrollView.contentOffset.y - end
      guard overshoot > 60 else {
        if pullStarted != nil {
          pullStarted = nil
          props.onPull(0)
        }
        return
      }
      let now = ProcessInfo.processInfo.systemUptime
      if pullStarted == nil {
        pullStarted = now
        // A held finger sends no more scroll events, so the check is repeated until it lets go.
        Task { @MainActor [weak self] in
          while let self, self.pullStarted != nil, !self.pullTriggered {
            try? await Task.sleep(for: .milliseconds(30))
            self.checkPull(self.scroll)
          }
        }
      }
      let progress = min(1, (now - (pullStarted ?? now)) / 0.2)
      props.onPull(progress)
      if progress >= 1 {
        pullTriggered = true
        pullStarted = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        props.onAppend()
        props.onPull(0)
      }
    }
  }
#endif
