import Foundation

// The arithmetic of the calculator pen. Decimal, not Double, so 0.1 + 0.2 is 0.3 and a result that
// had to be rounded is known to be rounded. Nothing here may trap on input it did not expect: what
// the recognizer or the keyboard delivers ends as a value or as a `CalculatorError`, never a guess.
public enum CalculatorError: Error, Equatable, Sendable {
  case empty
  case syntax
  // A number that cannot be read in English notation, such as `1,5` or `5.`.
  case number
  case divisionByZero
  case undefined
  case overflow
}

public struct ExpressionValue: Equatable, Sendable {
  public var value: Decimal
  // False once a step had to round (1/3, a root that is not whole).
  public var exact: Bool
  public init(_ value: Decimal, exact: Bool = true) {
    self.value = value
    self.exact = exact
  }
}

public struct FormattedResult: Equatable, Sendable {
  public var text: String
  public var approximate: Bool
}

indirect enum ExpressionNode: Equatable, Sendable {
  case number(Decimal)
  case negate(ExpressionNode)
  case add(ExpressionNode, ExpressionNode)
  case subtract(ExpressionNode, ExpressionNode)
  case multiply(ExpressionNode, ExpressionNode)
  case divide(ExpressionNode, ExpressionNode)
  case power(ExpressionNode, ExpressionNode)
  case percent(ExpressionNode)
  case root(ExpressionNode)
}

public enum Expression {
  // `12*3+4`, also in the notation people type or write: × ÷ − and a trailing `=`.
  public static func evaluate(_ text: String) -> Result<ExpressionValue, CalculatorError> {
    do {
      let tokens = try Lexer.tokens(text)
      guard !tokens.isEmpty else { return .failure(.empty) }
      var parser = Parser(tokens: tokens)
      let node = try parser.parse()
      return .success(try Evaluator.value(of: node))
    } catch let error as CalculatorError {
      return .failure(error)
    } catch {
      return .failure(.syntax)
    }
  }
}

enum Token: Equatable {
  case number(Decimal)
  case plus, minus, times, divide, power, percent, root, open, close
}

enum Lexer {
  // More digits than a Decimal holds would be rounded without a word.
  static let maxDigits = 30

  static func tokens(_ text: String) throws -> [Token] {
    var out: [Token] = []
    let chars = Array(text)
    var i = 0
    var trimmed = chars.count
    while trimmed > 0, chars[trimmed - 1] == "=" || chars[trimmed - 1].isWhitespace { trimmed -= 1 }
    while i < trimmed {
      let c = chars[i]
      switch c {
      case " ", "\t", "\n": i += 1
      case "+": out.append(.plus); i += 1
      case "-", "−", "–": out.append(.minus); i += 1
      case "*", "×", "x", "X": out.append(.times); i += 1
      case "/", "÷": out.append(.divide); i += 1
      case "^": out.append(.power); i += 1
      case "%": out.append(.percent); i += 1
      case "√": out.append(.root); i += 1
      case "(": out.append(.open); i += 1
      case ")": out.append(.close); i += 1
      case "0"..."9", ".", ",":
        let (value, next) = try number(chars, from: i, end: trimmed)
        out.append(.number(value))
        i = next
      default: throw CalculatorError.syntax
      }
    }
    return out
  }

  // English notation: `.` is the decimal point and always one, a comma only groups thousands
  // (`1,000`). A comma anywhere else is rejected instead of read as a decimal, because a
  // handwritten comma and point look alike and a wrong guess changes the result by a factor.
  private static func number(_ chars: [Character], from start: Int, end: Int) throws -> (Decimal, Int) {
    var i = start
    var digits = ""
    func isDigit(_ k: Int) -> Bool { k < end && chars[k].isASCII && chars[k].isNumber }
    var groupsSeen = false
    var lead = 0
    while isDigit(i) {
      digits.append(chars[i])
      i += 1
      lead += 1
    }
    while i < end, chars[i] == "," {
      guard lead >= 1, lead <= 3 || groupsSeen, isDigit(i + 1), isDigit(i + 2), isDigit(i + 3),
        !isDigit(i + 4)
      else { throw CalculatorError.number }
      if !groupsSeen, lead > 3 { throw CalculatorError.number }
      digits.append(contentsOf: [chars[i + 1], chars[i + 2], chars[i + 3]])
      i += 4
      groupsSeen = true
    }
    if i < end, chars[i] == "." {
      i += 1
      guard isDigit(i) else { throw CalculatorError.number }
      digits.append(".")
      while isDigit(i) {
        digits.append(chars[i])
        i += 1
      }
      // `1.2.3` and `1,000.5,5` are not numbers.
      if i < end, chars[i] == "." || chars[i] == "," { throw CalculatorError.number }
    } else if digits.isEmpty {
      throw CalculatorError.number
    }
    guard digits.filter(\.isNumber).count <= maxDigits else { throw CalculatorError.overflow }
    guard let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else {
      throw CalculatorError.number
    }
    return (value, i)
  }
}

