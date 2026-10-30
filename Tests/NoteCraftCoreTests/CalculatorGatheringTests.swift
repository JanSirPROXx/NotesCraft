import Foundation
import Testing

@testable import NoteCraftCore

// Pages are laid out the way handwriting is: glyphs of one height on a baseline, a small gap
// between them. The strokes are crude (a diagonal, a bar) because only their boxes count here.
private struct Writer {
  var strokes: [Stroke] = []
  var x = 40.0
  var baseline: Double
  var height: Double
  var calculator = true

  init(baseline: Double = 100, height: Double = 20) {
    self.baseline = baseline
    self.height = height
  }

  private func stroke(_ points: [(Double, Double)], calculator: Bool? = nil) -> Stroke {
    var s = Stroke(
      samples: points.map { Sample(point: Point($0.0, $0.1)) }, color: .blue, width: 2.5,
      tool: .pen, style: .ballpoint)
    s.calculator = calculator ?? self.calculator
    return s
  }

  mutating func digit() {
    let w = height * 0.55
    strokes.append(
      stroke([(x, baseline - height), (x + w * 0.2, baseline - height * 0.4), (x + w, baseline)]))
    x += w + height * 0.3
  }
  mutating func digits(_ count: Int) { for _ in 0..<count { digit() } }

  mutating func plus() {
    let w = height * 0.5
    let mid = baseline - height / 2
    strokes.append(stroke([(x, mid), (x + w * 0.5, mid + 0.4), (x + w, mid)]))
    strokes.append(
      stroke([(x + w / 2, mid - w / 2), (x + w / 2 + 0.3, mid), (x + w / 2, mid + w / 2)]))
    x += w + height * 0.35
  }

  mutating func equals() {
    let w = height * 0.55
    let mid = baseline - height / 2
    let d = height * 0.15
    strokes.append(stroke([(x, mid - d), (x + w / 2, mid - d - 0.4), (x + w, mid - d)]))
    strokes.append(stroke([(x + 1, mid + d), (x + w / 2, mid + d + 0.3), (x + w + 1, mid + d)]))
    x += w + height * 0.35
  }

  mutating func gap(_ glyphs: Double) { x += height * glyphs }

  // Ink of an ordinary pen, however it is shaped.
  mutating func plainInk() {
    strokes.append(stroke([(x, baseline - height), (x + 8, baseline)], calculator: false))
    x += 12
  }
}

private func page(_ strokes: [Stroke], texts: [TextBox] = []) -> Page {
  var page = Page()
  page.strokes = strokes
  page.texts = texts
  return page
}
private func gathering(_ p: Page) -> Gathering? {
  p.strokes.last.flatMap { CalculatorTrigger.gathering(for: $0, on: p) }
}
// A failed expectation on the page itself would print every sample of it.
private func gathered(_ p: Page) throws -> Gathering {
  let result = gathering(p)
  return try #require(result != nil ? result : nil)
}
private func found(_ p: Page) -> Bool { gathering(p) != nil }

@Test func collectsTheWholeCalculationBeforeTheEqualsSign() throws {
  var w = Writer()
  w.digits(2); w.plus(); w.digits(2); w.equals()
  let p = page(w.strokes)
  let g = try gathered(p)
  #expect(Set(g.strokeIDs) == Set(p.strokes.map(\.id)))
  #expect(g.glyphHeight > 15 && g.glyphHeight < 25)
  // The answer starts to the right of the "=" and on the writing's baseline.
  #expect(g.answerOrigin.x > g.mark.bounds.x + g.mark.bounds.width)
  #expect(abs(g.baseline - 100) < 2)
}

@Test func theLastStrokeAloneIsNoRequest() throws {
  var w = Writer()
  w.digits(2); w.plus(); w.digits(1)
  #expect(!found(page(w.strokes)))
  // One bar, with the digits before it, is a minus and not a "=".
  var minus = Writer()
  minus.digits(2)
  minus.strokes.append(
    Stroke(samples: [Sample(point: Point(minus.x, 90)), Sample(point: Point(minus.x + 12, 90))]))
  minus.strokes[minus.strokes.count - 1].calculator = true
  #expect(!found(page(minus.strokes)))
}

