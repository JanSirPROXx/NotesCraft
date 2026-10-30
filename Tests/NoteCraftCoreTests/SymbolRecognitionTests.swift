import Foundation
import Testing

@testable import NoteCraftCore

// The recognizer is read against writing it has not seen: stock glyphs bent out of shape with
// seeds that no template was made with. What these tests protect is not that every calculation is
// read (a question mark is a fine answer) but that a wrong reading is never presented as certain.

private let stock = SymbolClassifier(templates: StockTemplates.make())

private func randomExpression(_ rng: inout SeededGenerator) -> String {
  func number() -> String {
    String(Int.random(in: 1...(Bool.random(using: &rng) ? 9 : 99), using: &rng))
  }
  var text = number()
  for _ in 0..<Int.random(in: 1...2, using: &rng) {
    text += ["+", "-", "*", "/"].randomElement(using: &rng)! + number()
  }
  return text
}

private struct Tally {
  var rightSure = 0, rightUnsure = 0, wrongSure = 0, wrongUnsure = 0, unread = 0
  var total: Int { rightSure + rightUnsure + wrongSure + wrongUnsure + unread }
  var wrongSureCases: [String] = []

  mutating func add(_ truth: String, _ reading: Reading?) {
    guard let reading else { unread += 1; return }
    let sure = reading.confidence >= Calculator.minimumConfidence
    // The same calculation, whatever the way it is spelled.
    let same = value(reading.expression) == value(truth)
    switch (same, sure) {
    case (true, true): rightSure += 1
    case (true, false): rightUnsure += 1
    case (false, true):
      wrongSure += 1
      wrongSureCases.append("\(truth) → \(reading.expression)")
    case (false, false): wrongUnsure += 1
    }
  }
  private func value(_ text: String) -> String {
    switch Expression.evaluate(text) {
    case .success(let v): return v.formatted().text
    case .failure(let e): return "\(e)"
    }
  }
}

private func calculations(strength: Double, count: Int = 300, seed: UInt64 = 777) -> Tally {
  let reader = LineReader(classifier: stock)
  var rng = SeededGenerator(seed: seed)
  var tally = Tally()
  for i in 0..<count {
    let text = randomExpression(&rng)
    var w = SynthWriter(seed: UInt64(10_000 + i), strength: strength, height: 40)
    let end = w.line(text, from: 100, top: 200)
    w.equals(at: end + 6, axis: 220)
    let page = w.page()
    guard let g = CalculatorTrigger.gathering(for: page.strokes.last!, on: page) else {
      tally.unread += 1
      continue
    }
    tally.add(text, reader.read(g))
  }
  return tally
}

// The full benchmark is 900 calculations and takes minutes in a build without optimization:
//   NOTECRAFT_RECOGNITION_BENCHMARK=1 swift test -c release -Xswiftc -enable-testing --filter SymbolRecognition
private let fullBenchmark = ProcessInfo.processInfo.environment["NOTECRAFT_RECOGNITION_BENCHMARK"] != nil

@Test(.enabled(if: fullBenchmark), arguments: [0.8, 1.0, 1.3])
func aWrongReadingIsNeverPresentedAsCertain(_ strength: Double) {
  let t = calculations(strength: strength)
  #expect(t.wrongSure == 0, "\(t.wrongSureCases)")
}

@Test(.enabled(if: fullBenchmark)) func mostCasualWritingIsReadAndTrusted() {
  let t = calculations(strength: 0.8)
  #expect(Double(t.rightSure) / Double(t.total) >= 0.85, "right and sure: \(t.rightSure) of \(t.total)")
  let worse = calculations(strength: 1.0)
  #expect(Double(worse.rightSure) / Double(worse.total) >= 0.75, "right and sure: \(worse.rightSure) of \(worse.total)")
}

// What always runs: a small sample, with the same two promises.
@Test func aSmallSampleIsReadAndNoWrongReadingIsTrusted() {
  let t = calculations(strength: 1.0, count: 30)
  #expect(t.wrongSure == 0, "\(t.wrongSureCases)")
  #expect(Double(t.rightSure) / Double(t.total) >= 0.6, "right and sure: \(t.rightSure) of \(t.total)")
}

