import Foundation

// The Pencil reports force and tilt over a different radio than the touch position, so UIKit first
// delivers an estimate and the measured value some milliseconds later, tagged with an update index.
// Ink that has already been baked cannot be reworked, so it may only advance as far as the first
// sample whose measurement is still on its way.
public struct PendingEstimates: Sendable {
  // Update index → index of the sample it belongs to.
  private var waiting: [Int: Int] = [:]
  // An update that never arrives (a device that reports nothing later) must not hold the ink back
  // for ever; after this many newer samples the estimate is taken as final.
  static let patience = 24

  public init() {}

  public var isEmpty: Bool { waiting.isEmpty }
  // The oldest sample still expecting a measurement.
  public var earliest: Int? { waiting.values.min() }

  public mutating func expect(updateIndex: Int, forSample sample: Int) {
    waiting[updateIndex] = sample
  }

  // The sample an update belongs to, or nil for one this stroke does not know (a late update of the
  // previous stroke). `complete` is false while further refinements are still due.
  public mutating func receive(updateIndex: Int, complete: Bool) -> Int? {
    guard let sample = waiting[updateIndex] else { return nil }
    if complete { waiting[updateIndex] = nil }
    return sample
  }

  public mutating func expire(newest sample: Int) {
    waiting = waiting.filter { sample - $0.value <= Self.patience }
  }

  public mutating func removeAll() { waiting.removeAll(keepingCapacity: true) }
}
