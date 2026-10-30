import Foundation

// Reads the strokes of a calculation as an expression: which strokes are one symbol, which symbol
// each is, how they sit (a line of symbols, with fractions standing over and under a bar), and
// whether what comes out is a calculation at all.
//
// Two things keep a wrong number off the page. A symbol that fits two shapes alike (a slanted
// "1" and a "/") keeps both, and the grammar decides: if only one of the readings is a calculation
// it is that one, if both are it is nobody's call and the reading is not trusted. And the
// reading's confidence is that of its least certain symbol.

public struct LineReader: Sendable {
  let classifier: SymbolClassifier

  public init(classifier: SymbolClassifier) { self.classifier = classifier }

  // A group of strokes further than this from every template is no symbol of the alphabet.
  static let farthest = 0.09
  // A symbol whose nearest shape is this much nearer than the next one is certain.
  static let certainMargin = 0.35
  // What each symbol costs on top of its distance, so one clean symbol beats two bad halves.
  static let groupCost = 0.03
  static let mostAmbiguous = 7
  // A symbol this near its template is a good fit; the usual one is at 0.03.
  static let goodFit = 0.055

  struct Piece {
    var char: String
    var distance: Double
  }
  struct Symbol {
    var options: [Piece]  // nearest first; more than one only where the shape is not clear
    var margin: Double
    var box: Rect
    var chosen = 0
    var char: String { options[chosen].char }
    var confidence: Double { min(1, margin / LineReader.certainMargin) }
    var x: Double { box.x }
    var centreX: Double { box.x + box.width / 2 }
    var centreY: Double { box.y + box.height / 2 }
  }

  public func read(_ gathering: Gathering) -> Reading? {
    let strokes = gathering.writing.filter { $0.samples.count >= 1 }
    guard !strokes.isEmpty, strokes.count <= 80 else { return nil }
    let h = digitHeight(strokes, estimate: gathering.glyphHeight)
    let segmenter = Segmenter(reader: self, clouds: strokes.map(points), height: h)
    guard let best = segmenter.best(), var reading = resolve(best.symbols, height: h) else { return nil }

    // The cut of the strokes into symbols is a reading too. If a nearly as good cut gives another
    // calculation (a "1" and a "4" that are also one "4"), nobody can say which was written.
    for alternative in segmenter.alternatives(to: best) {
      // Only a cut that fits every one of its symbols well, and costs little more, is a rival.
      guard alternative.cost <= best.cost + 0.06,
        alternative.symbols.allSatisfy({ $0.options[0].distance <= Self.goodFit }),
        let other = resolve(alternative.symbols, height: h), other.expression != reading.expression
      else { continue }
      reading.confidence = min(reading.confidence, 0.5)
      break
    }
    return reading
  }

  // How tall a digit is. The gathering's estimate is a middle value, which a digit written in two
  // pieces (an "8" of two rings) pulls down to half; the tall end of the strokes is the digit.
  private func digitHeight(_ strokes: [Stroke], estimate: Double) -> Double {
    let heights = strokes.map { box(of: [points($0)]).height }.sorted()
    let tall = heights[min(heights.count - 1, Int(Double(heights.count) * 0.9))]
    return max(estimate, tall)
  }

  // MARK: segmentation

  private func points(_ stroke: Stroke) -> [Point] { stroke.samples.map(\.point) }

