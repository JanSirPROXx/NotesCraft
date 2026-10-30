import Foundation

// What the recognizer says the strokes of a calculation write, and what the page shows for it.

public struct Reading: Equatable, Sendable {
  // In the fixed notation `Expression` takes: `12*3+4`.
  public var expression: String
  // 0...1, how sure the recognizer is of the whole reading, not of a single symbol.
  public var confidence: Double
  public init(expression: String, confidence: Double = 1) {
    self.expression = expression
    self.confidence = confidence
  }
}

public protocol ExpressionRecognizing: Sendable {
  // Bumped when the recognizer changes, and stored with each answer.
  var version: Int { get }
  // nil when nothing could be read: a recognizer says so rather than guess.
  func read(_ gathering: Gathering) async -> Reading?
}

// For tests and UI tests: always reads the same calculation, whatever was written.
public struct FixedRecognizer: ExpressionRecognizing {
  public var version = 0
  public var reading: Reading?
  public init(_ expression: String?, confidence: Double = 1) {
    reading = expression.map { Reading(expression: $0, confidence: confidence) }
  }
  public func read(_ gathering: Gathering) async -> Reading? { reading }
}

// Used until a model is bundled: it reads nothing, so every calculation ends as a question mark
// that can be corrected by hand.
public struct NoModelRecognizer: ExpressionRecognizing {
  public var version = 0
  public init() {}
  public func read(_ gathering: Gathering) async -> Reading? { nil }
}

public struct CalculationOutcome: Equatable, Sendable {
  public var text: String
  public var state: CalculationLink.State
  // What was calculated, so a hand correction starts from the reading.
  public var expression: String
}

public enum Calculator {
  // Below this the whole reading is distrusted and no number is shown.
  public static let minimumConfidence = 0.9

  public static func outcome(for reading: Reading?) -> CalculationOutcome {
    guard let reading else { return CalculationOutcome(text: "?", state: .uncertain, expression: "") }
    return outcome(forExpression: reading.expression, confidence: reading.confidence)
  }

  public static func outcome(forExpression expression: String, confidence: Double = 1)
    -> CalculationOutcome
  {
    func unsure() -> CalculationOutcome {
      CalculationOutcome(text: "?", state: .uncertain, expression: expression)
    }
    guard confidence >= minimumConfidence else { return unsure() }
    switch Expression.evaluate(expression) {
    case .success(let value):
      let shown = value.formatted()
      return CalculationOutcome(
        text: (shown.approximate ? "≈" : "") + shown.text, state: .done, expression: expression)
    // A reading that is a real calculation without an answer says so; one that is no calculation
    // at all (a stroke gone wrong) is a question mark, never a made-up number.
    case .failure(.divisionByZero), .failure(.undefined):
      return CalculationOutcome(text: "undefined", state: .done, expression: expression)
    case .failure(.overflow):
      return CalculationOutcome(text: "too large", state: .done, expression: expression)
    case .failure: return unsure()
    }
  }

  // The text box that carries the answer, in the pen's colour, on the writing's baseline.
  // `ascender` is the font's, because a text box is positioned by its top.
  public static func answerBox(
    for outcome: CalculationOutcome, gathering: Gathering, color: InkColor, fontName: String?,
    ascender: Double, recognizerVersion: Int
  ) -> TextBox {
    let size = gathering.answerFontSize
    let origin = gathering.answerOrigin
    var box = TextBox(origin: Point(origin.x, origin.y - ascender * size), text: outcome.text)
    box.size = size
    box.color = color
    box.fontName = fontName
    // A box is as wide as its answer, so it is not a 280 pt hit area that swallows the page.
    box.boxWidth = max(size, Double(outcome.text.count) * size * 0.62 + size * 0.3)
    box.calculation = CalculationLink(
      strokeIDs: gathering.strokeIDs, expression: outcome.expression, state: outcome.state,
      recognizerVersion: recognizerVersion)
    return box
  }

  // An answer whose writing is gone (erased, cut) no longer answers anything.
  public static func pruned(_ page: Page) -> Page {
    guard page.texts.contains(where: { $0.calculation != nil }) else { return page }
    let ids = Set(page.strokes.map(\.id))
    var result = page
    result.texts.removeAll { text in
      guard let link = text.calculation else { return false }
      return !link.strokeIDs.allSatisfy(ids.contains)
    }
    return result
  }
}
