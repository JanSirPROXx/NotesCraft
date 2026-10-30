import Foundation

// What the reader has written for the calculator pen, kept so that it can be read better: each
// sample is strokes with the text they were meant to say. A symbol sample (one "7") becomes a
// template at once; a calculation sample ("(9+2)/11") is what the recognizer is tested against
// and what a later, trained model learns from. Samples live on the device and leave it only when
// the reader shares the file.

public struct CorpusSample: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case symbol, calculation }

  public var id: UUID
  public var kind: Kind
  // The symbol ("7", "+", "-", "*", "÷", "(", ")") or the calculation in the notation `Expression` reads.
  public var label: String
  // In page points, as written; shape and layout both survive.
  public var strokes: [[Point]]
  public var created: Date
  public init(
    id: UUID = UUID(), kind: Kind, label: String, strokes: [[Point]], created: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.strokes = strokes
    // Whole seconds, which is what the file keeps, so a sample is the same after a save.
    self.created = Date(timeIntervalSince1970: created.timeIntervalSince1970.rounded())
  }
}

public struct Corpus: Codable, Equatable, Sendable {
  public var version = 1
  public var samples: [CorpusSample] = []
  public init(samples: [CorpusSample] = []) { self.samples = samples }

  // The symbols the pen reads and the trainer asks for. "*" is the times sign and "÷" the obelus;
  // a fraction bar is a "-", and the point is told by its size, so it needs no samples.
  public static let symbols = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "-", "*", "÷", "(", ")"]

  public var symbolCount: Int { samples.filter { $0.kind == .symbol }.count }
  public var calculationCount: Int { samples.filter { $0.kind == .calculation }.count }

  // How many of each symbol have been written.
  public func counts() -> [String: Int] {
    var out: [String: Int] = [:]
    for sample in samples where sample.kind == .symbol { out[sample.label, default: 0] += 1 }
    return out
  }

  public func templates() -> [SymbolTemplate] {
    samples.compactMap { sample in
      guard sample.kind == .symbol, Self.symbols.contains(sample.label) else { return nil }
      return StockTemplates.template(symbol: sample.label, strokes: sample.strokes)
    }
  }

  // What the recognizer reads with: the stock shapes, and every symbol the reader has written.
  public func classifier() -> SymbolClassifier {
    SymbolClassifier(templates: StockTemplates.make() + templates())
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }

  public static func decoded(from data: Data) throws -> Corpus {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var corpus = try decoder.decode(Corpus.self, from: data)
    // A sample that cannot be a template or a test is dropped rather than failing the whole file.
    corpus.samples.removeAll { $0.strokes.isEmpty || $0.strokes.contains { $0.isEmpty } || $0.label.isEmpty }
    return corpus
  }
}

// What the trainer asks the reader to write.
public enum TrainingPrompts {
  // A round: every symbol once, in an order that changes from round to round, so that two of the
  // same are never asked for after each other.
  public static func symbolRound(seed: UInt64) -> [String] {
    var rng = SeededGenerator(seed: seed)
    var round = Corpus.symbols.shuffled(using: &rng)
    return round.indices.dropFirst().contains(where: { round[$0] == round[$0 - 1] })
      ? round.reversed() : round
  }

  // Calculations as they are written in the notebook, in the notation the pen reads: whole
  // numbers, the four operations, and now and then a fraction.
  public static func calculation(seed: UInt64) -> String {
    var rng = SeededGenerator(seed: seed)
    func number() -> String {
      String(Int.random(in: 1...(Bool.random(using: &rng) ? 9 : 99), using: &rng))
    }
    if Int.random(in: 0..<4, using: &rng) == 0 {
      let top = Bool.random(using: &rng) ? "\(number())+\(number())" : number()
      return "(\(top))/(\(number()))"
    }
    var text = number()
    for _ in 0..<Int.random(in: 1...2, using: &rng) {
      text += ["+", "-", "*", "/"].randomElement(using: &rng)! + number()
    }
    return text
  }

  // How a label is shown to the reader: × and ÷, as they are written.
  public static func shown(_ label: String) -> String {
    label.replacingOccurrences(of: "*", with: "×").replacingOccurrences(of: "/", with: "÷")
  }
}
