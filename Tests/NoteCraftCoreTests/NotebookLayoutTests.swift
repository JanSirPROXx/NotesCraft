import Foundation
import Testing

@testable import NoteCraftCore

private let a4 = Point(595, 842)
private func pages(_ count: Int, size: Point = a4) -> [Point] { Array(repeating: size, count: count) }

// MARK: - column

@Test func aColumnStacksPagesWithGapsAndSideMargins() {
  let layout = NotebookLayout(pageSizes: pages(3), viewport: Point(800, 1000), axis: .vertical)
  #expect(layout.count == 3)
  let first = layout.frames[0]
  #expect(first.width == 760, "the view minus a margin on each side")
  #expect(first.x == 20)
  #expect(first.y == NotebookLayout.topInset)
  #expect(abs(first.height - 760 * 842 / 595) < 1e-9)
  let second = layout.frames[1]
  #expect(abs(second.y - (first.y + first.height + NotebookLayout.gap)) < 1e-9)
  let last = layout.frames[2]
  #expect(abs(layout.contentSize.y - (last.y + last.height + NotebookLayout.bottomInset)) < 1e-9)
  #expect(layout.contentSize.x == 800)
}

@Test func anInfiniteColumnHasNoGapsAndNoInsets() {
  let layout = NotebookLayout(
    pageSizes: pages(3), viewport: Point(800, 1000), axis: .vertical, infinite: true)
  #expect(layout.frames[0].y == 0)
  #expect(abs(layout.frames[1].y - layout.frames[0].height) < 1e-9)
  #expect(abs(layout.contentSize.y - (layout.frames[2].y + layout.frames[2].height)) < 1e-9)
}

@Test func aLandscapePageKeepsItsProportionsInAColumn() {
  let layout = NotebookLayout(
    pageSizes: [Point(842, 595)], viewport: Point(800, 1000), axis: .vertical)
  #expect(abs(layout.frames[0].height / layout.frames[0].width - 595.0 / 842) < 1e-9)
}

@Test func aShortNotebookStillFillsTheView() {
  let layout = NotebookLayout(
    pageSizes: [Point(595, 100)], viewport: Point(800, 1000), axis: .vertical)
  #expect(layout.contentSize.y >= 1000)
}

// MARK: - row

@Test func aRowGivesEachPageACellAsWideAsTheView() {
  let layout = NotebookLayout(pageSizes: pages(4), viewport: Point(1000, 800), axis: .horizontal)
  #expect(layout.contentSize == Point(4000, 800))
  for (index, frame) in layout.frames.enumerated() {
    let cellStart = Double(index) * 1000
    #expect(frame.x >= cellStart && frame.x + frame.width <= cellStart + 1000)
    #expect(abs((frame.x - cellStart) - (cellStart + 1000 - (frame.x + frame.width))) < 1e-9)
  }
}

@Test func aWholePageFitsIntoTheRowWithoutBeingCutOff() {
  let layout = NotebookLayout(pageSizes: pages(1), viewport: Point(1200, 800), axis: .horizontal)
  let frame = layout.frames[0]
  #expect(frame.y >= NotebookLayout.topInset)
  #expect(frame.y + frame.height <= 800 - NotebookLayout.bottomInset + 1e-9)
  #expect(abs(frame.width / frame.height - 595.0 / 842) < 1e-9)
}

@Test func aNarrowViewLimitsTheWidthOfAPageInARow() {
  let layout = NotebookLayout(pageSizes: pages(1), viewport: Point(400, 1400), axis: .horizontal)
  #expect(layout.frames[0].width == 360)
}

// MARK: - which pages

@Test func theCurrentPageIsTheOneThatHoldsMostOfTheView() {
  let layout = NotebookLayout(pageSizes: pages(6), viewport: Point(800, 1000), axis: .vertical)
  func current(_ edge: Double) -> Int {
    layout.currentIndex(visibleIn: Rect(x: 0, y: edge, width: 800, height: 1000))
  }
  #expect(current(0) == 0)
  #expect(current(layout.offset(toShow: 3)) == 3)
  // Halfway between two pages the lower one has the bigger share of the view.
  let between = layout.frames[2].y + layout.frames[2].height * 0.7
  #expect(current(between) == 3)
  #expect(current(100_000) == 5, "past the end is still the last page")
  #expect(current(-500) == 0)
}

