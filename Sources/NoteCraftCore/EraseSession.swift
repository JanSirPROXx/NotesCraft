import Foundation

// One eraser gesture over one page. A page of handwriting has thousands of strokes with hundreds
// of samples each, and the eraser asks "what is near this point" for every pen event, so bounds
// are measured once and strokes are bucketed in a grid: an event only looks at the few strokes
// in the cells around the eraser instead of walking every sample on the page.
public struct EraseSession: Sendable {
  private struct Entry: Sendable {
    var stroke: Stroke
    var bounds: Rect
    // Position of the original stroke on the page; pieces cut from it keep it, so z-order survives.
    var order: Int
    var alive = true
  }

  private var entries: [Entry]
  private var cells: [Int64: [Int32]] = [:]
  // Strokes spanning too many cells to bucket (page-sized lines); always tested.
  private var oversized: [Int32] = []
  private var seen: [UInt32] = []
  private var stamp: UInt32 = 0
  private var widest = 0.0
  private var hasPieces = false
  private static let cellSize = 64.0
  private static let cellLimit = 256

  public init(strokes: [Stroke]) {
    entries = []
    entries.reserveCapacity(strokes.count)
    for (order, stroke) in strokes.enumerated() {
      add(Entry(stroke: stroke, bounds: stroke.bounds, order: order))
    }
  }

  private static func key(_ column: Int, _ row: Int) -> Int64 {
    let c = Int64(Int32(clamping: column))
    let r = Int64(Int32(clamping: row))
    return (c << 32) | (r & 0xFFFF_FFFF)
  }
  private static func cell(_ value: Double) -> Int {
    Int((value / cellSize).rounded(.down).clamped(to: -1e9...1e9))
  }

  private mutating func add(_ entry: Entry) {
    let index = Int32(entries.count)
    entries.append(entry)
    seen.append(0)
    widest = max(widest, entry.stroke.width)
    let b = entry.bounds
    let c0 = Self.cell(b.x)
    let c1 = Self.cell(b.x + b.width)
    let r0 = Self.cell(b.y)
    let r1 = Self.cell(b.y + b.height)
    if (c1 - c0 + 1) * (r1 - r0 + 1) > Self.cellLimit {
      oversized.append(index)
      return
    }
    for r in r0...r1 {
      for c in c0...c1 { cells[Self.key(c, r), default: []].append(index) }
    }
  }

  // Indices of live strokes whose cells overlap the box, each once.
  private mutating func candidates(in box: Rect) -> [Int] {
    stamp &+= 1
    var found: [Int] = []
    let c0 = Self.cell(box.x)
    let c1 = Self.cell(box.x + box.width)
    let r0 = Self.cell(box.y)
    let r1 = Self.cell(box.y + box.height)
    for r in r0...r1 {
      for c in c0...c1 {
        for index in cells[Self.key(c, r)] ?? [] where seen[Int(index)] != stamp {
          seen[Int(index)] = stamp
          if entries[Int(index)].alive { found.append(Int(index)) }
        }
      }
    }
    for index in oversized where seen[Int(index)] != stamp {
      seen[Int(index)] = stamp
      if entries[Int(index)].alive { found.append(Int(index)) }
    }
    return found
  }

  // Erases at one point and reports the page area whose pixels changed (nil when nothing was
  // hit), so a canvas can repaint just that area.
  public mutating func erase(
    at point: Point, radius: Double, mode: EraserMode, highlighterOnly: Bool
  ) -> Rect? {
    let reach = radius + widest / 2
    let box = Rect(x: point.x - reach, y: point.y - reach, width: 2 * reach, height: 2 * reach)
    var dirty: Rect?
    for index in candidates(in: box) {
      let entry = entries[index]
      let stroke = entry.stroke
      if highlighterOnly && stroke.tool != .highlighter { continue }
      // `bounds` already includes half the stroke width.
      let b = entry.bounds
      guard point.x >= b.x - radius, point.x <= b.x + b.width + radius,
        point.y >= b.y - radius, point.y <= b.y + b.height + radius,
        Editing.strokeIsNear(stroke, point, radius + stroke.width / 2)
      else { continue }
      let pad = stroke.width * 2 + 2
      let area = Rect(x: b.x - pad, y: b.y - pad, width: b.width + 2 * pad, height: b.height + 2 * pad)
      dirty = dirty.map { Self.union($0, area) } ?? area
      entries[index].alive = false
      for piece in Editing.erase(
        strokes: [stroke], at: point, radius: radius, mode: mode, highlighterOnly: highlighterOnly)
      {
        hasPieces = true
        add(Entry(stroke: piece, bounds: piece.bounds, order: entry.order))
      }
    }
    return dirty
  }

  // The strokes that remain, in page order.
  public var strokes: [Stroke] {
    ordered(entries.indices.filter { entries[$0].alive })
  }

  // The remaining strokes that can reach into `area`, in page order: what a repaint of that
  // area needs, without touching the rest of the page.
  public mutating func strokes(reaching area: Rect) -> [Stroke] {
    let pad = widest * 2 + 2
    let box = Rect(x: area.x - pad, y: area.y - pad, width: area.width + 2 * pad, height: area.height + 2 * pad)
    return ordered(candidates(in: box).filter { entries[$0].bounds.intersects(box) })
  }

  private func ordered(_ indices: [Int]) -> [Stroke] {
    // Entries are appended in page order until a stroke is cut into pieces.
    let sorted = hasPieces ? indices.sorted { (entries[$0].order, $0) < (entries[$1].order, $1) } : indices
    return sorted.map { entries[$0].stroke }
  }

  private static func union(_ a: Rect, _ b: Rect) -> Rect {
    let minX = min(a.x, b.x)
    let minY = min(a.y, b.y)
    return Rect(
      x: minX, y: minY, width: max(a.x + a.width, b.x + b.width) - minX,
      height: max(a.y + a.height, b.y + b.height) - minY)
  }
}

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
    min(range.upperBound, max(range.lowerBound, self))
  }
}
