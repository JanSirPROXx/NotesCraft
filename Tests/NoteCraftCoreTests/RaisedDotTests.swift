import Foundation
import Testing

@testable import NoteCraftCore

// "2·3" is a product and "2.3" a decimal number, told by how high the dot sits against the digits on
// either side of it. Halfway up is a times sign, on the line is a decimal point, and in between the
// reading is not trusted.

private let stock = SymbolClassifier(templates: StockTemplates.make())

private struct Outcome {
  var trusted = 0
  var wrong: [String] = []
  var unreadOrUnsure = 0
}

// "2", a dot `level` of a digit's height above the digits' foot, "3", and the "=" that asks for the answer.
private func read(
  _ level: Double, expecting expected: String, seeds: Range<Int>, strength: Double = 0.6
) -> Outcome {
  var out = Outcome()
  for seed in seeds {
    var w = SynthWriter(seed: UInt64(7_000 + seed), strength: strength, height: 40)
    let end = w.write("2", at: Point(100, 200)) + 100
    w.dot(at: Point(end + 9, 240 - level * 40))
    let right = w.write("3", at: Point(end + 18, 200)) + end + 18
    w.equals(at: right + 8, axis: 220)
    let page = w.page()
    guard let gathering = CalculatorTrigger.gathering(for: page.strokes.last!, on: page),
      let reading = LineReader(classifier: stock).read(gathering),
      reading.confidence >= Calculator.minimumConfidence
    else {
      out.unreadOrUnsure += 1
      continue
    }
    out.trusted += 1
    if reading.expression != expected { out.wrong.append(reading.expression) }
  }
  return out
}

@Test func aDotHalfwayUpIsATimesSign() {
  let out = read(0.5, expecting: "2*3", seeds: 0..<24)
  #expect(out.wrong.isEmpty, "\(out.wrong)")
  #expect(out.trusted >= 8, "trusted \(out.trusted) of 24")
}

@Test func aDotOnTheLineIsADecimalPoint() {
  let out = read(0.05, expecting: "2.3", seeds: 0..<24)
  #expect(out.wrong.isEmpty, "\(out.wrong)")
  #expect(out.trusted >= 8, "trusted \(out.trusted) of 24")
}

@Test func aDotBetweenTheTwoLevelsIsNotTrusted() {
  // Glyphs that are not bent, so that the level of the dot is the one asked for.
  let out = read(0.26, expecting: "", seeds: 0..<24, strength: 0)
  #expect(out.trusted == 0, "trusted as \(out.wrong)")
  // The same writing with the dot halfway up is read and trusted, so the test is not just about nothing read.
  #expect(read(0.5, expecting: "2*3", seeds: 0..<24, strength: 0).trusted > 0)
}
