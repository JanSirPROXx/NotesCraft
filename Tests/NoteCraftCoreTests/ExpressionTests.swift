import Foundation
import Testing

@testable import NoteCraftCore

private func text(_ expression: String) -> String? {
  guard case .success(let value) = Expression.evaluate(expression) else { return nil }
  return value.formatted().text
}
private func failure(_ expression: String) -> CalculatorError? {
  if case .failure(let error) = Expression.evaluate(expression) { return error }
  return nil
}

@Test(arguments: [
  ("2+2", "4"), ("2+2=", "4"), ("12×3+4", "40"), ("12*3+4", "40"), ("2+3*4", "14"),
  ("(2+3)*4", "20"), ("10-2-3", "5"), ("100/4/5", "5"), ("2^3^2", "512"), ("-2^2", "-4"),
  ("(-2)^2", "4"), ("2*-3", "-6"), ("2--3", "5"), ("10÷4", "2.5"), ("7−10", "-3"),
  ("0.1+0.2", "0.3"), (".5+.5", "1"), ("1,000+1", "1001"), ("12,345,678/2", "6172839"),
  ("2(3+4)", "14"), ("(1+2)3", "9"), ("2√9", "6"), ("√144", "12"), ("√(9+16)", "5"),
  ("50+10%", "55"), ("50-10%", "45"), ("200*10%", "20"), ("10%", "0.1"), ("2^-1", "0.5"),
  ("2^0", "1"), ("3x4", "12"), (" 8 / 2 ", "4"), ("1000000*1000000", "1000000000000"),
])
func evaluatesArithmetic(_ expression: String, _ expected: String) {
  #expect(text(expression) == expected)
}

@Test(arguments: [
  ("1/3", "0.3333333333"), ("2/3", "0.6666666667"), ("√2", "1.414213562"),
  ("100/7", "14.28571429"), ("2^0.5", "1.414213562"),
])
func roundedResultsAreMarkedApproximate(_ expression: String, _ expected: String) {
  guard case .success(let value) = Expression.evaluate(expression) else {
    Issue.record("\(expression) failed")
    return
  }
  let shown = value.formatted()
  #expect(shown.text == expected)
  #expect(shown.approximate)
}

@Test func exactResultsAreNotMarkedApproximate() {
  for expression in ["1/4", "0.1+0.2", "√144", "2^10", "5/2"] {
    guard case .success(let value) = Expression.evaluate(expression) else {
      Issue.record("\(expression) failed")
      continue
    }
    #expect(!value.formatted().approximate, "\(expression)")
  }
}

@Test(arguments: [
  ("1/0", CalculatorError.divisionByZero), ("5/(2-2)", .divisionByZero), ("0^-1", .divisionByZero),
  ("0^0", .undefined), ("√(0-4)", .undefined), ("(-8)^0.5", .undefined),
  ("", .empty), ("=", .empty), ("2+", .syntax), ("*3", .syntax), ("(2+3", .syntax),
  ("2+3)", .syntax), ("2 3", .syntax), ("2++", .syntax), ("abc", .syntax), ("()", .syntax),
  ("1,5", .number), ("5.", .number), ("1.2.3", .number), ("1,00", .number), ("1,0000", .number),
  ("1234,567", .number), ("1,000,00", .number), (",5", .number),
  ("9^9999", .overflow), ("9^99999", .overflow),
])
func rejectsWhatCannotBeReadOrDefined(_ expression: String, _ error: CalculatorError) {
  #expect(failure(expression) == error, "\(expression)")
}

@Test func tooManyDigitsOrDeepNestingIsRefusedNotRounded() {
  #expect(failure(String(repeating: "9", count: 31) + "+1") == .overflow)
  #expect(failure(String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100)) == .syntax)
}

@Test func largeAndSmallNumbersUseScientificNotation() {
  #expect(text("10^20") == "1e+20")
  #expect(text("12345678901234567890*10") == "1.234567890e+20" || text("12345678901234567890*10") == "1.23456789e+20")
  #expect(text("1/10^12") == "1e-12")
}

@Test func percentOnlyReadsRelativeNextToPlusAndMinus() {
  #expect(text("200+50%") == "300")
  #expect(text("200*50%") == "100")
  #expect(text("50%+200") == "200.5")
}

@Test func garbageNeverCrashes() {
  let alphabet = Array("0123456789+-*/^().,%√×÷= x")
  var generator = SystemRandomNumberGenerator()
  for _ in 0..<5000 {
    let length = Int.random(in: 1...14, using: &generator)
    let expression = String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    _ = Expression.evaluate(expression)
  }
}
