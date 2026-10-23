import Foundation

// How the width of a pen with a width model follows the pen. Every model is causal: a width depends
// only on the samples up to it, so live ink drawn while the pen moves is the stroke that is saved.
public enum WidthModel: Sendable, Equatable {
  case fountain(PenTip)

  public init?(style: PenStyle, tip: PenTip) {
    switch style {
    case .fountain: self = .fountain(tip)
    case .ballpoint, .brush: return nil
    }
  }

  public func advance(_ state: inout FountainInk.State, sample: Sample, base: Double) -> Double {
    switch self {
    case .fountain(let tip): FountainInk.advance(&state, sample: sample, base: base, tip: tip)
    }
  }

  public func widths(for samples: [Sample], base: Double, finished: Bool = true) -> [Double] {
    switch self {
    case .fountain(let tip):
      FountainInk.widths(for: samples, base: base, tip: tip, finished: finished)
    }
  }
}

// The widths of the stroke being written, with the model state saved after each sample. When a
// measured force arrives for an earlier sample, only the widths from there on are worked out again,
// from the saved state, instead of replaying the whole stroke.
public struct WidthTrack: Sendable {
  public private(set) var widths: [Double] = []
  private var states: [FountainInk.State] = []

  public init() {}

  // The state after the newest sample, for widths of samples that are only predicted.
  public var state: FountainInk.State { states.last ?? FountainInk.State() }

  public mutating func append(_ sample: Sample, base: Double, model: WidthModel) {
    var next = state
    widths.append(model.advance(&next, sample: sample, base: base))
    states.append(next)
  }

  public mutating func revise(
    from index: Int, samples: [Sample], base: Double, model: WidthModel
  ) {
    guard index >= 0, index < widths.count, samples.count == widths.count else { return }
    var next = index > 0 ? states[index - 1] : FountainInk.State()
    for i in index..<samples.count {
      widths[i] = model.advance(&next, sample: samples[i], base: base)
      states[i] = next
    }
  }

  public mutating func removeAll() {
    widths.removeAll(keepingCapacity: true)
    states.removeAll(keepingCapacity: true)
  }
}