@Test func theCurrentPageOfARowIsTheCellOnScreen() {
  let layout = NotebookLayout(pageSizes: pages(5), viewport: Point(1000, 800), axis: .horizontal)
  func current(_ edge: Double) -> Int {
    layout.currentIndex(visibleIn: Rect(x: edge, y: 0, width: 1000, height: 800))
  }
  #expect(current(0) == 0)
  #expect(current(2000) == 2)
  #expect(current(2400) == 2, "less than half of the way to the next page")
  #expect(current(2600) == 3)
}

@Test func onlyThePagesNearTheViewAreBuilt() {
  let layout = NotebookLayout(pageSizes: pages(300), viewport: Point(800, 1000), axis: .vertical)
  let edge = layout.offset(toShow: 150)
  let range = layout.indexes(visibleIn: Rect(x: 0, y: edge, width: 800, height: 1000))
  #expect(range.contains(150))
  #expect(range.count <= 5, "\(range)")
  // At the ends the range is clipped to the notebook.
  let top = layout.indexes(visibleIn: Rect(x: 0, y: 0, width: 800, height: 1000))
  #expect(top.lowerBound == 0)
  let bottom = layout.indexes(visibleIn: Rect(x: 0, y: 1e9, width: 800, height: 1000))
  #expect(bottom.upperBound == 300)
  #expect(!bottom.isEmpty)
}

@Test func zoomingOutShowsMorePagesAndZoomingInFewer() {
  let layout = NotebookLayout(pageSizes: pages(50), viewport: Point(800, 1000), axis: .vertical)
  // Zoom 0.5 shows twice the height of the notebook in the same view.
  let normal = layout.indexes(visibleIn: Rect(x: 0, y: 0, width: 800, height: 1000), margin: 0)
  let zoomedOut = layout.indexes(visibleIn: Rect(x: 0, y: 0, width: 1600, height: 2000), margin: 0)
  let zoomedIn = layout.indexes(visibleIn: Rect(x: 0, y: 3000, width: 160, height: 200), margin: 0)
  #expect(zoomedOut.count > normal.count)
  #expect(zoomedIn.count == 1)
}

@Test func anEmptyNotebookHasNothingToBuild() {
  let layout = NotebookLayout(pageSizes: [], viewport: Point(800, 1000), axis: .vertical)
  #expect(layout.indexes(visibleIn: Rect(x: 0, y: 0, width: 800, height: 1000)).isEmpty)
  #expect(layout.currentIndex(visibleIn: Rect(x: 0, y: 0, width: 800, height: 1000)) == 0)
  #expect(layout.offset(toShow: 3) == 0)
}

// MARK: - keeping the place

@Test func showingAPageOpensItsTopAndTheCurrentPageIsThatPage() {
  let layout = NotebookLayout(pageSizes: pages(12), viewport: Point(800, 1000), axis: .vertical)
  for index in 0..<12 {
    let edge = layout.offset(toShow: index)
    #expect(
      layout.currentIndex(visibleIn: Rect(x: 0, y: edge, width: 800, height: 1000)) == index,
      "page \(index + 1)")
  }
}

// The reported bug: choose page 8 with the sidebar open (a narrower view), close the sidebar (a
// wider one). The place must still be page 8, where the old arithmetic left the view on page 7.
@Test func theChosenPageSurvivesTheSidebarClosing() {
  let narrow = NotebookLayout(pageSizes: pages(12), viewport: Point(640, 1000), axis: .vertical)
  let wide = NotebookLayout(pageSizes: pages(12), viewport: Point(800, 1000), axis: .vertical)
  let edge = narrow.offset(toShow: 7)
  let anchor = narrow.anchor(leadingEdge: edge)
  let restored = wide.leadingEdge(of: anchor)
  #expect(
    wide.currentIndex(visibleIn: Rect(x: 0, y: restored, width: 800, height: 1000)) == 7)
  // Keeping the offset in points, as a scroll view does, lands on an earlier page.
  #expect(
    wide.currentIndex(visibleIn: Rect(x: 0, y: edge, width: 800, height: 1000)) != 7,
    "the arithmetic that was replaced")
}