  private func box(of groups: [[Point]]) -> Rect {
    var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
    for point in groups.joined() {
      minX = min(minX, point.x); maxX = max(maxX, point.x)
      minY = min(minY, point.y); maxY = max(maxY, point.y)
    }
    return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  struct Cut {
    var symbols: [Symbol]
    var cost: Double
    // Where each symbol's strokes begin and end, as a stroke index.
    var spans: [(start: Int, end: Int)]
  }

  // The best way to cut the strokes, in the order they were written, into groups of up to four
  // that are each a symbol (consecutive strokes only: a symbol is written in one go), and the
  // next best ways. Each group is read once.
  final class Segmenter {
    let reader: LineReader
    let clouds: [[Point]]
    let height: Double
    private var cache: [Int: Symbol?] = [:]

    init(reader: LineReader, clouds: [[Point]], height: Double) {
      self.reader = reader
      self.clouds = clouds
      self.height = height
    }

    private func symbol(_ start: Int, _ end: Int) -> Symbol? {
      let key = start * 1000 + end
      if let known = cache[key] { return known }
      let read = reader.read(Array(clouds[start..<end]), height: height)
      cache[key] = .some(read)
      return read
    }

    func best() -> Cut? { cut(forbidding: nil, boundary: nil) }

    // The best cut with one of the best cut's groups not allowed, or with one of its joins
    // not allowed to be a boundary.
    func alternatives(to best: Cut) -> [Cut] {
      var out: [Cut] = []
      for span in best.spans where span.end - span.start > 1 {
        if let other = cut(forbidding: span.start * 1000 + span.end, boundary: nil) { out.append(other) }
      }
      for span in best.spans.dropLast() {
        if let other = cut(forbidding: nil, boundary: span.end) { out.append(other) }
      }
      return out
    }

    private func cut(forbidding group: Int?, boundary: Int?) -> Cut? {
      let n = clouds.count
      var cost = [Double](repeating: .infinity, count: n + 1)
      var from = [Int](repeating: 0, count: n + 1)
      var chosen = [Symbol?](repeating: nil, count: n + 1)
      cost[0] = 0
      for end in 1...n {
        if end == boundary { continue }
        for length in 1...min(4, end) {
          let start = end - length
          guard cost[start] < .infinity, start * 1000 + end != group,
            let symbol = symbol(start, end)
          else { continue }
          let total = cost[start] + symbol.options[0].distance + LineReader.groupCost
          if total < cost[end] {
            cost[end] = total
            from[end] = start
            chosen[end] = symbol
          }
        }
      }
      guard cost[n] < .infinity else { return nil }
      var symbols: [Symbol] = []
      var spans: [(Int, Int)] = []
      var at = n
      while at > 0 {
        symbols.append(chosen[at]!)
        spans.append((from[at], at))
        at = from[at]
      }
      return Cut(symbols: symbols.reversed(), cost: cost[n], spans: spans.reversed().map { (start: $0.0, end: $0.1) })
    }
  }

  private func read(_ group: [[Point]], height h: Double) -> Symbol? {
    let b = box(of: group)
    if group.count == 1, max(b.width, b.height) < 0.16 * h {
      return Symbol(options: [Piece(char: ".", distance: 0)], margin: 1, box: b)
    }
    if group.count > 1 {
      // Strokes of one symbol touch or nearly: each is within a quarter of a digit of the others.
      // The widest symbol of several strokes is about 0.6 of a digit's height; two symbols side by
      // side are wider than that.
      guard b.width <= 0.85 * h, b.height <= 1.3 * h else { return nil }
      var joined = box(of: [group[0]])
      for stroke in group.dropFirst() {
        let r = box(of: [stroke])
        let gapX = max(0, max(joined.x, r.x) - min(joined.x + joined.width, r.x + r.width))
        let gapY = max(0, max(joined.y, r.y) - min(joined.y + joined.height, r.y + r.height))
        guard max(gapX, gapY) <= 0.25 * h else { return nil }
        let x0 = min(joined.x, r.x), y0 = min(joined.y, r.y)
        joined = Rect(
          x: x0, y: y0, width: max(joined.x + joined.width, r.x + r.width) - x0,
          height: max(joined.y + joined.height, r.y + r.height) - y0)
      }
    }
    let ranking = classifier.ranked(group)
    guard let first = ranking.first, first.distance <= Self.farthest else { return nil }
    var options: [Piece] = []
    for (symbol, distance) in ranking.prefix(3) {
      let char = symbol == "÷" ? "/" : symbol
      // ÷ and / read alike; keep the better of the two once.
      if options.contains(where: { $0.char == char }) { continue }
      options.append(Piece(char: char, distance: distance))
    }
    let second = ranking.count > 1 ? ranking[1].distance : first.distance * 4
    let margin = second > 0 ? max(0, (second - first.distance) / second) : 0
    // A shape that is not clear keeps its runner-up, and a third that is as near.
    var kept = [options[0]]
    if margin < Self.certainMargin {
      for option in options.dropFirst() where option.distance <= second * 1.0001 + 0.005 { kept.append(option) }
    }
    return Symbol(options: kept, margin: kept.count > 1 || margin >= Self.certainMargin ? margin : 1, box: b)
  }

  // MARK: reading the expression

  private func resolve(_ input: [Symbol], height h: Double) -> Reading? {
    var symbols = input
    let ambiguous = symbols.indices.filter { symbols[$0].options.count > 1 }
    guard ambiguous.count <= Self.mostAmbiguous else { return nil }

    // Every way of choosing among the unclear symbols, as the expression it would be.
    var readings: [(expression: String, cost: Double, picks: [Int])] = []
    var picks = [Int](repeating: 0, count: ambiguous.count)
    func walk(_ k: Int) {
      if readings.count > 600 { return }
      if k == ambiguous.count {
        var copy = symbols
        for (slot, i) in ambiguous.enumerated() { copy[i].chosen = picks[slot] }
        guard let text = layout(copy, height: h), Self.isCalculation(text) else { return }
        let cost = copy.reduce(0) { $0 + $1.options[$1.chosen].distance }
        readings.append((text, cost, picks))
        return
      }
      for option in symbols[ambiguous[k]].options.indices {
        picks[k] = option
        walk(k + 1)
      }
    }
    if ambiguous.isEmpty {
      guard let text = layout(symbols, height: h), Self.isCalculation(text) else { return nil }
      return Reading(expression: text, confidence: symbols.map(\.confidence).min() ?? 1)
    }
    walk(0)
    guard let winner = readings.min(by: { $0.cost < $1.cost }) else { return nil }

    var confidence = 1.0
    for (slot, i) in ambiguous.enumerated() {
      // The unclear symbol is settled when no reading that is a calculation chose otherwise.
      let settled = readings.allSatisfy { $0.picks[slot] == winner.picks[slot] }
      confidence = min(confidence, settled ? max(symbols[i].confidence, 0.95) : symbols[i].confidence)
    }
    for (i, symbol) in symbols.enumerated() where !ambiguous.contains(i) {
      confidence = min(confidence, symbol.confidence)
    }
    return Reading(expression: winner.expression, confidence: confidence)
  }

  // A reading is only a candidate if it is a calculation, whatever it comes to.
  static func isCalculation(_ text: String) -> Bool {
    switch Expression.evaluate(text) {
    case .success: return true
    case .failure(.divisionByZero), .failure(.undefined), .failure(.overflow): return true
    case .failure: return false
    }
  }

  // MARK: layout

  // The symbols as an expression: a line from left to right, with a fraction wherever a bar has
  // writing over it and under it.
  func layout(_ symbols: [Symbol], height h: Double) -> String? {
    guard !symbols.isEmpty else { return nil }
    func inRegion(_ s: Symbol, of bar: Symbol) -> Bool {
      let slack = 0.3 * h
      guard s.centreX >= bar.box.x - slack, s.centreX <= bar.box.x + bar.box.width + slack else { return false }
      let off = abs(s.centreY - bar.centreY)
      return off >= 0.15 * h && off <= 2.2 * h
    }
    let ids = Array(symbols.indices)
    func isBar(_ i: Int) -> Bool {
      guard symbols[i].char == "-" else { return false }
      let others = ids.filter { $0 != i && inRegion(symbols[$0], of: symbols[i]) }
      return others.contains { symbols[$0].centreY < symbols[i].centreY }
        && others.contains { symbols[$0].centreY > symbols[i].centreY }
    }
    let bars = ids.filter(isBar)
    // The bars that are not themselves over or under another: the outer fractions.
    let outer = bars.filter { b in
      !bars.contains { o in o != b && symbols[o].box.width > symbols[b].box.width
        && inRegion(symbols[b], of: symbols[o]) }
    }
    var consumed = Set<Int>()
    var items: [(x: Double, text: String, symbol: Int?)] = []
    for bar in outer {
      let inside = ids.filter { $0 != bar && !consumed.contains($0) && inRegion(symbols[$0], of: symbols[bar]) }
      let over = inside.filter { symbols[$0].centreY < symbols[bar].centreY }
      let under = inside.filter { symbols[$0].centreY > symbols[bar].centreY }
      guard let top = layout(over.map { symbols[$0] }, height: h),
        let bottom = layout(under.map { symbols[$0] }, height: h)
      else { return nil }
      consumed.formUnion(inside)
      consumed.insert(bar)
      items.append((symbols[bar].x, "((\(top))/(\(bottom)))", nil))
    }
    for i in ids where !consumed.contains(i) { items.append((symbols[i].x, symbols[i].char, i)) }
    items.sort { $0.x < $1.x }

    // Symbols in a line stand one after the other, so the centre of one is never inside the span of
    // the next. When it is, they are one above the other or one across the other (a "8" read as
    // two "0", a "+" read as "-" and "1"), which is no line, so it is not read as one.
    let line = items.compactMap(\.symbol).sorted { symbols[$0].centreX < symbols[$1].centreX }
    for (a, b) in zip(line, line.dropFirst()) {
      let wider = max(symbols[a].box.width, symbols[b].box.width)
      if abs(symbols[a].centreX - symbols[b].centreX) < 0.5 * wider { return nil }
    }

    // Digits written close are one number; a wide gap makes them two, which is no calculation
    // and so is not read as one.
    var text = ""
    var previous: Int?
    for item in items {
      if let p = previous, let i = item.symbol, Self.isNumeral(symbols[p].char), Self.isNumeral(symbols[i].char) {
        let gap = symbols[i].box.x - (symbols[p].box.x + symbols[p].box.width)
        if gap > 0.65 * h { text += " " }
      }
      text += item.text
      previous = item.symbol
    }
    return text
  }

  private static func isNumeral(_ char: String) -> Bool { char == "." || char.first?.isNumber == true }
}

public struct TemplateRecognizer: ExpressionRecognizing {
  public var version = 1
  private let reader: LineReader

  public init(classifier: SymbolClassifier) { reader = LineReader(classifier: classifier) }

  // Stock shapes only, until there are samples of the reader's own hand.
  public init() { self.init(classifier: SymbolClassifier(templates: StockTemplates.make())) }

  public func read(_ gathering: Gathering) async -> Reading? { reader.read(gathering) }
}
