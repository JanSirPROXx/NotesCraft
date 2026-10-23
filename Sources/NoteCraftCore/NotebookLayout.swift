import Foundation

// Where the pages of a notebook sit in one scrollable surface, at a zoom of 1 (fit). The surface is
// either a column (vertical, with gaps) or a row of cells as wide as the view (horizontal paging).
// Everything the scroll view needs to know follows from this and the zoom: which pages to build,
// which one is current, and where to scroll to, also after the view has been resized.
public struct NotebookLayout: Equatable, Sendable {
  public enum Axis: Sendable { case vertical, horizontal }

  // Space left and right of a page in a column, and above and below the whole notebook.
  public static let sideMargin = 20.0
  public static let topInset = 64.0
  public static let bottomInset = 40.0
  public static let gap = 28.0

  // A place in the notebook that survives a change of layout: a page, and how far through it the
  // top (or left) edge of the view is. An edge in the gap just above a page is kept as a distance
  // in points instead, so the gap does not stretch when the page does.
  public struct Anchor: Equatable, Sendable {
    public var index: Int
    public var fraction: Double
    public var before: Double
  }

  public let axis: Axis
  public let viewport: Point
  public private(set) var frames: [Rect] = []
  public private(set) var contentSize = Point(0, 0)

  public init(pageSizes: [Point], viewport: Point, axis: Axis, infinite: Bool = false) {
    self.axis = axis
    self.viewport = viewport
    switch axis {
    case .vertical: layoutColumn(pageSizes, infinite: infinite)
    case .horizontal: layoutRow(pageSizes)
    }
  }

  private mutating func layoutColumn(_ sizes: [Point], infinite: Bool) {
    let width = max(120, viewport.x - 2 * Self.sideMargin)
    let spacing = infinite ? 0 : Self.gap
    var y = infinite ? 0 : Self.topInset
    for size in sizes {
      let height = width * size.y / max(1, size.x)
      frames.append(Rect(x: (viewport.x - width) / 2, y: y, width: width, height: height))
      y += height + spacing
    }
    let bottom = infinite ? 0 : Self.bottomInset - spacing
    contentSize = Point(viewport.x, max(viewport.y, y + bottom))
  }

  // Each page gets a cell as wide as the view and is fitted whole into it.
  private mutating func layoutRow(_ sizes: [Point]) {
    let availableHeight = max(120, viewport.y - Self.topInset - Self.bottomInset)
    for (index, size) in sizes.enumerated() {
      let aspect = size.x / max(1, size.y)
      let width = max(120, min(viewport.x - 2 * Self.sideMargin, availableHeight * aspect))
      let height = width / max(0.01, aspect)
      frames.append(
        Rect(
          x: Double(index) * viewport.x + (viewport.x - width) / 2,
          y: Self.topInset + max(0, (availableHeight - height) / 2), width: width, height: height))
    }
    contentSize = Point(viewport.x * Double(max(1, sizes.count)), viewport.y)
  }

  public var count: Int { frames.count }

  private func start(_ rect: Rect) -> Double { axis == .vertical ? rect.y : rect.x }
  private func length(_ rect: Rect) -> Double { axis == .vertical ? rect.height : viewport.x }
  private func begin(of rect: Rect) -> Double {
    axis == .vertical ? rect.y : (rect.x - (viewport.x - rect.width) / 2)
  }

  // The pages worth having built for a visible rectangle (zoom-1 coordinates), with `margin` pages
  // on either side so a scroll never shows an empty page.
  public func indexes(visibleIn rect: Rect, margin: Int = 1) -> Range<Int> {
    guard !frames.isEmpty else { return 0..<0 }
    let lower = axis == .vertical ? rect.y : rect.x
    let upper = lower + (axis == .vertical ? rect.height : rect.width)
    var first = frames.count
    var last = -1
    for (index, frame) in frames.enumerated() {
      let a = begin(of: frame)
      let b = a + (axis == .vertical ? frame.height : viewport.x)
      if b >= lower && a <= upper {
        first = min(first, index)
        last = max(last, index)
      }
    }
    if last < 0 {
      // Past either end: the nearest page.
      let nearest = lower > (frames.last.map { begin(of: $0) } ?? 0) ? frames.count - 1 : 0
      first = nearest
      last = nearest
    }
    return max(0, first - margin)..<min(frames.count, last + margin + 1)
  }

  // The page that holds the most of the visible rectangle, which is the one the reader is on.
  public func currentIndex(visibleIn rect: Rect) -> Int {
    guard !frames.isEmpty else { return 0 }
    var best = 0
    var bestArea = -1.0
    for (index, frame) in frames.enumerated() {
      let cell =
        axis == .vertical
        ? frame
        : Rect(x: begin(of: frame), y: 0, width: viewport.x, height: viewport.y)
      let width = min(rect.x + rect.width, cell.x + cell.width) - max(rect.x, cell.x)
      let height = min(rect.y + rect.height, cell.y + cell.height) - max(rect.y, cell.y)
      let area = width > 0 && height > 0 ? width * height : 0
      if area > bestArea + 1e-6 {
        bestArea = area
        best = index
      }
    }
    if bestArea <= 0 {
      // Nothing of any page is visible (scrolled into a margin): the page that is closest.
      let lower = axis == .vertical ? rect.y : rect.x
      return frames.indices.min {
        abs(begin(of: frames[$0]) - lower) < abs(begin(of: frames[$1]) - lower)
      } ?? 0
    }
    return best
  }

  // Where the leading edge of the view (top, or left) is, as a place in the notebook.
  public func anchor(leadingEdge edge: Double) -> Anchor {
    guard !frames.isEmpty else { return Anchor(index: 0, fraction: 0, before: 0) }
    var index = 0
    for (i, frame) in frames.enumerated() where begin(of: frame) - gapBefore(i) <= edge { index = i }
    let start = begin(of: frames[index])
    if edge < start { return Anchor(index: index, fraction: 0, before: start - edge) }
    let extent = max(1, axis == .vertical ? frames[index].height : viewport.x)
    return Anchor(index: index, fraction: (edge - start) / extent, before: 0)
  }

  // Space between this page and the one above it that still belongs to this page's anchor.
  private func gapBefore(_ index: Int) -> Double {
    guard axis == .vertical, index > 0 else { return 0 }
    return frames[index].y - (frames[index - 1].y + frames[index - 1].height)
  }

  // The leading edge of the view that puts an anchor back where it was, in this layout.
  public func leadingEdge(of anchor: Anchor) -> Double {
    guard !frames.isEmpty else { return 0 }
    let frame = frames[min(frames.count - 1, max(0, anchor.index))]
    let start = begin(of: frame)
    if anchor.before > 0 { return start - anchor.before }
    let extent = max(1, axis == .vertical ? frame.height : viewport.x)
    return start + anchor.fraction * extent
  }

  // The scroll offset (zoom-1 points along the scroll axis) that shows a page: the top of a page a
  // little below the top of the view, or a whole cell of the row.
  public func offset(toShow index: Int) -> Double {
    guard !frames.isEmpty else { return 0 }
    let frame = frames[min(frames.count - 1, max(0, index))]
    switch axis {
    case .vertical: return max(0, frame.y - Self.topInset)
    case .horizontal: return begin(of: frame)
    }
  }
}
