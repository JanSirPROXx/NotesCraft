import Foundation

// Tells which symbol a few strokes write by laying them over what is known: every template is a
// symbol written once, cut down to the same number of points, and the nearest one wins. Nothing
// is trained: a new way of writing a "7" is one more template, so the first sample of the reader's
// own hand already changes the answer, and the stock shapes carry the start.
//
// Strokes are compared as a cloud of points, not as a path, so the order and direction in which
// the pen moved do not matter (a "+" is read the same whichever bar came first); the size does
// not matter either, only the shape and its proportions.

public struct SymbolTemplate: Sendable {
  public var symbol: String
  // See `SymbolShape.normalized`.
  var points: [Point]
}

public struct SymbolGuess: Sendable, Equatable {
  public var symbol: String
  // How far the strokes are from the best template, and from the best template of any other symbol.
  public var distance: Double
  public var runnerUp: Double

  // How much nearer the answer is than the alternative, 0 to 1. A shape that fits two symbols
  // alike has none, however close it is to both.
  public var margin: Double { runnerUp > 0 ? max(0, (runnerUp - distance) / runnerUp) : 0 }
}

public enum SymbolShape {
  static let pointCount = 24

  // The strokes as `pointCount` points, shifted to their centre and scaled so that the longer side
  // of their box is 1. Nil when there is nothing to compare: no points, or all in one spot.
  static func normalized(_ strokes: [[Point]]) -> [Point]? {
    let all = strokes.flatMap { $0 }
    guard let first = all.first else { return nil }
    var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
    for point in all {
      minX = min(minX, point.x)
      maxX = max(maxX, point.x)
      minY = min(minY, point.y)
      maxY = max(maxY, point.y)
    }
    let size = max(maxX - minX, maxY - minY)
    guard size > 1e-9 else { return nil }

    let lengths = strokes.map { stroke -> Double in
      guard stroke.count > 1 else { return 0 }
      return zip(stroke.dropFirst(), stroke).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }
    let total = lengths.reduce(0, +)
    let usable = strokes.indices.filter { !strokes[$0].isEmpty }
    guard !usable.isEmpty else { return nil }
    // Points go to the strokes in proportion to their length, at least one each; a dot of a "÷"
    // is a stroke of no length that still counts.
    var counts = usable.map { index -> Int in
      let share = total > 0 ? lengths[index] / total : 1 / Double(usable.count)
      return max(1, Int((share * Double(pointCount)).rounded()))
    }
    var excess = counts.reduce(0, +) - pointCount
    while excess != 0 {
      let step = excess > 0 ? -1 : 1
      guard let at = counts.indices.max(by: { counts[$0] < counts[$1] }),
        counts[at] + step >= 1
      else { break }
      counts[at] += step
      excess += step
    }
    var cloud: [Point] = []
    for (slot, index) in usable.enumerated() {
      cloud += resampled(strokes[index], count: counts[slot])
    }
    let cx = cloud.map(\.x).reduce(0, +) / Double(cloud.count)
    let cy = cloud.map(\.y).reduce(0, +) / Double(cloud.count)
    return cloud.map { Point(($0.x - cx) / size, ($0.y - cy) / size) }
  }

  static func resampled(_ stroke: [Point], count: Int) -> [Point] {
    guard stroke.count > 1, count > 1 else { return Array(repeating: stroke[0], count: max(1, count)) }
    var cumulative = [0.0]
    for i in 1..<stroke.count { cumulative.append(cumulative[i - 1] + stroke[i].distance(to: stroke[i - 1])) }
    let length = cumulative.last!
    guard length > 0 else { return Array(repeating: stroke[0], count: count) }
    var out: [Point] = []
    var segment = 1
    for k in 0..<count {
      let target = length * Double(k) / Double(count - 1)
      while segment < cumulative.count - 1, cumulative[segment] < target { segment += 1 }
      let span = cumulative[segment] - cumulative[segment - 1]
      let t = span > 0 ? (target - cumulative[segment - 1]) / span : 0
      let a = stroke[segment - 1], b = stroke[segment]
      out.append(Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
    }
    return out
  }

  // The mean distance from each point to the nearest of the other cloud, both ways round. With a
  // `limit` it gives up (returns infinity) as soon as the result cannot come in under it, which
  // is most templates by the time half the points have been compared.
  static func distance(_ a: [Point], _ b: [Point], limit: Double = .infinity) -> Double {
    func oneWay(_ from: [Point], _ to: [Point], budget: Double) -> Double {
      var sum = 0.0
      let allowed = budget * Double(from.count)
      for p in from {
        var best = Double.infinity
        for q in to {
          let dx = p.x - q.x, dy = p.y - q.y
          let d = dx * dx + dy * dy
          if d < best { best = d }
        }
        sum += best.squareRoot()
        if sum > allowed { return .infinity }
      }
      return sum / Double(from.count)
    }
    // Both ways are averaged, so each may take up to twice the limit.
    let first = oneWay(a, b, budget: limit * 2)
    guard first.isFinite else { return .infinity }
    let second = oneWay(b, a, budget: limit * 2 - first)
    guard second.isFinite else { return .infinity }
    return (first + second) / 2
  }
}

public final class SymbolClassifier: Sendable {
  private let templates: [SymbolTemplate]

  public init(templates: [SymbolTemplate]) { self.templates = templates }

  public var symbols: Set<String> { Set(templates.map(\.symbol)) }

  // Every symbol with the distance of its nearest template, nearest first. Empty with no templates
  // or nothing drawn.
  public func ranked(_ strokes: [[Point]]) -> [(symbol: String, distance: Double)] {
    guard let shape = SymbolShape.normalized(strokes) else { return [] }
    var best: [String: Double] = [:]
    // Only the nearest three symbols are ever looked at, so a template that cannot beat the third
    // best so far is not measured to the end.
    var cutoff = Double.infinity
    for template in templates {
      let own = best[template.symbol, default: .infinity]
      let d = SymbolShape.distance(shape, template.points, limit: min(own, cutoff))
      if d < own {
        best[template.symbol] = d
        if best.count >= 3 { cutoff = best.values.sorted()[2] }
      }
    }
    return best.sorted { $0.value < $1.value }.map { ($0.key, $0.value) }
  }

  public func classify(_ strokes: [[Point]]) -> SymbolGuess? {
    let ranking = ranked(strokes)
    guard let first = ranking.first else { return nil }
    return SymbolGuess(
      symbol: first.symbol, distance: first.distance,
      runnerUp: ranking.count > 1 ? ranking[1].distance : first.distance * 4)
  }
}

public enum StockTemplates {
  // Each stock glyph, bent out of shape a few times, so a template stands for how a symbol is
  // written and not for one drawing of it. Always the same set.
  public static func make(variants: Int = 16) -> [SymbolTemplate] {
    var rng = SeededGenerator(seed: 0x4E6F_7465_4372_6166)
    var out: [SymbolTemplate] = []
    for glyph in StockGlyphs.all {
      if let plain = SymbolShape.normalized(glyph.strokes) {
        out.append(SymbolTemplate(symbol: glyph.symbol, points: plain))
      }
      for _ in 0..<variants {
        let bent = StockGlyphs.perturbed(glyph.strokes, strength: 1, using: &rng)
        if let shape = SymbolShape.normalized(bent) {
          out.append(SymbolTemplate(symbol: glyph.symbol, points: shape))
        }
      }
    }
    return out
  }

  public static func template(symbol: String, strokes: [[Point]]) -> SymbolTemplate? {
    SymbolShape.normalized(strokes).map { SymbolTemplate(symbol: symbol, points: $0) }
  }
}