// expression := term (("+" | "-") term)*
// term       := unary (("*" | "/") unary | implicit)*   implicit: before "(" or "√", or a number after ")"
// unary      := ("-" | "+") unary | power
// power      := postfix ("^" unary)?                     right associative, binds tighter than unary minus
// postfix    := primary "%"*
// primary    := number | "(" expression ")" | "√" primary
struct Parser {
  let tokens: [Token]
  private var index = 0
  private var endedWithClose = false
  private var depth = 0

  init(tokens: [Token]) { self.tokens = tokens }

  mutating func parse() throws -> ExpressionNode {
    let node = try expression()
    guard index == tokens.count else { throw CalculatorError.syntax }
    return node
  }

  private var peek: Token? { index < tokens.count ? tokens[index] : nil }

  private mutating func expression() throws -> ExpressionNode {
    var left = try term()
    while let token = peek, token == .plus || token == .minus {
      index += 1
      let right = try term()
      left = token == .plus ? .add(left, right) : .subtract(left, right)
    }
    return left
  }

  private mutating func term() throws -> ExpressionNode {
    var left = try unary()
    while let token = peek {
      switch token {
      case .times, .divide:
        index += 1
        let right = try unary()
        left = token == .times ? .multiply(left, right) : .divide(left, right)
      case .open, .root:
        left = .multiply(left, try unary())
      case .number where endedWithClose:
        left = .multiply(left, try unary())
      default: return left
      }
    }
    return left
  }

  private mutating func unary() throws -> ExpressionNode {
    switch peek {
    case .minus:
      index += 1
      return .negate(try unary())
    case .plus:
      index += 1
      return try unary()
    default: return try power()
    }
  }

  private mutating func power() throws -> ExpressionNode {
    let base = try postfix()
    guard peek == .power else { return base }
    index += 1
    return .power(base, try unary())
  }

  private mutating func postfix() throws -> ExpressionNode {
    var node = try primary()
    while peek == .percent {
      index += 1
      node = .percent(node)
      endedWithClose = false
    }
    return node
  }

  private mutating func primary() throws -> ExpressionNode {
    guard let token = peek else { throw CalculatorError.syntax }
    index += 1
    switch token {
    case .number(let value):
      endedWithClose = false
      return .number(value)
    case .open:
      depth += 1
      // Nesting this deep is not a calculation but a stroke gone wrong.
      guard depth <= 40 else { throw CalculatorError.syntax }
      let inner = try expression()
      depth -= 1
      guard peek == .close else { throw CalculatorError.syntax }
      index += 1
      endedWithClose = true
      return inner
    case .root:
      return .root(try primary())
    default: throw CalculatorError.syntax
    }
  }
}

enum Evaluator {
  static func value(of node: ExpressionNode) throws -> ExpressionValue {
    switch node {
    case .number(let v): return ExpressionValue(v)
    case .negate(let n):
      let v = try value(of: n)
      return ExpressionValue(-v.value, exact: v.exact)
    case .add(let l, let r):
      // `a + b%` is b percent of a, like the iPad calculator: 50 + 10% is 55.
      if case .percent(let p) = r { return try combine(l, relative: p, +1) }
      return try apply(NSDecimalAdd, try value(of: l), try value(of: r))
    case .subtract(let l, let r):
      if case .percent(let p) = r { return try combine(l, relative: p, -1) }
      return try apply(NSDecimalSubtract, try value(of: l), try value(of: r))
    case .multiply(let l, let r):
      return try apply(NSDecimalMultiply, try value(of: l), try value(of: r))
    case .divide(let l, let r):
      let divisor = try value(of: r)
      guard divisor.value != 0 else { throw CalculatorError.divisionByZero }
      return try apply(NSDecimalDivide, try value(of: l), divisor)
    case .percent(let n):
      return try apply(NSDecimalDivide, try value(of: n), ExpressionValue(100))
    case .power(let b, let e):
      return try power(try value(of: b), try value(of: e))
    case .root(let n):
      return try squareRoot(try value(of: n))
    }
  }

  private typealias Operation = (
    UnsafeMutablePointer<Decimal>, UnsafePointer<Decimal>, UnsafePointer<Decimal>,
    NSDecimalNumber.RoundingMode
  ) -> NSDecimalNumber.CalculationError

  private static func apply(
    _ operation: Operation, _ a: ExpressionValue, _ b: ExpressionValue
  ) throws -> ExpressionValue {
    var left = a.value
    var right = b.value
    var out = Decimal()
    let status = operation(&out, &left, &right, .plain)
    switch status {
    case .noError: return ExpressionValue(out, exact: a.exact && b.exact)
    case .lossOfPrecision, .underflow: return ExpressionValue(out, exact: false)
    case .overflow: throw CalculatorError.overflow
    case .divideByZero: throw CalculatorError.divisionByZero
    @unknown default: throw CalculatorError.overflow
    }
  }

