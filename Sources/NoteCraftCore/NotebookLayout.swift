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
  // Between two pages of a row, as it is on the screen: at fit there is a margin on both sides of
  // a page, and the more the row is zoomed the closer the pages come, until they almost touch.
  public static let fitGap = 2 * sideMargin
  public static let zoomedGap = 12.0
  // How far past fit the pages take to come together.
  private static let closingZoom = 0.5

  // The space between two pages of a row at a zoom, in zoom-1 points (the layout's unit).
  public static func rowGap(atZoom zoom: Double) -> Double {
    let z = max(0.01, zoom)
    let closed = min(1, max(0, (z - 1) / closingZoom))
    return (fitGap + (zoomedGap - fitGap) * closed) / z
  }

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
  // A row: the stretch of the surface that belongs to each page, which is what the row pages by.
  private var cellStarts: [Double] = []
  private var cellWidths: [Double] = []

  // `zoom` only matters to a row, where the pages sit closer together the more it is zoomed; at a
  // zoom of 1 every page has a cell as wide as the view.
  public init(
    pageSizes: [Point], viewport: Point, axis: Axis, infinite: Bool = false, zoom: Double = 1
  ) {
    self.axis = axis
    self.viewport = viewport
    switch axis {
    case .vertical: layoutColumn(pageSizes, infinite: infinite)
    case .horizontal: layoutRow(pageSizes, zoom: zoom)
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

  // Each page is fitted whole into the view and gets a cell around it: as wide as the view, or at
  // a zoom where the page is wider than the view than the page and the gap to the next one. The
  // cell is where the row stops for a page, so a zoomed page can be panned across its cell and
  // the next page is one swipe away.
  private mutating func layoutRow(_ sizes: [Point], zoom: Double) {
    let z = max(0.01, zoom)
    let gap = Self.rowGap(atZoom: z)
    let availableHeight = max(120, viewport.y - Self.topInset - Self.bottomInset)
    var x = 0.0
    for size in sizes {
      let aspect = size.x / max(1, size.y)
      let width = max(120, min(viewport.x - 2 * Self.sideMargin, availableHeight * aspect))
      let height = width / max(0.01, aspect)
      let cell = max(width + gap, viewport.x / z)
      frames.append(
        Rect(
          x: x + (cell - width) / 2, y: Self.topInset + max(0, (availableHeight - height) / 2),
          width: width, height: height))
      cellStarts.append(x)
      cellWidths.append(cell)
      x += cell
    }
    contentSize = Point(max(viewport.x, x), viewport.y)
  }

  public var count: Int { frames.count }

  // Where the stretch of the surface that belongs to a page starts and how long it is.
  private func begin(_ index: Int) -> Double {
    axis == .vertical ? frames[index].y : cellStarts[index]
  }
  private func length(_ index: Int) -> Double {
    axis == .vertical ? frames[index].height : cellWidths[index]
  }

  // The pages worth having built for a visible rectangle (zoom-1 coordinates), with `margin` pages
  // on either side so a scroll never shows an empty page.
  public func indexes(visibleIn rect: Rect, margin: Int = 1) -> Range<Int> {
    guard !frames.isEmpty else { return 0..<0 }
    let lower = axis == .vertical ? rect.y : rect.x
    let upper = lower + (axis == .vertical ? rect.height : rect.width)
    var first = frames.count
    var last = -1
    for index in frames.indices {
      let a = begin(index)
      let b = a + length(index)
      if b >= lower && a <= upper {
        first = min(first, index)
        last = max(last, index)
      }
    }
    if last < 0 {
      // Past either end: the nearest page.
      let nearest = lower > begin(frames.count - 1) ? frames.count - 1 : 0
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
        : Rect(x: cellStarts[index], y: 0, width: cellWidths[index], height: viewport.y)
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
      return frames.indices.min { abs(begin($0) - lower) < abs(begin($1) - lower) } ?? 0
    }
    return best
  }

  // Where the leading edge of the view (top, or left) is, as a place in the notebook.
  public func anchor(leadingEdge edge: Double) -> Anchor {
    guard !frames.isEmpty else { return Anchor(index: 0, fraction: 0, before: 0) }
    var index = 0
    for i in frames.indices where begin(i) - gapBefore(i) <= edge { index = i }
    let start = begin(index)
    if edge < start { return Anchor(index: index, fraction: 0, before: start - edge) }
    let extent = max(1, length(index))
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
    let index = min(frames.count - 1, max(0, anchor.index))
    let start = begin(index)
    if anchor.before > 0 { return start - anchor.before }
    return start + anchor.fraction * max(1, length(index))
  }

  // The scroll offset (zoom-1 points along the scroll axis) that shows a page: the top of a page a
  // little below the top of the view, or a whole cell of the row.
  public func offset(toShow index: Int) -> Double {
    guard !frames.isEmpty else { return 0 }
    let index = min(frames.count - 1, max(0, index))
    switch axis {
    case .vertical: return max(0, frames[index].y - Self.topInset)
    case .horizontal: return begin(index)
    }
  }

  // MARK: paging a row

  // The offsets (in points of the surface as it is zoomed) the view can be at while it is on a
  // page: from the start of the page's cell to the offset that shows its end. A page that fits the
  // view has a single place, with the cell filling the view.
  public func pageRange(_ index: Int, zoom: Double) -> ClosedRange<Double> {
    guard axis == .horizontal, !frames.isEmpty else { return 0...0 }
    let i = min(frames.count - 1, max(0, index))
    let low = cellStarts[i] * zoom
    return low...max(low, (cellStarts[i] + cellWidths[i]) * zoom - viewport.x)
  }

  public enum Release: Equatable, Sendable {
    // Let the view come to rest at this offset, which is on the page.
    case stay(Double)
    // Turn to another page, with the view at this offset: the same place on the surface, only
    // moved sideways, so the zoom and the height stay.
    case flip(page: Int, offset: Double)
  }

  // How fast a swipe has to be, in points per second, to turn the page.
  public static let flickSpeed = 420.0
  // How near the edge of a page counts as being at it.
  public static let edgeSlack = 16.0

  // The offsets a finger that comes down at `start` can drag the view across: the page it is on, and
  // the next page too (or the one before) when it starts at that edge of the page. A drag that
  // starts inside a zoomed page therefore bounces at the edge of the page, like a pan inside one
  // zoomed photo, and it is the next swipe that turns the page.
  public func dragRange(page: Int, startedAt start: Double, zoom: Double) -> ClosedRange<Double> {
    guard axis == .horizontal, !frames.isEmpty else { return 0...0 }
    let page = min(frames.count - 1, max(0, page))
    let range = pageRange(page, zoom: zoom)
    var low = range.lowerBound
    var high = range.upperBound
    if start <= range.lowerBound + Self.edgeSlack, page > 0 {
      low = pageRange(page - 1, zoom: zoom).upperBound
    }
    if start >= range.upperBound - Self.edgeSlack, page + 1 < frames.count {
      high = pageRange(page + 1, zoom: zoom).lowerBound
    }
    return min(low, start)...max(high, start)
  }

  // What happens when a finger lets go of a row. `start` is where the view was when the finger came
  // down, `projected` where it would stop on its own, and `velocity` is in points per second,
  // positive towards the end of the row. A page turns when the swipe starts at the edge of the page
  // it is on and goes past it fast enough or far enough, as it does at fit; a swipe that starts
  // inside a zoomed page only pans, and stops at the edge.
  public func release(
    page: Int, startedAt start: Double, projected: Double, velocity: Double, zoom: Double
  ) -> Release {
    guard axis == .horizontal, !frames.isEmpty else { return .stay(projected) }
    let page = min(frames.count - 1, max(0, page))
    let range = pageRange(page, zoom: zoom)
    let third = viewport.x * 0.3
    let atEnd = start >= range.upperBound - Self.edgeSlack
    let atStart = start <= range.lowerBound + Self.edgeSlack
    let forward =
      page + 1 < frames.count
      && atEnd && (velocity > Self.flickSpeed || projected - range.upperBound > third)
    let back =
      page > 0
      && atStart && (velocity < -Self.flickSpeed || range.lowerBound - projected > third)
    if forward && (!back || velocity >= 0) {
      return .flip(page: page + 1, offset: pageRange(page + 1, zoom: zoom).lowerBound)
    }
    if back {
      return .flip(page: page - 1, offset: pageRange(page - 1, zoom: zoom).upperBound)
    }
    return .stay(min(max(projected, range.lowerBound), range.upperBound))
  }
}