@Test func fractionsAreReadWithTheirBar() {
  let reader = LineReader(classifier: stock)
  var tally = Tally()
  var rng = SeededGenerator(seed: 4242)
  for i in 0..<(fullBenchmark ? 150 : 24) {
    let a = Int.random(in: 1...9, using: &rng), b = Int.random(in: 1...9, using: &rng)
    let c = Int.random(in: 2...9, using: &rng)
    let useSum = Bool.random(using: &rng)
    let top = useSum ? "\(a)+\(b)" : "\(a * 10 + b)"
    var w = SynthWriter(seed: UInt64(50_000 + i), strength: 0.8, height: 40)
    let end = w.fraction(top, over: "\(c)", from: 100, axis: 220)
    w.equals(at: end + 8, axis: 220)
    let page = w.page()
    guard let g = CalculatorTrigger.gathering(for: page.strokes.last!, on: page) else {
      tally.unread += 1
      continue
    }
    tally.add("(\(top))/\(c)", reader.read(g))
  }
  #expect(tally.wrongSure == 0, "\(tally.wrongSureCases)")
  #expect(Double(tally.rightSure) / Double(tally.total) >= 0.6, "right and sure: \(tally.rightSure) of \(tally.total)")
}

@Test func anEightWrittenAsTwoRingsIsNotTwoZeros() throws {
  let rings = StockGlyphs.all.first { $0.symbol == "8" && $0.strokes.count == 2 }!
  var w = SynthWriter(seed: 9, strength: 0.4, height: 40)
  var s = w.strokes
  for stroke in rings.strokes {
    var made = Stroke(
      samples: stroke.map { Sample(point: Point(100 + $0.x * 40, 200 + $0.y * 40)) }, color: .blue,
      width: 2.5, tool: .pen, style: .ballpoint)
    made.calculator = true
    s.append(made)
  }
  w.strokes = s
  w.line("*2", from: 140, top: 200)
  w.equals(at: 210, axis: 220)
  let page = w.page()
  let g = try #require(CalculatorTrigger.gathering(for: page.strokes.last!, on: page))
  let reading = LineReader(classifier: stock).read(g)
  #expect(reading?.expression != "00*2")
  if let reading, reading.confidence >= Calculator.minimumConfidence {
    #expect(reading.expression == "8*2")
  }
}

@Test func aPlusIsNotAMinusAndAOne() throws {
  var wrong = 0, trusted = 0
  for i in 0..<(fullBenchmark ? 60 : 16) {
    var w = SynthWriter(seed: UInt64(900 + i), strength: 1.0, height: 40)
    let end = w.line("4+4", from: 100, top: 200)
    w.equals(at: end + 6, axis: 220)
    let page = w.page()
    guard let g = CalculatorTrigger.gathering(for: page.strokes.last!, on: page),
      let reading = LineReader(classifier: stock).read(g), reading.confidence >= Calculator.minimumConfidence
    else { continue }
    trusted += 1
    if reading.expression != "4+4" { wrong += 1 }
  }
  #expect(wrong == 0)
  #expect(trusted > (fullBenchmark ? 30 : 6))
}

@Test func theReadersOwnHandwritingBecomesATemplate() throws {
  // A "5" written in a way the stock shapes do not have: one stroke that is a mirrored S.
  func zigzag() -> [[Point]] {
    [(0...20).map { i in
      let t = Double(i) / 20
      return Point(0.25 + 0.25 * sin(t * 2 * .pi * 1.2 + 0.4), t)
    }]
  }
  let alone = SymbolClassifier(templates: StockTemplates.make())
  let before = alone.classify(zigzag())
  let mine = SymbolClassifier(
    templates: StockTemplates.make() + [StockTemplates.template(symbol: "5", strokes: zigzag())!])
  let after = try #require(mine.classify(zigzag()))
  #expect(after.symbol == "5")
  #expect(after.distance < (before?.distance ?? 1))
  #expect(after.margin > 0.5)
}

@Test func readingAFullCalculationIsFast() throws {
  var w = SynthWriter(seed: 31, strength: 1.0, height: 40)
  let end = w.line("48+9*72-5", from: 60, top: 200)
  w.equals(at: end + 6, axis: 220)
  let page = w.page()
  let g = try #require(CalculatorTrigger.gathering(for: page.strokes.last!, on: page))
  let reader = LineReader(classifier: stock)
  let start = Date()
  _ = reader.read(g)
  // Nine symbols. Only an optimized build says anything about speed; a build for tests has none.
  #if !DEBUG
    #expect(Date().timeIntervalSince(start) < 0.25)
  #endif
  _ = start
}
