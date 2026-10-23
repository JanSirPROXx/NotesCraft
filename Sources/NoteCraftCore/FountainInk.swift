import Foundation

// Width model of the fountain pen. Widths are produced by a causal filter (each value depends
// only on samples up to it) so live ink, drawn incrementally while the Pencil moves, matches the
// committed stroke except for the end taper, which needs to know where the stroke ends.
public enum FountainInk {
  public struct State: Sendable {
    var last: Sample?
    var spacing = 0.0
    var width = 0.0
    var count = 0
    var dx = 0.0
    var dy = 0.0
    public init() {}
  }

  // Nib angle for the flatness setting, measured in the page's y-down coordinates.
  static let nibAngle = -Double.pi / 4

  public static func advance(
    _ state: inout State, sample: Sample, base: Double, tip: PenTip
  ) -> Double {
    guard let last = state.last else {
      state.last = sample
      state.count = 1
      state.width = base * startRatio(tip)
      return state.width
    }
    let ddx = sample.point.x - last.point.x
    let ddy = sample.point.y - last.point.y
    let distance = hypot(ddx, ddy)
    // Samples arrive at a fixed rate, so spacing stands in for speed.
    state.spacing += (distance - state.spacing) * 0.5
    if distance > 0.05 {
      let nx = state.dx * 0.7 + ddx / distance * 0.3
      let ny = state.dy * 0.7 + ddy / distance * 0.3
      let length = max(0.0001, hypot(nx, ny))
      state.dx = nx / length
      state.dy = ny / length
    }
    var scale = 1.0
    // Fingers and mice report constant pressure 1; treating that as a real reading would
    // fatten every such stroke.
    if sample.pressure < 0.999 {
      let eased = min(1, max(0, sample.pressure)).squareRoot()
      // Pencil force starts near zero and builds over the first few samples; weighting it in
      // gradually keeps the stroke from starting hair-thin and then visibly swelling.
      let engaged = min(1, Double(state.count) / 8)
      scale *= max(0.25, 1 + tip.pressure * 3 * (eased - 0.45) * engaged)
    }
    let thinning = 0.2 + 0.6 * tip.sharpness
    scale *= 1 - thinning * min(1, state.spacing / 6)
    if tip.flatness > 0, state.dx != 0 || state.dy != 0 {
      let side = abs(sin(atan2(state.dy, state.dx) - nibAngle))
      scale *= (1 - tip.flatness) + tip.flatness * (0.2 + 0.8 * side)
    }
    var target = base * scale
    let entry = startRatio(tip)
    let ramp = min(1, Double(state.count) / 3)
    target *= entry + (1 - entry) * ramp
    state.width += (target - state.width) * 0.6
    state.count += 1
    state.last = sample
    return max(base * 0.2, state.width)
  }

  public static func widths(
    for samples: [Sample], base: Double, tip: PenTip, finished: Bool = true
  ) -> [Double] {
    var state = State()
    var result = samples.map { advance(&state, sample: $0, base: base, tip: tip) }
    if finished, result.count > 3 {
      let reach = min(6, result.count - 1)
      let floor = 0.5 - 0.35 * tip.sharpness
      for offset in 0..<reach {
        let index = result.count - 1 - offset
        result[index] *= floor + (1 - floor) * Double(offset) / Double(reach)
      }
    }
    return result
  }

  private static func startRatio(_ tip: PenTip) -> Double { 0.85 - 0.25 * tip.sharpness }
}

// The fountain widths of the stroke being written, with the filter state saved after each sample.
// When a measured force arrives for an earlier sample, only the widths from there on are worked out
// again, from the saved state, instead of replaying the whole stroke.
public struct FountainTrack: Sendable {
  public private(set) var widths: [Double] = []
  private var states: [FountainInk.State] = []

  public init() {}

  // The state after the newest sample, for widths of samples that are only predicted.
  public var state: FountainInk.State { states.last ?? FountainInk.State() }

  public mutating func append(_ sample: Sample, base: Double, tip: PenTip) {
    var next = state
    widths.append(FountainInk.advance(&next, sample: sample, base: base, tip: tip))
    states.append(next)
  }

  public mutating func revise(from index: Int, samples: [Sample], base: Double, tip: PenTip) {
    guard index >= 0, index < widths.count, samples.count == widths.count else { return }
    var next = index > 0 ? states[index - 1] : FountainInk.State()
    for i in index..<samples.count {
      widths[i] = FountainInk.advance(&next, sample: samples[i], base: base, tip: tip)
      states[i] = next
    }
  }

  public mutating func removeAll() {
    widths.removeAll(keepingCapacity: true)
    states.removeAll(keepingCapacity: true)
  }
}
