import Foundation
import Testing

@testable import NoteCraftCore

// How the readers do on digits that real people wrote with a pen, not on glyphs bent by a program:
// the "Pen-Based Recognition of Handwritten Digits" set (UCI, CC BY 4.0; 44 writers, the 14 of
// `pendigits-orig.tes` are not in the pretrained network's training). It is not in the repository.
//
//   NOTECRAFT_PENDIGITS=/path/to/pendigits-orig.tes swift test -c release -Xswiftc -enable-testing --filter RealStroke
//
// The file is `pendigits-orig.tes.Z` of https://archive.ics.uci.edu/dataset/81, uncompressed with
// `gzip -d`. The numbers go in docs/CALCULATOR.md.

private let path = ProcessInfo.processInfo.environment["NOTECRAFT_PENDIGITS"]

private struct WrittenDigit {
  var digit: Int
  var strokes: [[Point]]
}

private func load(_ path: String) -> [WrittenDigit] {
  guard let text = try? String(contentsOfFile: path, encoding: .isoLatin1) else { return [] }
  var out: [WrittenDigit] = []
  var current: WrittenDigit?
  var stroke: [Point]?
  func closeStroke() {
    if let s = stroke, !s.isEmpty { current?.strokes.append(s) }
    stroke = nil
  }
  func closeDigit() {
    closeStroke()
    if let c = current, !c.strokes.isEmpty { out.append(c) }
    current = nil
  }
  for raw in text.split(separator: "\n") {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix(".SEGMENT") {
      closeDigit()
      if let quote = line.lastIndex(of: "\""), let digit = Int(String(line[line.index(before: quote)])) {
        current = WrittenDigit(digit: digit, strokes: [])
      }
    } else if line == ".PEN_DOWN" {
      closeStroke()
      stroke = []
    } else if line == ".PEN_UP" {
      closeStroke()
    } else if !line.isEmpty, !line.hasPrefix("."), stroke != nil {
      let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
      // The tablet's y points up.
      if parts.count == 2 { stroke?.append(Point(parts[0], -parts[1])) }
    }
  }
  closeDigit()
  return out
}

@Test(.enabled(if: path != nil)) func singleDigitsWrittenByPeople() throws {
  let digits = load(try #require(path))
  #expect(digits.count > 3000)
  let neural = NeuralSymbolClassifier()
  let stock = SymbolClassifier(templates: StockTemplates.make())
  var neuralRight = 0, stockRight = 0, refused = 0, neuralSureWrong = 0
  var confusion: [String: Int] = [:]
  for d in digits {
    if let found = neural.candidates(d.strokes) {
      if found.options[0].symbol == String(d.digit) { neuralRight += 1 } else {
        confusion["\(d.digit)→\(found.options[0].symbol)", default: 0] += 1
        if found.margin >= LineReader.certainMargin * 0.9 { neuralSureWrong += 1 }
      }
    } else { refused += 1 }
    if let found = stock.candidates(d.strokes), found.options[0].symbol == String(d.digit) { stockRight += 1 }
  }
  let n = Double(digits.count)
  print("""
    single digits of \(digits.count) written by people
      pretrained network: right \(Double(neuralRight) / n), refused \(Double(refused) / n), wrong and sure \(neuralSureWrong)
      stock shapes:       right \(Double(stockRight) / n)
      commonest mistakes of the network: \(confusion.sorted { $0.value > $1.value }.prefix(8))
    """)
  #expect(Double(neuralRight) / n > 0.9)
}

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

private struct Outcome {
  var rightSure = 0, rightUnsure = 0, wrongSure = 0, wrongUnsure = 0, unread = 0, wrongSureCases: [String] = []
  var total: Int { rightSure + rightUnsure + wrongSure + wrongUnsure + unread }
}

// Whole calculations: the digits as people wrote them, the operators from the drawn glyphs, laid out like a line.
private func readLines(with reader: LineReader, digits: [WrittenDigit], count: Int) -> Outcome {
  var byDigit: [Int: [WrittenDigit]] = [:]
  for d in digits { byDigit[d.digit, default: []].append(d) }
  var rng = SeededGenerator(seed: 2026)
  var out = Outcome()
  for i in 0..<count {
    let text = randomExpression(&rng)
    var w = SynthWriter(seed: UInt64(30_000 + i), strength: 0.8, height: 40)
    var cursor = 100.0
    for char in text {
      if let value = char.wholeNumberValue {
        let pick = byDigit[value]![Int.random(in: 0..<byDigit[value]!.count, using: &rng)]
        cursor += w.write(strokes: pick.strokes, at: Point(cursor, 200), height: 40) + 40 * 0.3
      } else {
        let symbol = char == "/" ? "÷" : String(char)
        cursor += w.write(symbol, at: Point(cursor, 200)) + 40 * 0.34
      }
    }
    w.equals(at: cursor + 6, axis: 220)
    let page = w.page()
    guard let g = CalculatorTrigger.gathering(for: page.strokes.last!, on: page),
      let reading = reader.read(g)
    else { out.unread += 1; continue }
    func value(_ t: String) -> String {
      switch Expression.evaluate(t) {
      case .success(let v): return v.formatted().text
      case .failure(let e): return "\(e)"
      }
    }
    let same = value(reading.expression) == value(text)
    let sure = reading.confidence >= Calculator.minimumConfidence
    switch (same, sure) {
    case (true, true): out.rightSure += 1
    case (true, false): out.rightUnsure += 1
    case (false, true):
      out.wrongSure += 1
      out.wrongSureCases.append("\(text) → \(reading.expression)")
    case (false, false): out.wrongUnsure += 1
    }
  }
  return out
}

@Test(.enabled(if: path != nil)) func calculationsWrittenWithRealDigits() throws {
  let digits = load(try #require(path))
  let count = 300
  let neural = readLines(with: LineReader(classifier: NeuralSymbolClassifier()), digits: digits, count: count)
  let stock = readLines(
    with: LineReader(classifier: SymbolClassifier(templates: StockTemplates.make())), digits: digits, count: count)
  func line(_ o: Outcome) -> String {
    "right and sure \(o.rightSure), right but unsure \(o.rightUnsure), wrong and sure \(o.wrongSure), wrong and unsure \(o.wrongUnsure), unread \(o.unread) of \(o.total)"
  }
  print("""
    \(count) calculations with digits written by people
      pretrained network: \(line(neural))
      stock shapes:       \(line(stock))
      wrong and sure (network): \(neural.wrongSureCases.prefix(12))
    """)
  #expect(neural.rightSure > stock.rightSure)
}

// Where the reading of a whole calculation is lost: the drawn operators of the test writer, one by one.
@Test(.enabled(if: path != nil)) func operatorsOfTheTestWriterAreRead() {
  let neural = NeuralSymbolClassifier()
  for symbol in ["+", "-", "*", "÷", "(", ")"] {
    var right = 0, refused = 0
    var got: [String: Int] = [:]
    for i in 0..<200 {
      var w = SynthWriter(seed: UInt64(900 + i), strength: 0.8, height: 40)
      w.write(symbol, at: Point(100, 200))
      let strokes = w.strokes.map { $0.samples.map(\.point) }
      if let found = neural.candidates(strokes) {
        let said = found.options[0].symbol == "/" ? "÷" : found.options[0].symbol
        if said == symbol { right += 1 } else { got[said, default: 0] += 1 }
      } else { refused += 1 }
    }
    print("operator \(symbol): right \(right) of 200, refused \(refused), read as \(got)")
  }
}
