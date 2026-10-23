import Foundation

// How a page is cut into tiles for drawing. A page that is zoomed in can need far more pixels than
// a screen can hold, but only the part that is on screen has to exist, so the page is drawn in small
// square tiles at exactly the density it is seen at, and only the tiles near the view are kept.
// Everything is in the unit the page is shown in (view points); `density` is device pixels per such
// point, so a tile is always the same number of pixels whatever the zoom.
public struct TileGrid: Equatable, Sendable {
  public struct ID: Hashable, Sendable {
    public var column: Int
    public var row: Int
    public init(column: Int, row: Int) {
      self.column = column
      self.row = row
    }
  }

  public let pageSize: Point
  public let density: Double
  public let tilePixels: Int
  // The edge of a tile in view points.
  public let tileSize: Double
  public let columns: Int
  public let rows: Int

  public init(pageSize: Point, density: Double, tilePixels: Int = 512) {
    self.pageSize = pageSize
    self.density = max(0.01, density)
    self.tilePixels = max(16, tilePixels)
    tileSize = Double(self.tilePixels) / self.density
    columns = pageSize.x > 0 ? Int((pageSize.x / tileSize).rounded(.up)) : 0
    rows = pageSize.y > 0 ? Int((pageSize.y / tileSize).rounded(.up)) : 0
  }

  public var count: Int { columns * rows }

  // The area a tile covers; the tiles on the right and bottom edges stop at the page.
  public func rect(of id: ID) -> Rect {
    let x = Double(id.column) * tileSize
    let y = Double(id.row) * tileSize
    return Rect(
      x: x, y: y, width: min(tileSize, pageSize.x - x), height: min(tileSize, pageSize.y - y))
  }

  // The bitmap a tile needs: a whole tile everywhere but along the edges.
  public func pixelSize(of id: ID) -> (width: Int, height: Int) {
    let r = rect(of: id)
    if r.width >= tileSize - 1e-9, r.height >= tileSize - 1e-9 { return (tilePixels, tilePixels) }
    return (
      max(1, min(tilePixels, Int((r.width * density).rounded(.up)))),
      max(1, min(tilePixels, Int((r.height * density).rounded(.up))))
    )
  }

  public func contains(_ id: ID) -> Bool {
    id.column >= 0 && id.column < columns && id.row >= 0 && id.row < rows
  }

  // The tiles that touch a rectangle, row by row.
  public func ids(intersecting rect: Rect) -> [ID] {
    guard count > 0, rect.width >= 0, rect.height >= 0 else { return [] }
    let first = Int(floor(max(0, rect.x) / tileSize))
    let last = Int(floor(min(pageSize.x, rect.x + rect.width) / tileSize))
    let top = Int(floor(max(0, rect.y) / tileSize))
    let bottom = Int(floor(min(pageSize.y, rect.y + rect.height) / tileSize))
    guard rect.x <= pageSize.x, rect.y <= pageSize.y, rect.x + rect.width >= 0,
      rect.y + rect.height >= 0
    else { return [] }
    var result: [ID] = []
    for row in max(0, top)...min(rows - 1, bottom) {
      for column in max(0, first)...min(columns - 1, last) {
        result.append(ID(column: column, row: row))
      }
    }
    return result
  }

  // The tiles worth having around a visible rectangle: it and a margin of `margin` times its size
  // on each side, so a scroll finds the next tiles already drawn.
  public func ids(visible rect: Rect, margin: Double) -> [ID] {
    let dx = rect.width * margin
    let dy = rect.height * margin
    return ids(
      intersecting: Rect(
        x: rect.x - dx, y: rect.y - dy, width: rect.width + 2 * dx, height: rect.height + 2 * dy))
  }

  // Nearest to the middle of the view first, so what is on screen is drawn before what is near it.
  public func ordered(_ ids: [ID], around rect: Rect) -> [ID] {
    let cx = rect.x + rect.width / 2
    let cy = rect.y + rect.height / 2
    func distance(_ id: ID) -> Double {
      let r = self.rect(of: id)
      return hypot(r.x + r.width / 2 - cx, r.y + r.height / 2 - cy)
    }
    return ids.sorted { distance($0) < distance($1) }
  }
}
