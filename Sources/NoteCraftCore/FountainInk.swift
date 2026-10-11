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
    state.spacing += (distance - state.spacing) * 0.25
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
      scale *= max(0.25, 1 + tip.pressure * 3 * (eased - 0.45))
    }
    let thinning = 0.2 + 0.6 * tip.sharpness
    scale *= 1 - thinning * min(1, state.spacing / 6)
    if tip.flatness > 0, state.dx != 0 || state.dy != 0 {
      let side = abs(sin(atan2(state.dy, state.dx) - nibAngle))
      scale *= (1 - tip.flatness) + tip.flatness * (0.2 + 0.8 * side)
    }
    var target = base * scale
    let entry = startRatio(tip)
    let ramp = min(1, Double(state.count) / 5)
    target *= entry + (1 - entry) * ramp
    state.width += (target - state.width) * 0.35
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

  private static func startRatio(_ tip: PenTip) -> Double { 0.6 - 0.3 * tip.sharpness }
}
