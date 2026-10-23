import Foundation

// Width of the pencil line. A graphite tip draws a slightly wider line the harder it is pressed and
// a much wider, softer one when it is laid on its side, so pressure and tilt both widen the line.
// Like every width model it is causal, so live ink matches the stroke that is saved.
public enum PencilInk {
  // The model state is shared with the fountain pen; only `width` and `count` are used here.
  public static func advance(_ state: inout FountainInk.State, sample: Sample, base: Double)
    -> Double
  {
    var scale = 1.0
    // Fingers and mice report a constant pressure of 1, which says nothing about force.
    if sample.pressure < 0.999 {
      let eased = min(1, max(0, sample.pressure)).squareRoot()
      // Force builds over the first samples of a touch; letting it in gradually keeps the line from
      // starting thin and swelling.
      let engaged = min(1, Double(state.count) / 6)
      scale *= 1 + (0.7 + 0.6 * eased - 1) * engaged
    }
    // Altitude is the pencil's angle to the screen: pi/2 upright, towards 0 lying flat.
    let side = 1 - sin(min(Double.pi / 2, max(0.15, sample.altitude)))
    scale *= 1 + 1.1 * side
    let target = base * scale
    state.width = state.count == 0 ? target : state.width + (target - state.width) * 0.5
    state.count += 1
    state.last = sample
    return max(base * 0.35, state.width)
  }

  public static func widths(for samples: [Sample], base: Double, finished: Bool = true) -> [Double] {
    var state = FountainInk.State()
    var result = samples.map { advance(&state, sample: $0, base: base) }
    if finished, result.count > 3 {
      let reach = min(4, result.count - 1)
      for offset in 0..<reach {
        let index = result.count - 1 - offset
        result[index] *= 0.7 + 0.3 * Double(offset) / Double(reach)
      }
    }
    return result
  }
}
