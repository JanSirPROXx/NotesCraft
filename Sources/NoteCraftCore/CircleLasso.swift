import Foundation

// Circle to Lasso. The pen draws a loop around ink as it always does, and nothing is decided while
// it is drawn: a circle around a word stays a circle. Holding the pen still on that loop afterwards
// turns it into a selection of what it encloses (and touches, like the lasso), and the loop leaves
// the page so it is not part of what is moved.
extension InkGestures {
  public struct LoopSelection: Equatable, Sendable {
    public var loop: UUID
    public var selection: Set<UUID>
  }

  // A loop is closed (or overshoots its own start), turns about once around, and is big enough to
  // enclose something. A handwritten "o", a figure eight, a spiral or an open "C" are not loops.
  static func loopPolygon(_ stroke: Stroke) -> [Point]? {
    guard stroke.tool == .pen, stroke.shape == nil, stroke.fillColor == nil,
      stroke.samples.count >= 12
    else { return nil }
    let points = stroke.samples.map(\.point)
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    let diagonal = hypot(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
    guard diagonal >= 24 else { return nil }
    // Even spacing, so a cluster of samples where the pen slowed down does not dominate the turning.
    let step = max(1.5, diagonal / 48)
    var path = [points[0]]
    for point in points.dropFirst() where point.distance(to: path.last!) >= step {
      path.append(point)
    }
    guard path.count >= 10 else { return nil }
    var length = 0.0
    var turning = 0.0
    for i in 1..<path.count {
      length += path[i - 1].distance(to: path[i])
      guard i > 1 else { continue }
      let before = atan2(path[i - 1].y - path[i - 2].y, path[i - 1].x - path[i - 2].x)
      let after = atan2(path[i].y - path[i - 1].y, path[i].x - path[i - 1].x)
      var change = after - before
      while change > .pi { change -= 2 * .pi }
      while change < -.pi { change += 2 * .pi }
      turning += change
    }
    // A rectangle that closes on its first corner has turned only three corners by the time the
    // pen is back there, which is why the lower bound sits well under a full turn.
    guard abs(turning) >= 1.4 * .pi, abs(turning) <= 2.9 * .pi, length / diagonal >= 2 else {
      return nil
    }
    var closed = path[0].distance(to: path[path.count - 1]) <= max(8, diagonal * 0.3)
    if !closed {
      // The pen went past where it started: the last piece crosses the first quarter.
      let a = path[path.count - 2]
      let b = path[path.count - 1]
      closed = zip(path.prefix(path.count / 4), path.dropFirst().prefix(path.count / 4)).contains {
        Editing.segmentsIntersect($0.0, $0.1, a, b)
      }
    }
    return closed ? points : nil
  }

  private static func distance(_ point: Point, toPolyline points: [Point]) -> Double {
    guard var previous = points.first else { return .infinity }
    var best = previous.distance(to: point)
    for next in points.dropFirst() {
      best = min(best, Editing.distance(point, toSegmentFrom: previous, to: next))
      previous = next
    }
    return best
  }

  // What the lasso tool would select with `polygon`: ink, images and text boxes it touches.
  public static func lassoSelection(
    page: Page, polygon: [Point], bounds: Rect, ink: Bool = true, images: Bool = true,
    texts: Bool = true, excluding: Set<UUID> = []
  ) -> Set<UUID> {
    var selected: Set<UUID> = []
    if ink {
      selected = Editing.selection(
        strokes: page.strokes.filter { !excluding.contains($0.id) }, polygon: polygon,
        bounds: bounds)
    }
    if images {
      selected.formUnion(
        page.images.filter { rectTouches($0.bounds, polygon: polygon) }.map(\.id))
    }
    if texts {
      selected.formUnion(page.texts.filter { rectTouches($0.bounds, polygon: polygon) }.map(\.id))
    }
    return selected
  }

  private static func rectTouches(_ rect: Rect, polygon: [Point]) -> Bool {
    let outline = [
      Point(rect.x, rect.y), Point(rect.x + rect.width, rect.y),
      Point(rect.x + rect.width, rect.y + rect.height), Point(rect.x, rect.y + rect.height),
      Point(rect.x, rect.y),
    ]
    return Editing.strokeIntersects(
      Stroke(samples: outline.map { Sample(point: $0) }), polygon: polygon)
      || polygon.contains { rect.contains($0) }
  }

  // The loop under a long press, if it encloses anything. The topmost loop wins; one that encloses
  // nothing is skipped, so a loop drawn over another can still be reached.
  public static func loopSelection(
    at point: Point, page: Page, tolerance: Double, bounds: Rect, ink: Bool = true,
    images: Bool = true, texts: Bool = true
  ) -> LoopSelection? {
    for stroke in page.strokes.reversed() {
      let box = stroke.bounds
      let reach = tolerance + stroke.width / 2
      guard point.x >= box.x - reach, point.x <= box.x + box.width + reach,
        point.y >= box.y - reach, point.y <= box.y + box.height + reach,
        let polygon = loopPolygon(stroke),
        distance(point, toPolyline: polygon) <= reach
      else { continue }
      let selected = lassoSelection(
        page: page, polygon: polygon, bounds: bounds, ink: ink, images: images, texts: texts,
        excluding: [stroke.id])
      if !selected.isEmpty { return LoopSelection(loop: stroke.id, selection: selected) }
    }
    return nil
  }
}