@Test func barsThatAreNotStackedAreNoEqualsSign() throws {
  // Two flat strokes side by side (a minus, then a minus) or far apart one above the other.
  var side = Writer()
  side.digits(1)
  let y = 90.0
  for dx in [0.0, 30.0] {
    var s = Stroke(samples: [Sample(point: Point(side.x + dx, y)), Sample(point: Point(side.x + dx + 12, y))])
    s.calculator = true
    side.strokes.append(s)
  }
  #expect(!found(page(side.strokes)))
  var far = Writer()
  far.digits(1)
  for dy in [0.0, 40.0] {
    var s = Stroke(samples: [Sample(point: Point(far.x, y + dy)), Sample(point: Point(far.x + 12, y + dy))])
    s.calculator = true
    far.strokes.append(s)
  }
  #expect(!found(page(far.strokes)))
}

@Test func onlyCalculatorInkIsReadWhateverItsColourOrShape() throws {
  var w = Writer()
  w.digits(1); w.plainInk(); w.digit(); w.plus(); w.digit(); w.equals()
  let p = page(w.strokes)
  let g = try gathered(p)
  let plain = p.strokes.filter { !$0.calculator }.map(\.id)
  #expect(plain.count == 1)
  #expect(Set(g.strokeIDs).isDisjoint(with: plain))
  #expect(g.strokes.count == p.strokes.count - 1)
}

@Test func anEqualsSignDrawnWithAnotherPenDoesNothing() throws {
  var w = Writer()
  w.digits(2); w.plus(); w.digits(2)
  w.calculator = false
  w.equals()
  #expect(!found(page(w.strokes)))
}

@Test func aSolvedCalculationAndItsAnswerEndTheSearch() throws {
  var w = Writer()
  w.digit(); w.plus(); w.digit(); w.equals()
  let first = w.strokes
  var answer = TextBox(origin: Point(w.x, 78), text: "4")
  answer.size = 28
  answer.boxWidth = 24
  answer.calculation = CalculationLink(
    strokeIDs: first.map(\.id), expression: "2+2", state: .done, recognizerVersion: 0)
  w.x = answer.bounds.x + answer.bounds.width + 6
  // The next calculation starts right behind the answer, with less than a glyph between them.
  let startOfSecond = w.strokes.count
  w.digit(); w.plus(); w.digit(); w.equals()
  let g = try gathered(page(w.strokes, texts: [answer]))
  #expect(Set(g.strokeIDs) == Set(w.strokes[startOfSecond...].map(\.id)))
}

@Test func twoLinesStayTwoCalculations() throws {
  var upper = Writer(baseline: 60)
  upper.digit(); upper.plus(); upper.digit(); upper.equals()
  var lower = Writer(baseline: 100)
  lower.digit(); lower.plus(); lower.digit(); lower.equals()
  // Same columns on both lines: the first line is not solved yet, so only the band keeps it out.
  let g = try gathered(page(upper.strokes + lower.strokes))
  #expect(Set(g.strokeIDs) == Set(lower.strokes.map(\.id)))
}

@Test func aWideGapEndsTheCalculation() throws {
  var w = Writer()
  w.digit()
  w.gap(3)
  let kept = w.strokes.count
  w.digit(); w.plus(); w.digit(); w.equals()
  let p = page(w.strokes)
  let g = try gathered(p)
  #expect(!g.strokeIDs.contains(p.strokes[0].id))
  #expect(g.strokes.count == p.strokes.count - kept)
}

@Test func writingAfterTheEqualsSignMakesItAnEquationNotARequest() throws {
  var w = Writer()
  w.digits(2); w.equals()
  w.digit()
  // The last stroke is a digit here, so nothing is asked.
  #expect(!found(page(w.strokes)))
  // A digit already standing to the right when the "=" is finished.
  var inserted = Writer()
  inserted.digits(2)
  let markX = inserted.x
  inserted.x += 14
  inserted.digits(2)
  var later = Writer()
  later.x = markX
  later.equals()
  let p = page(inserted.strokes + later.strokes)
  #expect(!found(p))
}

@Test(arguments: [6.0, 8.0, 14.0, 20.0, 40.0, 90.0])
func worksAtEveryHandwritingSize(_ height: Double) throws {
  var w = Writer(baseline: 300, height: height)
  w.digits(3); w.plus(); w.digits(2); w.equals()
  let p = page(w.strokes)
  let g = try gathered(p)
  #expect(g.strokes.count == p.strokes.count)
  // The box includes the pen width (2.5), which is most of a glyph at the smallest sizes.
  #expect(abs(g.glyphHeight - height) < height * 0.3 + 2.5)
}

