import Foundation

// Which strokes on a page make up the calculation that a freshly written "=" asks to solve.
//
// Only calculator ink is ever considered, never the colour: the pen's stroke marker decides. Ink that
// already belongs to a solved calculation, and the boxes holding earlier answers, end the search, so a
// second calculation next to a first one is read on its own.

public struct EqualsMark: Equatable, Sendable {
  public var strokeIDs: [UUID]
  public var bounds: Rect
}

public struct Gathering: Equatable, Sendable {
  // Left to right, the two lines of the "=" included.
  public var strokes: [Stroke]
  // The same strokes without the "=", in the order they were written: the order is what tells which
  // strokes make one symbol.
  public var writing: [Stroke]
  public var mark: EqualsMark
  public var bounds: Rect
  // Height of a typical digit, and the line the writing stands on.
  public var glyphHeight: Double
  public var baseline: Double

  public var strokeIDs: [UUID] { strokes.map(\.id) }
  // Where the answer starts: after the "=", with a little air, on the writing's own baseline.
  public var answerOrigin: Point { Point(mark.bounds.x + mark.bounds.width + glyphHeight * 0.45, baseline) }
  // A digit is about 0.7 em tall.
  public var answerFontSize: Double { min(120, max(10, glyphHeight / 0.7)) }
}

public enum CalculatorTrigger {
  // The calculation `latest` closes, if it closes one. `page` already holds `latest`.
  public static func gathering(for latest: Stroke, on page: Page) -> Gathering? {
    guard latest.calculator else { return nil }
    let ink = page.strokes.filter(\.calculator)
    guard ink.last?.id == latest.id, ink.count >= 3 else { return nil }
    let solved = Set(page.texts.compactMap(\.calculation).flatMap(\.strokeIDs))
    guard !solved.contains(latest.id) else { return nil }
    let open = ink.filter { !solved.contains($0.id) }
    guard let mark = equalsMark(endingWith: latest, in: open) else { return nil }
    let barriers = page.texts.filter { $0.calculation != nil }.map(\.bounds)
    return gather(
      mark: mark, open: open, solved: ink.filter { solved.contains($0.id) }, barriers: barriers)
  }

  // "=" is two flat strokes one above the other, the second just written right after the first.
  static func equalsMark(endingWith latest: Stroke, in open: [Stroke]) -> EqualsMark? {
    guard open.count >= 2, open.last?.id == latest.id else { return nil }
    let first = open[open.count - 2]
    guard let a = Line(first), let b = Line(latest) else { return nil }
    let shorter = min(a.width, b.width)
    let longer = max(a.width, b.width)
    guard shorter / longer >= 0.45 else { return nil }
    let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
    guard overlap >= 0.55 * shorter else { return nil }
    let apart = abs(a.centerY - b.centerY)
    guard apart >= max(1, 0.12 * longer), apart <= 0.9 * longer else { return nil }
    let box = Rect(
      x: min(a.minX, b.minX), y: min(a.minY, b.minY), width: max(a.maxX, b.maxX) - min(a.minX, b.minX),
      height: max(a.maxY, b.maxY) - min(a.minY, b.minY))
    return EqualsMark(strokeIDs: [first.id, latest.id], bounds: box)
  }

  // A stroke that is a flat, nearly straight line: one bar of an "=" (or a minus).
  private struct Line {
    var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
    var width: Double { maxX - minX }
    var centerY: Double { (minY + maxY) / 2 }
    init?(_ stroke: Stroke) {
      guard stroke.samples.count >= 2 else { return nil }
      let points = stroke.samples.map(\.point)
      minX = points.map(\.x).min()!
      maxX = points.map(\.x).max()!
      minY = points.map(\.y).min()!
      maxY = points.map(\.y).max()!
      let height = maxY - minY
      guard width >= 3, height <= 0.35 * width else { return nil }
      // A bar leans a little, a stroke that climbs is something else.
      let first = points.first!, last = points.last!
      guard abs(last.y - first.y) <= 0.45 * abs(last.x - first.x) + 1 else { return nil }
      var path = 0.0
      for i in 1..<points.count { path += points[i].distance(to: points[i - 1]) }
      guard first.distance(to: last) >= 0.8 * path else { return nil }
    }
  }

