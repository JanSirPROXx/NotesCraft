import Foundation

// The pretrained network as a source of symbols for the line reader, next to the template matcher
// that learns from the reader's own hand. Both keep the rule the pen is built on: a wrong reading
// is never presented as certain. Here that means a symbol is certain only when the network puts
// nearly all of its belief on it, and "not a symbol" counts as a rival like any other symbol.
public struct NeuralSymbolClassifier: SymbolClassifying {
  private let net: SymbolNet

  public init(net: SymbolNet = .bundled) { self.net = net }

  // Below this a group is not taken as a symbol at all.
  static let leastBelief = 0.5
  // Another symbol that holds at least this much belief stays a possible reading.
  static let plausible = 0.12
  // A symbol is certain when the first is this far ahead of the second (or of "not a symbol"):
  // none at all below `unsureGap`, fully certain from `sureGap` on.
  static let unsureGap = 0.4
  static let sureGap = 0.8
  // Cost of a symbol: the surprise of the network, in nats, times this.
  static let costPerNat = 0.05

  // A symbol costs its surprise plus this, so a clean symbol beats two halves that are each
  // a little less sure, and a symbol the network doubts loses to two it is sure of.
  public var groupCost: Double { 0.012 }
  // At least four out of five of the belief.
  public var goodFit: Double { Self.costPerNat * -log(0.8) }
  // About a quarter of the belief of one symbol.
  public var rivalSlack: Double { 0.05 }
  // The network refuses what is two symbols, so only what cannot be one symbol at all is kept from it.
  public var widestGroup: Double { 1.15 }

  public func candidates(_ strokes: [[Point]]) -> SymbolCandidates? {
    guard let picture = SymbolRaster.render(strokes) else { return nil }
    let p = net.probabilities(picture).map(Double.init)
    let reject = p[SymbolNet.rejectClass]
    let order = (0..<SymbolNet.symbols.count).sorted { p[$0] > p[$1] }
    let top = p[order[0]]
    guard top >= Self.leastBelief, top > reject else { return nil }

    func candidate(_ index: Int) -> SymbolCandidate {
      let symbol = SymbolNet.symbols[index]
      return SymbolCandidate(
        symbol: symbol == "÷" ? "/" : symbol, cost: Self.costPerNat * -log(max(p[index], 1e-4)))
    }
    var options = [candidate(order[0])]
    for index in order.dropFirst().prefix(2) where p[index] >= Self.plausible {
      options.append(candidate(index))
    }
    let rival = max(p[order[1]], reject)
    let sure = min(1, max(0, (top - rival - Self.unsureGap) / (Self.sureGap - Self.unsureGap)))
    return SymbolCandidates(options: options, margin: sure * LineReader.certainMargin)
  }
}

// Reads calculations with the pretrained network. Needs no samples of the reader's own writing.
public struct PretrainedRecognizer: ExpressionRecognizing {
  public var version = 2
  private let reader: LineReader

  public init(net: SymbolNet = .bundled) {
    reader = LineReader(classifier: NeuralSymbolClassifier(net: net))
  }

  public func read(_ gathering: Gathering) async -> Reading? { reader.read(gathering) }
}
