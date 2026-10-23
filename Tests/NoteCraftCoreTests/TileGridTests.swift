import Foundation
import Testing

@testable import NoteCraftCore

private let page = Point(800, 1100)

@Test func aTileIsTheSameNumberOfPixelsAtEveryDensity() {
  for density in [1.0, 2, 4, 8, 12] {
    let grid = TileGrid(pageSize: page, density: density)
    let interior = TileGrid.ID(column: 0, row: 0)
    #expect(grid.pixelSize(of: interior).width == 512)
    #expect(grid.pixelSize(of: interior).height == 512)
    #expect(abs(grid.tileSize * density - 512) < 1e-9)
  }
}

@Test func theGridCoversThePageExactly() {
  let grid = TileGrid(pageSize: page, density: 2)  // 256 pt tiles
  #expect(grid.columns == 4 && grid.rows == 5)
  #expect(grid.count == 20)
  let last = TileGrid.ID(column: 3, row: 4)
  let corner = grid.rect(of: last)
  #expect(corner.x + corner.width == 800)
  #expect(corner.y + corner.height == 1100)
  // Together the tiles have the area of the page.
  var area = 0.0
  for row in 0..<grid.rows {
    for column in 0..<grid.columns {
      let r = grid.rect(of: .init(column: column, row: row))
      area += r.width * r.height
    }
  }
  #expect(abs(area - 800 * 1100) < 1e-6)
}

@Test func edgeTilesNeedSmallerBitmaps() {
  let grid = TileGrid(pageSize: page, density: 2)
  let edge = grid.pixelSize(of: .init(column: 3, row: 4))
  // 800 - 3 * 256 = 32 pt wide, 1100 - 4 * 256 = 76 pt tall.
  #expect(edge.width == 64 && edge.height == 152)
  #expect(grid.pixelSize(of: .init(column: 0, row: 4)).width == 512)
  #expect(grid.pixelSize(of: .init(column: 3, row: 0)).height == 512)
}

@Test func aRectangleSelectsTheTilesItTouches() {
  let grid = TileGrid(pageSize: page, density: 2)
  let ids = grid.ids(intersecting: Rect(x: 200, y: 200, width: 100, height: 100))
  // 200...300 spans columns 0 and 1, rows 0 and 1.
  #expect(Set(ids) == [.init(column: 0, row: 0), .init(column: 1, row: 0), .init(column: 0, row: 1), .init(column: 1, row: 1)])
  #expect(grid.ids(intersecting: Rect(x: 10, y: 10, width: 5, height: 5)) == [.init(column: 0, row: 0)])
}

@Test func aRectangleBeyondThePageSelectsOnlyWhatIsOnIt() {
  let grid = TileGrid(pageSize: page, density: 2)
  #expect(grid.ids(intersecting: Rect(x: 900, y: 0, width: 50, height: 50)).isEmpty)
  #expect(grid.ids(intersecting: Rect(x: -500, y: -500, width: 100, height: 100)).isEmpty)
  let overlapping = grid.ids(intersecting: Rect(x: -100, y: -100, width: 150, height: 150))
  #expect(overlapping == [.init(column: 0, row: 0)])
  let everything = grid.ids(intersecting: Rect(x: -1e6, y: -1e6, width: 2e6, height: 2e6))
  #expect(everything.count == grid.count)
}

@Test func zoomedInOnlyTheVisibleTilesExist() {
  // At 6x zoom and 2x screen the density is 12; a screen shows a sliver of the page.
  let grid = TileGrid(pageSize: page, density: 12)
  #expect(grid.count > 400, "the page as a whole would be \(grid.count) tiles")
  let view = Rect(x: 300, y: 500, width: 140, height: 180)
  let visible = grid.ids(intersecting: view)
  let withMargin = grid.ids(visible: view, margin: 0.5)
  #expect(visible.count <= 30)
  #expect(withMargin.count > visible.count)
  #expect(withMargin.count <= 80)
  #expect(Set(visible).isSubset(of: Set(withMargin)))
}

@Test func theMiddleOfTheViewComesFirst() {
  let grid = TileGrid(pageSize: page, density: 2)
  let view = Rect(x: 300, y: 300, width: 256, height: 256)
  let ids = grid.ordered(grid.ids(visible: view, margin: 1), around: view)
  let centre = grid.ids(intersecting: Rect(x: 427, y: 427, width: 1, height: 1))[0]
  #expect(ids.first == centre)
  // Distances never decrease along the list.
  var last = -1.0
  for id in ids {
    let r = grid.rect(of: id)
    let d = hypot(r.x + r.width / 2 - 428, r.y + r.height / 2 - 428)
    #expect(d >= last - 1e-9)
    last = d
  }
}

@Test func anEmptyPageHasNoTiles() {
  let grid = TileGrid(pageSize: Point(0, 0), density: 2)
  #expect(grid.count == 0)
  #expect(grid.ids(intersecting: Rect(x: 0, y: 0, width: 10, height: 10)).isEmpty)
}

@Test func aTileIsKnownToItsGrid() {
  let grid = TileGrid(pageSize: page, density: 2)
  #expect(grid.contains(.init(column: 3, row: 4)))
  #expect(!grid.contains(.init(column: 4, row: 0)))
  #expect(!grid.contains(.init(column: 0, row: -1)))
}

@Test func aRectangleTouchingTheFarEdgeOfAnExactGridDoesNotCrash() {
  // 512 pt tiles at density 1: a page of 1024 x 1536 is exactly 2 x 3 tiles.
  let grid = TileGrid(pageSize: Point(1024, 1536), density: 1)
  #expect(grid.columns == 2 && grid.rows == 3)
  #expect(grid.ids(intersecting: Rect(x: 0, y: 1536, width: 100, height: 0)).count <= 2)
  #expect(grid.ids(intersecting: Rect(x: 1024, y: 0, width: 0, height: 100)).count <= 3)
  #expect(grid.ids(intersecting: Rect(x: 1024, y: 1536, width: 0, height: 0)).count <= 1)
}
