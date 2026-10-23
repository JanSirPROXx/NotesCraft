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
    var onCurrentPage: (Int) -> Void
    var onZoom: (Double) -> Void
    var onPull: (Double) -> Void
    var onAppend: () -> Void
    var onTrailingReached: () -> Void
    var onScrollActivity: () -> Void
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
    private var hosts: [UUID: UIHostingController<AnyView>] = [:]
    private var props: NotebookDocumentView?
    private var layout = NotebookLayout(pageSizes: [], viewport: Point(0, 0), axis: .vertical)
    // The place the reader is at, as a page and how far through it, so a change of layout puts the
    // view back on the same part of the same page.
    private var place: (id: UUID, anchor: NotebookLayout.Anchor)?
    private var laidOut = false
    private var reportedIndex = -1
    private var animatingTo: Int?
    private var restoring = false
    private var dragStartOffset = 0.0
    private var pullStarted: TimeInterval?
    private var pullTriggered = false
    private var lastZoomReport = 0.0
    private var lastSelected = -1

    private var zoom: CGFloat { scroll.zoomScale }
    private var columns: Bool { props?.axis != .horizontal }

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
    }

    // Only a finger moves or zooms the paper; Pencil draws. The canvas keeps the pan up to date while
    // a stroke is under way (`configureScrolling`). The pinch recognizer only exists while the zoom
    // range is a range, so this is repeated whenever that changes.
    private func configureGestures() {
      let finger = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
      scroll.panGestureRecognizer.allowedTouchTypes = finger
      scroll.pinchGestureRecognizer?.allowedTouchTypes = finger
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
        if new.selectedIndex != reportedIndex, laidOut, new.ids.indices.contains(new.selectedIndex) {
          let distance = abs(new.selectedIndex - max(0, reportedIndex))
          show(new.selectedIndex, animated: distance <= 1 && reportedIndex >= 0)
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

    private func updateInsets() {
      let width = scroll.contentSize.width
      let height = scroll.contentSize.height
      let x = max(0, (scroll.bounds.width - width) / 2)
      let y = columns ? 0 : max(0, (scroll.bounds.height - height) / 2)
      let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
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

    private func syncHosts() {
      guard let props, layout.count == props.ids.count else { return }
      let range = layout.indexes(visibleIn: visibleRect(), margin: 1)
      let wanted = Set(range.map { props.ids[$0] })
      for (id, host) in hosts where !wanted.contains(id) {
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        hosts[id] = nil
      }
      for index in range {
        let id = props.ids[index]
        let frame = CGRect(
          x: layout.frames[index].x, y: layout.frames[index].y, width: layout.frames[index].width,
          height: layout.frames[index].height)
        if let host = hosts[id] {
          if host.view.frame != frame { host.view.frame = frame }
          continue
        }
        let host = UIHostingController(rootView: props.content(index, frame.size))
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.frame = frame
        addChild(host)
        surface.addSubview(host.view)
        host.didMove(toParent: self)
        hosts[id] = host
        // A page that appears while the paper is zoomed has to be drawn for that zoom.
        if zoom > 1.01 {
          host.view.layoutIfNeeded()
          refreshResolution(host.view)
        }
      }
    }

    private func refreshHosts() {
      guard let props, layout.count == props.ids.count else { return }
      for (index, id) in props.ids.enumerated() {
        guard let host = hosts[id] else { continue }
        host.rootView = props.content(index, host.view.frame.size)
      }
      syncHosts()
    }

    // The canvases draw at the resolution of the zoom they were last settled at.
    private func refreshResolution(_ view: UIView) {
      if let canvas = view as? DrawingView {
        canvas.contentScaleFactor = UIScreen.main.scale * min(4, zoom)
        canvas.cachedPage = nil
        canvas.setNeedsDisplay()
      }
      for child in view.subviews { refreshResolution(child) }
    }

    // MARK: navigation

    private func show(_ index: Int, animated: Bool) {
      guard let props, props.ids.indices.contains(index), layout.count == props.ids.count else {
        return
      }
      let edge = CGFloat(layout.offset(toShow: index)) * zoom
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
      let now = ProcessInfo.processInfo.systemUptime
      if now - lastZoomReport > 0.1 {
        lastZoomReport = now
        props?.onZoom(Double(zoom))
      }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
      guard !restoring else { return }
      props?.onZoom(Double(scale))
      for host in hosts.values { refreshResolution(host.view) }
      place = currentPlace()
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
      if animatingTo == nil {
        let index = layout.currentIndex(visibleIn: visibleRect())
        if index != reportedIndex {
          reportedIndex = index
          props.onCurrentPage(index)
        }
      }
      place = currentPlace()
      if scrollView.isDragging || scrollView.isDecelerating { props.onScrollActivity() }
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

    private func settled() {
      place = currentPlace()
      guard let props, layout.count == props.ids.count, let trailing = props.trailingIndex else {
        return
      }
      if layout.currentIndex(visibleIn: visibleRect()) == trailing { props.onTrailingReached() }
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