@Test func anAnswerIsRemovedWhenItsWritingIsGone() throws {
  var w = Writer()
  w.digit(); w.plus(); w.digit(); w.equals()
  let g = try gathered(page(w.strokes))
  let box = Calculator.answerBox(
    for: Calculator.outcome(forExpression: "2+2"), gathering: g, color: .blue, fontName: nil,
    ascender: 0.95, recognizerVersion: 0)
  var p = page(w.strokes, texts: [box])
  #expect(Calculator.pruned(p).texts.count == 1)
  p.strokes.removeFirst()
  #expect(Calculator.pruned(p).texts.isEmpty)
  // A text box the user typed is never touched.
  p.texts.append(TextBox(origin: Point(0, 0), text: "note"))
  #expect(Calculator.pruned(p).texts.map(\.text) == ["note"])
}

@Test func theAnswerSitsOnTheBaselineInThePensColour() throws {
  var w = Writer(baseline: 200, height: 30)
  w.digits(2); w.equals()
  let g = try gathered(page(w.strokes))
  let box = Calculator.answerBox(
    for: Calculator.outcome(forExpression: "12*3"), gathering: g, color: .blue, fontName: "X",
    ascender: 0.9, recognizerVersion: 3)
  #expect(box.text == "36")
  #expect(box.color == .blue)
  #expect(abs(box.origin.y + 0.9 * box.size - 200) < 3)
  #expect(box.bounds.x >= g.mark.bounds.x + g.mark.bounds.width)
  #expect(box.calculation?.recognizerVersion == 3)
  #expect(box.layoutBounds.width < 120)
}

@Test func outcomesNeverShowAGuess() throws {
  #expect(Calculator.outcome(for: nil).text == "?")
  #expect(Calculator.outcome(for: nil).state == .uncertain)
  #expect(Calculator.outcome(for: Reading(expression: "2+2", confidence: 0.5)).text == "?")
  #expect(Calculator.outcome(for: Reading(expression: "2+2", confidence: 0.5)).expression == "2+2")
  #expect(Calculator.outcome(for: Reading(expression: "12*3+4")).text == "40")
  #expect(Calculator.outcome(forExpression: "1/3").text == "≈0.3333333333")
  #expect(Calculator.outcome(forExpression: "1/0").text == "undefined")
  #expect(Calculator.outcome(forExpression: "1/0").state == .done)
  #expect(Calculator.outcome(forExpression: "2+").text == "?")
  #expect(Calculator.outcome(forExpression: "1,5+1").text == "?")
  #expect(Calculator.outcome(forExpression: "9^9999").text == "too large")
}

