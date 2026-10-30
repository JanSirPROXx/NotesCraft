import Foundation

@testable import NoteCraftCore

// Writes calculations the way a hand would, from the stock glyphs bent out of shape with a seed
// that no template was made with, so the recognizer is tested on writing it has not seen.
struct SynthWriter {
  var rng: SeededGenerator
  var strength: Double
  var height: Double
  var strokes: [Stroke] = []

  init(seed: UInt64, strength: Double = 1, height: Double = 40) {
    rng = SeededGenerator(seed: seed)
    self.strength = strength
    self.height = height
  }

  // One glyph for the symbol, drawn at `origin` (its top left), `scale` times the digit height.
  // Returns the width it took.
  @discardableResult
  mutating func write(_ symbol: String, at origin: Point, scale: Double = 1) -> Double {
    let variants = StockGlyphs.all.filter { $0.symbol == symbol }
    let glyph = variants[Int.random(in: 0..<variants.count, using: &rng)]
    let bent = StockGlyphs.perturbed(glyph.strokes, strength: strength, using: &rng)
    let all = bent.flatMap { $0 }
    let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
    for stroke in bent {
      var s = Stroke(
        samples: stroke.map {
          Sample(point: Point(origin.x + ($0.x - minX) * height * scale, origin.y + $0.y * height * scale))
        }, color: .blue, width: 2.5, tool: .pen, style: .ballpoint)
      s.calculator = true
      strokes.append(s)
    }
    return (maxX - minX) * height * scale
  }

  // A line of symbols: "12+3*4". Division is written as ÷.
  @discardableResult
  mutating func line(_ text: String, from x: Double, top: Double, scale: Double = 1) -> Double {
    var cursor = x
    for char in text {
      var symbol = String(char)
      if symbol == "/" { symbol = "÷" }
      let isOperator = "+-*÷/()".contains(symbol)
      let width = write(symbol, at: Point(cursor, top), scale: scale)
      cursor += width + height * scale * (isOperator ? 0.34 : 0.26) + Double.random(in: -0.04...0.06, using: &rng) * height
    }
    return cursor
  }

  // numerator over denominator, a bar between, centred; returns the right edge.
  @discardableResult
  mutating func fraction(_ top: String, over bottom: String, from x: Double, axis: Double) -> Double {
    let probe = estimatedWidth(top), probe2 = estimatedWidth(bottom)
    let width = max(probe, probe2) + height * 0.3
    let numeratorStart = x + (width - probe) / 2
    let denominatorStart = x + (width - probe2) / 2
    line(top, from: numeratorStart, top: axis - height * 1.15)
    var bar = Stroke(
      samples: [Sample(point: Point(x, axis)), Sample(point: Point(x + width * 0.5, axis + 0.8)), Sample(point: Point(x + width, axis))],
      color: .blue, width: 2.5, tool: .pen, style: .ballpoint)
    bar.calculator = true
    strokes.append(bar)
    line(bottom, from: denominatorStart, top: axis + height * 0.2)
    return x + width
  }

  func estimatedWidth(_ text: String) -> Double { Double(text.count) * height * 0.8 }

  // "=" after a line, as the two bars it is written with.
  mutating func equals(at x: Double, axis: Double) {
    for dy in [-0.12, 0.12] {
      var s = Stroke(
        samples: [Sample(point: Point(x, axis + dy * height)),
          Sample(point: Point(x + height * 0.3, axis + dy * height + 0.4)),
          Sample(point: Point(x + height * 0.6, axis + dy * height))],
        color: .blue, width: 2.5, tool: .pen, style: .ballpoint)
      s.calculator = true
      strokes.append(s)
    }
  }

  func page() -> Page {
    var page = Page()
    page.strokes = strokes
    return page
  }
}
