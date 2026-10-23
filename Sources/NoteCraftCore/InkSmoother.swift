import Foundation

// Steadies the pen path with the 1 € filter (Casiez, Roussel and Vogel, CHI 2012): a first-order
// low-pass whose cutoff rises with pen speed. Digitiser noise and tremor are only visible while the
// pen is slow, and that is where the cutoff is low; a quick stroke gets a cutoff high enough that
// the lag stays well under a point. A fixed-factor average cannot do both, and it also depends on
// how often samples arrive (a finger reports at 60 Hz, a Pencil at 240 Hz), where this works on the
// time between them.
public struct InkSmoother: Sendable {
  public struct Parameters: Sendable, Equatable {
    // Cutoff in Hz with the pen at rest.
    public var minCutoff: Double
    // Hz of cutoff gained per screen point per second of pen speed. The lag of a first-order filter
    // at constant speed is speed / (2π · cutoff), so a cutoff that grows with speed keeps it flat.
    public var beta: Double
    // Cutoff of the filter that smooths the speed estimate itself. The derivative of a noisy path is
    // far noisier than the path, so a high value lets that noise raise the cutoff and un-smooth
    // exactly the slow strokes; a low one delays the response to a sudden flick. 10 Hz keeps the
    // peak lag of a flick from rest near 1.5 pt and still takes out most of the noise.
    public var speedCutoff = 10.0

    public init(minCutoff: Double, beta: Double) {
      self.minCutoff = minCutoff
      self.beta = beta
    }

    // `stabilization` is the pen setting, 0...1. At 0 only noise is taken out (about half a point
    // of lag at any speed); at 1 the ink trails the tip by several points and runs smooth.
    public init(stabilization: Double) {
      let s = min(1, max(0, stabilization))
      self.init(minCutoff: 4 * pow(0.15, s), beta: 0.25 * pow(0.1, s))
    }
  }

  public let parameters: Parameters
  // Screen points per unit of the coordinates fed in, so the parameters mean the same thing at any
  // zoom: at 6× a jitter of 0.1 pt in the document is already 0.6 pt under the finger.
  private let scale: Double
  private var last: (raw: Point, time: TimeInterval)?
  private var value = Point(0, 0)
  private var velocity: (x: Double, y: Double)?

  public init(parameters: Parameters, scale: Double = 1) {
    self.parameters = parameters
    self.scale = max(0.0001, scale)
  }

  // Samples closer than this in time are treated as simultaneous, so a repeated timestamp cannot
  // divide by zero.
  private static let minimumInterval = 0.0005

  private static func weight(cutoff: Double, interval: Double) -> Double {
    let tau = 1 / (2 * Double.pi * cutoff)
    return 1 / (1 + tau / interval)
  }

  public mutating func advance(_ raw: Point, at time: TimeInterval) -> Point {
    guard let previous = last else {
      last = (raw, time)
      value = raw
      return raw
    }
    let dt = max(Self.minimumInterval, time - previous.time)
    let vx = (raw.x - previous.raw.x) * scale / dt
    let vy = (raw.y - previous.raw.y) * scale / dt
    // The first speed reading is taken as it is: starting from rest would hold the opening of
    // every stroke back at the low cutoff until the estimate caught up.
    if let current = velocity {
      let k = Self.weight(cutoff: parameters.speedCutoff, interval: dt)
      velocity = (current.x + k * (vx - current.x), current.y + k * (vy - current.y))
    } else {
      velocity = (vx, vy)
    }
    let speed = hypot(velocity?.x ?? 0, velocity?.y ?? 0)
    let k = Self.weight(cutoff: parameters.minCutoff + parameters.beta * speed, interval: dt)
    value = Point(value.x + k * (raw.x - value.x), value.y + k * (raw.y - value.y))
    last = (raw, time)
    return value
  }
}