  private static func combine(
    _ base: ExpressionNode, relative percent: ExpressionNode, _ sign: Decimal
  ) throws -> ExpressionValue {
    let a = try value(of: base)
    let p = try value(of: percent)
    let share = try apply(NSDecimalDivide, try apply(NSDecimalMultiply, a, p), ExpressionValue(100))
    return try apply(sign > 0 ? NSDecimalAdd : NSDecimalSubtract, a, share)
  }

  private static let maxExponent = 10_000

  private static func power(_ base: ExpressionValue, _ exponent: ExpressionValue) throws
    -> ExpressionValue
  {
    var whole = Decimal()
    var e = exponent.value
    NSDecimalRound(&whole, &e, 0, .plain)
    if whole == exponent.value {
      let n = NSDecimalNumber(decimal: whole).intValue
      guard abs(n) <= maxExponent else { throw CalculatorError.overflow }
      if base.value == 0 {
        if n == 0 { throw CalculatorError.undefined }
        if n < 0 { throw CalculatorError.divisionByZero }
        return ExpressionValue(0, exact: base.exact)
      }
      var b = base.value
      var out = Decimal()
      let status = NSDecimalPower(&out, &b, abs(n), .plain)
      if status == .overflow { throw CalculatorError.overflow }
      let result = ExpressionValue(out, exact: base.exact && exponent.exact && status == .noError)
      if n < 0 { return try apply(NSDecimalDivide, ExpressionValue(1), result) }
      return result
    }
    // A fractional exponent leaves exact arithmetic: x^(1/2), 4^0.5.
    let b = NSDecimalNumber(decimal: base.value).doubleValue
    let x = NSDecimalNumber(decimal: exponent.value).doubleValue
    guard b > 0 else { throw CalculatorError.undefined }
    return try fromDouble(pow(b, x))
  }

  private static func squareRoot(_ n: ExpressionValue) throws -> ExpressionValue {
    guard n.value >= 0 else { throw CalculatorError.undefined }
    if n.value == 0 { return ExpressionValue(0) }
    let root = try fromDouble(NSDecimalNumber(decimal: n.value).doubleValue.squareRoot())
    // A whole root such as √144 is exact: squaring it gives the radicand back.
    let squared = try apply(NSDecimalMultiply, root, root)
    return ExpressionValue(root.value, exact: n.exact && squared.value == n.value)
  }

  private static func fromDouble(_ d: Double) throws -> ExpressionValue {
    guard d.isFinite else { throw CalculatorError.overflow }
    // 15 digits is what a Double certainly holds; more would show its binary noise.
    let text = String(format: "%.15g", d)
    guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
      throw CalculatorError.overflow
    }
    return ExpressionValue(value, exact: false)
  }
}

extension ExpressionValue {
  // What is written on the page: up to 10 significant digits, a point for decimals, no grouping.
  // `approximate` is set when the shown number is not the exact value, so the page can say so.
  public func formatted(significantDigits: Int = 10) -> FormattedResult {
    var number = value
    if number == 0 { return FormattedResult(text: "0", approximate: false) }
    let negative = number < 0
    var magnitude = negative ? -number : number
    let digitsBefore = Self.decimalExponent(of: magnitude)
    var rounded = Decimal()
    NSDecimalRound(&rounded, &magnitude, significantDigits - 1 - digitsBefore, .plain)
    let approximate = !exact || rounded != magnitude
    let sign = negative ? "-" : ""
    // Very large or very small numbers are written in scientific notation, which a text box can hold.
    if digitsBefore >= 15 || digitsBefore < -9 {
      var scaled = Decimal()
      var base = rounded
      let divisor = Decimal(sign: .plus, exponent: digitsBefore, significand: 1)
      var d = divisor
      _ = NSDecimalDivide(&scaled, &base, &d, .plain)
      let text = Self.plain(scaled)
      return FormattedResult(
        text: "\(sign)\(text)e\(digitsBefore < 0 ? "-" : "+")\(abs(digitsBefore))",
        approximate: approximate)
    }
    number = rounded
    return FormattedResult(text: sign + Self.plain(number), approximate: approximate)
  }

  // The power of ten of the leading digit: 1234 is 3, 0.05 is -2.
  private static func decimalExponent(of positive: Decimal) -> Int {
    let d = NSDecimalNumber(decimal: positive).doubleValue
    var e = Int(floor(log10(d)))
    // log10 can land one off at exact powers of ten; settle it with Decimal comparisons.
    if positive >= Decimal(sign: .plus, exponent: e + 1, significand: 1) { e += 1 }
    if positive < Decimal(sign: .plus, exponent: e, significand: 1) { e -= 1 }
    return e
  }

  // Decimal's description keeps trailing zeros of a rounded value out and never uses exponents
  // for numbers of this size.
  private static func plain(_ d: Decimal) -> String {
    var text = NSDecimalNumber(decimal: d).description(withLocale: Locale(identifier: "en_US_POSIX"))
    if text.contains("e") || text.contains("E") { text = "\(d)" }
    return text
  }
}