@Test func theSameRowOfAPageStaysAtTheTopWhenThePageGrows() {
  let narrow = NotebookLayout(pageSizes: pages(8), viewport: Point(640, 1000), axis: .vertical)
  let wide = NotebookLayout(pageSizes: pages(8), viewport: Point(1000, 1000), axis: .vertical)
  // The view's top edge is a third of the way down page 5.
  let frame = narrow.frames[4]
  let edge = frame.y + frame.height / 3
  let anchor = narrow.anchor(leadingEdge: edge)
  #expect(anchor.index == 4)
  #expect(abs(anchor.fraction - 1.0 / 3) < 1e-9)
  let restored = wide.leadingEdge(of: anchor)
  let grown = wide.frames[4]
  #expect(abs((restored - grown.y) / grown.height - 1.0 / 3) < 1e-9)
}

@Test func theGapAboveAPageDoesNotStretchWithThePage() {
  let narrow = NotebookLayout(pageSizes: pages(3), viewport: Point(640, 1000), axis: .vertical)
  let wide = NotebookLayout(pageSizes: pages(3), viewport: Point(1000, 1000), axis: .vertical)
  // The edge is 10 points above page 2, in the gap.
  let edge = narrow.frames[1].y - 10
  let anchor = narrow.anchor(leadingEdge: edge)
  #expect(anchor.index == 1)
  #expect(anchor.before == 10)
  #expect(abs(wide.leadingEdge(of: anchor) - (wide.frames[1].y - 10)) < 1e-9)
}

@Test func aRowKeepsItsPageWhenTheViewIsResized() {
  let narrow = NotebookLayout(pageSizes: pages(6), viewport: Point(700, 800), axis: .horizontal)
  let wide = NotebookLayout(pageSizes: pages(6), viewport: Point(1000, 800), axis: .horizontal)
  let anchor = narrow.anchor(leadingEdge: narrow.offset(toShow: 4))
  #expect(anchor.index == 4)
  let restored = wide.leadingEdge(of: anchor)
  #expect(wide.currentIndex(visibleIn: Rect(x: restored, y: 0, width: 1000, height: 800)) == 4)
  #expect(abs(restored - wide.offset(toShow: 4)) < 1e-9)
}

@Test func anchorsOutsideTheNotebookAreClamped() {
  let layout = NotebookLayout(pageSizes: pages(3), viewport: Point(800, 1000), axis: .vertical)
  #expect(layout.anchor(leadingEdge: -300).index == 0)
  #expect(layout.anchor(leadingEdge: 1e9).index == 2)
  let past = NotebookLayout.Anchor(index: 99, fraction: 0.5, before: 0)
  #expect(layout.leadingEdge(of: past).isFinite)
}

// MARK: a row at a zoom

private func row(_ count: Int, zoom: Double, viewport: Point = Point(800, 1000)) -> NotebookLayout {
  NotebookLayout(
    pageSizes: Array(repeating: Point(600, 800), count: count), viewport: viewport,
    axis: .horizontal, zoom: zoom)
}

@Test func theGapBetweenPagesClosesAsTheRowIsZoomed() {
  // On the screen: the margins at fit, a thin line when zoomed.
  func screenGap(_ zoom: Double) -> Double { NotebookLayout.rowGap(atZoom: zoom) * zoom }
  #expect(abs(screenGap(1) - NotebookLayout.fitGap) < 1e-9)
  #expect(abs(screenGap(2) - NotebookLayout.zoomedGap) < 1e-9)
  #expect(abs(screenGap(6) - NotebookLayout.zoomedGap) < 1e-9)
  #expect(screenGap(1.25) < screenGap(1) && screenGap(1.25) > screenGap(2))
}

@Test func aRowAtFitHasOneCellAsWideAsTheViewPerPage() {
  let layout = row(3, zoom: 1)
  #expect(layout.contentSize.x == 2400)
  for index in 0..<3 {
    #expect(layout.pageRange(index, zoom: 1) == Double(index * 800)...Double(index * 800))
  }
  // The page sits in the middle of its cell.
  let frame = layout.frames[1]
  #expect(abs(frame.x + frame.width / 2 - 1200) < 1e-9)
}

