import Foundation
import Testing

@testable import NoteCraftCore

private func sample(_ label: String, kind: CorpusSample.Kind = .symbol) -> CorpusSample {
  var rng = SeededGenerator(seed: 5)
  let glyph = StockGlyphs.all.first { $0.symbol == label } ?? StockGlyphs.all[0]
  return CorpusSample(
    kind: kind, label: label,
    strokes: StockGlyphs.perturbed(glyph.strokes, strength: 1, using: &rng).map { $0.map { Point($0.x * 40, $0.y * 40) } })
}

@Test func aCorpusSurvivesASave() throws {
  let corpus = Corpus(samples: [sample("7"), sample("+"), sample("12+3", kind: .calculation)])
  let back = try Corpus.decoded(from: corpus.encoded())
  #expect(back == corpus)
  #expect(back.symbolCount == 2 && back.calculationCount == 1)
}

@Test func aDamagedSampleIsDroppedAndTheRestKept() throws {
  var corpus = Corpus(samples: [sample("7"), sample("8")])
  corpus.samples.append(CorpusSample(kind: .symbol, label: "9", strokes: []))
  corpus.samples.append(CorpusSample(kind: .symbol, label: "", strokes: [[Point(0, 0)]]))
  let back = try Corpus.decoded(from: corpus.encoded())
  #expect(back.samples.map(\.label) == ["7", "8"])
}

@Test func onlyTheSymbolsThePenReadsBecomeTemplates() {
  let corpus = Corpus(samples: [sample("7"), sample("7"), sample("%"), sample("1+2", kind: .calculation)])
  #expect(corpus.templates().map(\.symbol) == ["7", "7"])
  #expect(corpus.counts() == ["7": 2, "%": 1])
}

@Test func aSampleOfTheReadersHandChangesWhatIsRead() throws {
  // A "7" that is a plain diagonal stroke: no stock shape. Without the sample it is something else.
  let diagonal: [[Point]] = [(0...10).map { Point(Double($0) * 1.5, Double($0) * 4) }]
  let stock = Corpus().classifier().classify(diagonal)
  #expect(stock?.symbol != "7")
  let corpus = Corpus(samples: [CorpusSample(kind: .symbol, label: "7", strokes: diagonal)])
  let mine = try #require(corpus.classifier().classify(diagonal))
  #expect(mine.symbol == "7")
}

@Test func theTrainerAsksForEverySymbolWithoutRepeating() {
  for seed in 0..<20 {
    let round = TrainingPrompts.symbolRound(seed: UInt64(seed))
    #expect(Set(round) == Set(Corpus.symbols))
    #expect(round.count == Corpus.symbols.count)
    #expect(zip(round, round.dropFirst()).allSatisfy { $0 != $1 })
  }
}

@Test func theCalculationsItAsksForAreCalculations() {
  for seed in 0..<200 {
    let text = TrainingPrompts.calculation(seed: UInt64(seed))
    if case .failure(let error) = Expression.evaluate(text) {
      #expect(error == .divisionByZero || error == .undefined, "\(text) is not a calculation")
    }
  }
  #expect(TrainingPrompts.shown("12*3/4") == "12×3÷4")
}