@Test func theGatheringStaysFastOnAFullPage() throws {
  var strokes: [Stroke] = []
  for i in 0..<1800 {
    strokes.append(
      Stroke(samples: [Sample(point: Point(Double(i % 60) * 9, Double(i / 60) * 25 + 400)),
        Sample(point: Point(Double(i % 60) * 9 + 5, Double(i / 60) * 25 + 418))]))
  }
  var w = Writer(baseline: 100)
  w.digits(3); w.plus(); w.digits(3); w.equals()
  let p = page(strokes + w.strokes)
  let start = Date()
  for _ in 0..<50 { #expect(found(p)) }
  // 50 triggers in well under a second: one is far below a frame.
  #expect(Date().timeIntervalSince(start) < 1)
}

@Test func aHandCorrectionReplacesTheAnswerInPlace() throws {
  var w = Writer(baseline: 200, height: 30)
  w.digits(2); w.equals()
  let g = try gathered(page(w.strokes))
  let unsure = Calculator.answerBox(
    for: Calculator.outcome(for: nil), gathering: g, color: .blue, fontName: nil, ascender: 0.9,
    recognizerVersion: 0)
  #expect(unsure.text == "?" && unsure.calculation?.state == .uncertain)
  let fixed = Calculator.corrected(unsure, with: Calculator.outcome(forExpression: "12*3+4"))
  #expect(fixed.text == "40" && fixed.calculation?.state == .done)
  #expect(fixed.calculation?.expression == "12*3+4")
  #expect(fixed.origin == unsure.origin && fixed.size == unsure.size && fixed.id == unsure.id)
  #expect(fixed.calculation?.strokeIDs == unsure.calculation?.strokeIDs)
  #expect(fixed.layoutBounds.width >= unsure.layoutBounds.width)
}

// "9+2" over a bar over "11", then "=": the layout of the fraction in the iPad screenshot (pixels
// are taken as points; only the proportions matter). The "=" stands at the height of the bar.
private func fraction(scale: Double = 1, dx: Double = 0, dy: Double = 0) -> [Stroke] {
  func mark(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Stroke {
    var s = Stroke(
      samples: [
        Sample(point: Point((x0 + dx) * scale, (y0 + dy) * scale)),
        Sample(point: Point((x1 + dx) * scale, (y1 + dy) * scale)),
      ], color: .blue, width: 2.5, tool: .pen, style: .ballpoint)
    s.calculator = true
    return s
  }
  return [
    mark(1182, 750, 1212, 800),  // 9
    mark(1240, 775, 1262, 775),  // + (bar)
    mark(1251, 765, 1251, 786),  // + (stem)
    mark(1275, 758, 1305, 792),  // 2
    mark(1160, 810, 1332, 814),  // the fraction bar
    mark(1212, 845, 1226, 878),  // 1
    mark(1245, 845, 1262, 878),  // 1
    mark(1360, 808, 1405, 808),  // = (upper bar)
    mark(1360, 822, 1405, 822),  // = (lower bar)
  ]
}

@Test func aFractionIsReadWholeNotJustItsNumerator() throws {
  let strokes = fraction()
  let p = page(strokes)
  let g = try gathered(p)
  #expect(Set(g.strokeIDs) == Set(strokes.map(\.id)), "numerator, bar and denominator all belong")
  // The glow's box covers the whole fraction, over and under the bar.
  #expect(g.bounds.y < 760 && g.bounds.y + g.bounds.height > 870)
}

@Test func theAnswerBesideAFractionIsCentredOnTheEquals() throws {
  let g = try gathered(page(fraction()))
  let markCentre = g.mark.bounds.y + g.mark.bounds.height / 2
  // Not on the foot of the numerator (about 800), but a digit centred on the "=".
  #expect(abs(g.baseline - (markCentre + g.glyphHeight / 2)) < 1)
  #expect(g.glyphHeight > 25 && g.glyphHeight < 60, "a digit's height, not the fraction's")
  let box = Calculator.answerBox(
    for: Calculator.outcome(forExpression: "11/11"), gathering: g, color: .blue, fontName: nil,
    ascender: 0.9, recognizerVersion: 0)
  let middle = box.origin.y + 0.9 * box.size - g.glyphHeight / 2
  #expect(abs(middle - markCentre) < 2)
}

@Test(arguments: [0.4, 1.0, 2.5])
func aFractionIsReadWholeAtAnySize(_ scale: Double) throws {
  let strokes = fraction(scale: scale, dx: -900, dy: -600)
  let g = try gathered(page(strokes))
  #expect(Set(g.strokeIDs) == Set(strokes.map(\.id)))
}

@Test func aMinusBetweenNumbersIsNoFractionBar() throws {
  // "12 - 3 =": a flat stroke with nothing over or under it stays a minus.
  var w = Writer()
  w.digits(2)
  let mid = w.baseline - w.height / 2
  var minus = Stroke(samples: [Sample(point: Point(w.x, mid)), Sample(point: Point(w.x + 11, mid))])
  minus.calculator = true
  w.strokes.append(minus)
  w.x += 20
  w.digit(); w.equals()
  let p = page(w.strokes)
  let g = try gathered(p)
  #expect(g.strokes.count == p.strokes.count)
  #expect(abs(g.baseline - 100) < 2, "plain writing keeps the baseline of its digits")
}

@Test func writingAboveAFractionLineIsNotPulledIn() throws {
  // A finished calculation one line up, not above this fraction's bar: it is far and not over it.
  var upper = Writer(baseline: 560)
  upper.x = 40
  upper.digits(2); upper.plus(); upper.digits(2)
  let g = try gathered(page(upper.strokes + fraction()))
  #expect(Set(g.strokeIDs).isDisjoint(with: upper.strokes.map(\.id)))
}

@Test func aBarWithOnlyANumeratorStaysABar() throws {
  // Writing over a line with nothing under it is not a fraction: a numerator that is well above the
  // band is not reached.
  var strokes = fraction()
  strokes.removeSubrange(5...6)
  strokes = strokes.enumerated().map { index, stroke in
    guard index < 4 else { return stroke }
    var moved = stroke
    for i in moved.samples.indices { moved.samples[i].point.y -= 30 }
    return moved
  }
  let g = try gathered(page(strokes))
  #expect(!g.strokeIDs.contains(strokes[0].id))
}