@Test func zoomedInThePagesAreNextToEachOther() {
  let zoom = 3.0
  let layout = row(3, zoom: zoom)
  let gap = layout.frames[1].x - (layout.frames[0].x + layout.frames[0].width)
  #expect(abs(gap * zoom - NotebookLayout.zoomedGap) < 1e-6, "gap on the screen: \(gap * zoom)")
  // A page is as wide as the view minus the margins at fit, so zoomed it is wider than the view,
  // and its cell is the page and its share of the gap.
  let range = layout.pageRange(1, zoom: zoom)
  #expect(range.upperBound - range.lowerBound > 0)
  let cell = layout.pageRange(2, zoom: zoom).lowerBound - range.lowerBound
  #expect(abs(cell - (range.upperBound - range.lowerBound + 800)) < 1e-6)
}

@Test func turningAPageMovesTheViewByExactlyOneScreenAtAnyZoom() {
  // From the end of a page to the start of the next, however far the row is zoomed: a swipe is as
  // long zoomed as it is at fit.
  for zoom in [1.0, 1.5, 2, 4, 6] {
    let layout = row(3, zoom: zoom)
    let travel = layout.pageRange(1, zoom: zoom).lowerBound - layout.pageRange(0, zoom: zoom).upperBound
    #expect(abs(travel - 800) < 1e-6, "zoom \(zoom): \(travel)")
  }
}

@Test func theCurrentPageOfAZoomedRowIsTheOneUnderTheView() {
  let zoom = 2.0
  let layout = row(4, zoom: zoom)
  let cell = layout.pageRange(1, zoom: zoom).lowerBound
  let visible = Rect(x: (cell + 50) / zoom, y: 0, width: 800 / zoom, height: 1000 / zoom)
  #expect(layout.currentIndex(visibleIn: visible) == 1)
  let nearEnd = Rect(x: (layout.pageRange(1, zoom: zoom).upperBound - 10) / zoom, y: 0, width: 800 / zoom, height: 1000 / zoom)
  #expect(layout.currentIndex(visibleIn: nearEnd) == 1)
}

@Test func anAnchorSurvivesTheGapChangingWithTheZoom() {
  let before = row(5, zoom: 1)
  let anchor = before.anchor(leadingEdge: 2 * 800 + 400)
  #expect(anchor.index == 2)
  let after = row(5, zoom: 3)
  let edge = after.leadingEdge(of: anchor)
  #expect(after.anchor(leadingEdge: edge).index == 2)
}

// MARK: letting go of a row

private let zoomed = 3.0

private func release(
  _ layout: NotebookLayout, page: Int = 1, start: Double? = nil, offset: Double? = nil,
  projected: Double? = nil, velocity: Double = 0
) -> NotebookLayout.Release {
  let range = layout.pageRange(page, zoom: zoomed)
  let middle = (range.lowerBound + range.upperBound) / 2
  return layout.release(
    page: page, startedAt: start ?? middle, projected: projected ?? offset ?? start ?? middle,
    velocity: velocity, zoom: zoomed)
}

@Test func aSwipeInsideAZoomedPageOnlyPansAndStopsAtTheEdge() {
  let layout = row(4, zoom: zoomed)
  let range = layout.pageRange(1, zoom: zoomed)
  let middle = (range.lowerBound + range.upperBound) / 2
  // Slow: the view moves a little.
  #expect(release(layout, offset: middle + 30, projected: middle + 80, velocity: 200) == .stay(middle + 80))
  // Fast, and it would carry the view past the edge: it stops at the edge.
  #expect(release(layout, offset: middle + 30, projected: range.upperBound + 900, velocity: 3000) == .stay(range.upperBound))
}