  static func gather(
    mark: EqualsMark, open: [Stroke], solved: [Stroke], barriers: [Rect]
  ) -> Gathering? {
    let markIDs = Set(mark.strokeIDs)
    let others = open.filter { !markIDs.contains($0.id) }
    let w = mark.bounds.width
    let cy = mark.bounds.y + mark.bounds.height / 2
    guard w > 0 else { return nil }

    // A "=" is roughly half a digit wide, which is all there is to go by before anything is
    // read: a first pass with that guess finds the neighbours, whose height then sets the real
    // line band and the gap that still counts as the same calculation.
    var found = walk(
      from: mark, others: others, solved: solved, barriers: barriers, half: 2.5 * w, gap: 3 * w, cy: cy)
    guard !found.isEmpty else { return nil }
    let heights = found.map { $0.bounds.height }.sorted()
    var glyph = max(heights[min(heights.count - 1, Int(Double(heights.count) * 0.75))], w)
    found = walk(
      from: mark, others: others, solved: solved, barriers: barriers, half: 0.9 * glyph,
      gap: 1.5 * glyph, cy: cy)
    guard !found.isEmpty else { return nil }

    // A fraction reaches above and below the line the "=" stands on: the writing over and under
    // a bar belongs to the calculation although it is outside the band.
    let (members, onAxis) = attachingFractions(to: found, others: others, glyph: glyph)
    found = members
    if onAxis {
      // The bar and the signs are flat; the height of a digit is what sets the answer's size.
      let digits = found.filter { Line($0) == nil }.map { $0.bounds.height }.sorted()
      if !digits.isEmpty { glyph = digits[min(digits.count - 1, Int(Double(digits.count) * 0.75))] }
    }

    // Anything written to the right of the "=" makes this an equation, not a request to solve.
    let rightEdge = mark.bounds.x + mark.bounds.width
    let trailing = others.contains { s in
      let b = s.bounds
      return abs(b.y + b.height / 2 - cy) <= 0.9 * glyph && b.x >= rightEdge - 0.25 * w
        && b.x - rightEdge <= 1.5 * glyph
    }
    guard !trailing else { return nil }

    let strokes = (found + open.filter { markIDs.contains($0.id) }).sorted { $0.bounds.x < $1.bounds.x }
    var box = strokes[0].bounds
    for s in strokes.dropFirst() {
      let b = s.bounds
      let x0 = min(box.x, b.x), y0 = min(box.y, b.y)
      box = Rect(
        x: x0, y: y0, width: max(box.x + box.width, b.x + b.width) - x0,
        height: max(box.y + box.height, b.y + b.height) - y0)
    }
    // On a line of plain writing the answer stands on the digits' baseline. Beside a fraction that
    // would be the foot of the numerator, so it is centred on the "=" instead, as a digit would be.
    let tall = found.filter { $0.bounds.height >= 0.6 * glyph }.map { $0.bounds.y + $0.bounds.height }.sorted()
    let baseline = onAxis || tall.isEmpty ? cy + glyph / 2 : tall[tall.count / 2]
    let written = Set(found.map(\.id))
    return Gathering(
      strokes: strokes, writing: open.filter { written.contains($0.id) }, mark: mark, bounds: box,
      glyphHeight: glyph, baseline: baseline)
  }

  // A flat stroke with writing both over and under it, inside its width, is a fraction bar. What sits
  // over and under it, up to two digit heights away, is added; writing that was added may hold a
  // bar of its own (a fraction in a fraction), so this goes round a few times. A minus has nothing
  // over or under it, so it never counts as a bar.
  private static func attachingFractions(
    to found: [Stroke], others: [Stroke], glyph: Double
  ) -> (strokes: [Stroke], onAxis: Bool) {
    var members = found
    var inside = Set(found.map(\.id))
    var onAxis = false
    var bars = found.filter { Line($0) != nil }
    var rounds = 0
    while !bars.isEmpty, rounds < 3 {
      rounds += 1
      var added: [Stroke] = []
      for bar in bars {
        let b = bar.bounds
        let centre = b.y + b.height / 2
        let slack = 0.3 * glyph
        var over: [Stroke] = []
        var under: [Stroke] = []
        // Judged on everything near, what the band already took included: a bar needs writing
        // on both sides, wherever that was found.
        for s in others {
          let r = s.bounds
          let overlap = min(r.x + r.width, b.x + b.width + slack) - max(r.x, b.x - slack)
          guard overlap >= 0.5 * max(r.width, 1) else { continue }
          let offset = r.y + r.height / 2 - centre
          if offset < -0.15 * glyph, -offset <= 2 * glyph, r.y + r.height <= centre + 0.2 * glyph {
            over.append(s)
          } else if offset > 0.15 * glyph, offset <= 2 * glyph, r.y >= centre - 0.2 * glyph {
            under.append(s)
          }
        }
        guard !over.isEmpty, !under.isEmpty else { continue }
        onAxis = true
        for s in over + under where inside.insert(s.id).inserted { added.append(s) }
      }
      members += added
      bars = added.filter { Line($0) != nil }
    }
    return (members, onAxis)
  }

  // Walks left from the "=" and takes every stroke in the band while the gap to what is taken
  // so far stays small. A solved stroke or an answer box in the band ends the walk.
  private static func walk(
    from mark: EqualsMark, others: [Stroke], solved: [Stroke], barriers: [Rect], half: Double,
    gap: Double, cy: Double
  ) -> [Stroke] {
    struct Item {
      var maxX: Double
      var minX: Double
      var stroke: Stroke?
    }
    var items: [Item] = []
    for s in others where abs(s.bounds.y + s.bounds.height / 2 - cy) <= half {
      let b = s.bounds
      items.append(Item(maxX: b.x + b.width, minX: b.x, stroke: s))
    }
    for s in solved where abs(s.bounds.y + s.bounds.height / 2 - cy) <= half {
      let b = s.bounds
      items.append(Item(maxX: b.x + b.width, minX: b.x, stroke: nil))
    }
    for b in barriers where b.y <= cy + half && b.y + b.height >= cy - half {
      items.append(Item(maxX: b.x + b.width, minX: b.x, stroke: nil))
    }
    // Only what lies left of the right edge of the "=" can belong in front of it.
    let limit = mark.bounds.x + mark.bounds.width
    items = items.filter { $0.minX < limit }.sorted { $0.maxX > $1.maxX }
    var edge = mark.bounds.x
    var taken: [Stroke] = []
    for item in items {
      guard item.maxX >= edge - gap else { break }
      guard let stroke = item.stroke else { break }
      taken.append(stroke)
      edge = min(edge, item.minX)
    }
    return taken
  }
}
