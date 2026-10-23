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