@Test func aSwipeAtTheEdgeOfAZoomedPageTurnsToTheNextAtTheSameZoom() {
  let layout = row(4, zoom: zoomed)
  let range = layout.pageRange(1, zoom: zoomed)
  let next = layout.pageRange(2, zoom: zoomed)
  let result = release(layout, start: range.upperBound, offset: range.upperBound + 40, projected: range.upperBound + 60, velocity: 900)
  #expect(result == .flip(page: 2, offset: next.lowerBound))
  // Backwards from the start of a page, to the end of the one before.
  let back = release(layout, start: range.lowerBound, offset: range.lowerBound - 40, projected: range.lowerBound - 60, velocity: -900)
  #expect(back == .flip(page: 0, offset: layout.pageRange(0, zoom: zoomed).upperBound))
}

@Test func aSlowShortPullAtTheEdgeSpringsBack() {
  let layout = row(4, zoom: zoomed)
  let range = layout.pageRange(1, zoom: zoomed)
  #expect(release(layout, start: range.upperBound, offset: range.upperBound + 30, projected: range.upperBound + 30, velocity: 100) == .stay(range.upperBound))
}

@Test func aLongSlowPullAtTheEdgeTurnsThePage() {
  let layout = row(4, zoom: zoomed)
  let range = layout.pageRange(1, zoom: zoomed)
  let far = 800 * 0.3 + 60
  #expect(release(layout, start: range.upperBound, offset: range.upperBound + far, projected: range.upperBound + far, velocity: 50) == .flip(page: 2, offset: layout.pageRange(2, zoom: zoomed).lowerBound))
}

@Test func aDragFromTheMiddleOfAZoomedPageCannotLeaveIt() {
  let layout = row(4, zoom: zoomed)
  let range = layout.pageRange(1, zoom: zoomed)
  let middle = (range.lowerBound + range.upperBound) / 2
  #expect(layout.dragRange(page: 1, startedAt: middle, zoom: zoomed) == range)
  // However far it goes, a swipe that did not start at the edge does not turn the page.
  #expect(release(layout, start: middle, offset: range.upperBound + 500, projected: range.upperBound + 900, velocity: 3000) == .stay(range.upperBound))
}

@Test func aDragFromTheEdgeCanGoOnIntoTheNextPageButNoFurther() {
  let layout = row(4, zoom: zoomed)
  let range = layout.pageRange(1, zoom: zoomed)
  let next = layout.pageRange(2, zoom: zoomed)
  let previous = layout.pageRange(0, zoom: zoomed)
  #expect(layout.dragRange(page: 1, startedAt: range.upperBound, zoom: zoomed) == range.lowerBound...next.lowerBound)
  #expect(layout.dragRange(page: 1, startedAt: range.lowerBound + 5, zoom: zoomed) == previous.upperBound...range.upperBound)
}

@Test func atFitADragCanShowTheNeighboursOnBothSides() {
  let layout = row(4, zoom: 1)
  let here = layout.pageRange(1, zoom: 1).lowerBound
  #expect(layout.dragRange(page: 1, startedAt: here, zoom: 1) == 0...1600)
}

@Test func theEndsOfTheRowHaveNoPageToTurnTo() {
  let layout = row(3, zoom: zoomed)
  let last = layout.pageRange(2, zoom: zoomed)
  #expect(release(layout, page: 2, start: last.upperBound, offset: last.upperBound + 200, projected: last.upperBound + 200, velocity: 2000) == .stay(last.upperBound))
  let first = layout.pageRange(0, zoom: zoomed)
  #expect(release(layout, page: 0, start: first.lowerBound, offset: first.lowerBound - 200, projected: first.lowerBound - 200, velocity: -2000) == .stay(first.lowerBound))
}

@Test func atFitTheRowPagesLikeItAlwaysDid() {
  let layout = row(4, zoom: 1)
  let here = layout.pageRange(1, zoom: 1).lowerBound
  // Fast enough, or far enough, turns the page; a small slow move comes back.
  #expect(layout.release(page: 1, startedAt: here, projected: here + 150, velocity: 600, zoom: 1) == .flip(page: 2, offset: 1600))
  #expect(layout.release(page: 1, startedAt: here, projected: here - 300, velocity: -100, zoom: 1) == .flip(page: 0, offset: 0))
  #expect(layout.release(page: 1, startedAt: here, projected: here + 120, velocity: 100, zoom: 1) == .stay(here))
}
