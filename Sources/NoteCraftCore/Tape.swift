import Foundation

// Tape hides what is under it until it is tapped: cover the answer, ask yourself, peel it back.
// A strip is stored on an ordinary `pen` stroke (`Stroke.tape`) whose samples are the middle of the
// strip and whose width is its breadth, so a build that does not know tape still opens the page and
// shows a thick line where the strip is. Tape is always the top of a page: it is drawn over ink,
// images and text boxes, also over what is written after it was laid.
public enum TapePattern: String, Codable, CaseIterable, Sendable {
  case plain, stripes, dots, checks
}

public struct Tape: Codable, Equatable, Hashable, Sendable {
  public var pattern: TapePattern
  // Peeled back: the strip is see-through until it is tapped again.
  public var revealed: Bool

  public init(pattern: TapePattern = .stripes, revealed: Bool = false) {
    self.pattern = pattern
    self.revealed = revealed
  }

  private enum CodingKeys: String, CodingKey { case pattern, revealed }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    // A pattern from a later version is drawn plain rather than making the page unreadable.
    pattern = (try? values.decode(TapePattern.self, forKey: .pattern)) ?? .plain
    revealed = try values.decodeIfPresent(Bool.self, forKey: .revealed) ?? false
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(pattern, forKey: .pattern)
    if revealed { try values.encode(true, forKey: .revealed) }
  }

  // A drag shorter than this (page units) is not a strip.
  static let shortest = 4.0
  // A straight strip that is this close to level or upright (as a slope) is made exactly so. Three
  // degrees: a line of handwriting that climbs is followed, a hand that meant "level" is helped.
  static let squaringSlope = 0.0524

  static func squared(from a: Point, to b: Point) -> Point {
    let dx = abs(b.x - a.x)
    let dy = abs(b.y - a.y)
    if dy <= dx * squaringSlope { return Point(b.x, a.y) }
    if dx <= dy * squaringSlope { return Point(a.x, b.y) }
    return b
  }

  // The path of a strip drawn by hand: points at an even distance, each pulled towards its
  // neighbours. On a strip this wide the jitter between two pen samples would show as a ragged edge.
  static func smoothed(_ path: [Point], spacing: Double) -> [Point] {
    guard let first = path.first, let last = path.last else { return [] }
    var even = [first]
    for point in path.dropFirst() where point.distance(to: even[even.count - 1]) >= spacing {
      even.append(point)
    }
    // The strip ends where the pen lifted; a stub shorter than half a step would point anywhere.
    if even.count > 1, even[even.count - 1].distance(to: last) < spacing / 2 {
      even[even.count - 1] = last
    } else if even[even.count - 1] != last {
      even.append(last)
    }
    guard even.count > 2 else { return even }
    var result = even
    for i in 1..<(even.count - 1) {
      result[i] = Point(
        (even[i - 1].x + 2 * even[i].x + even[i + 1].x) / 4,
        (even[i - 1].y + 2 * even[i].y + even[i + 1].y) / 4)
    }
    return result
  }
}

extension Stroke {
  public var isTape: Bool { tape != nil }
  // A strip that is not peeled back: nothing under it can be seen.
  public var isCover: Bool { tape?.revealed == false }

  // The strip a drag along `path` lays down, or nil when the drag is too short to be one.
  public static func tape(
    along path: [Point], color: InkColor, width: Double, pattern: TapePattern, straight: Bool
  ) -> Stroke? {
    guard let first = path.first, let last = path.last else { return nil }
    let points =
      straight
      ? [first, Tape.squared(from: first, to: last)]
      : Tape.smoothed(path, spacing: max(3, width / 4))
    var length = 0.0
    for (a, b) in zip(points, points.dropFirst()) { length += a.distance(to: b) }
    guard length >= Tape.shortest else { return nil }
    var stroke = Stroke(
      samples: points.map { Sample(point: $0) }, color: color, width: width, tool: .pen,
      style: .ballpoint)
    stroke.tape = Tape(pattern: pattern)
    return stroke
  }

  // Whether `point` is on the strip (`slack` wider, for a fingertip). The band as it is drawn: cut
  // off square where the strip ends and rounded where it bends, so what counts as hidden is what
  // cannot be seen.
  public func tapeCovers(_ point: Point, slack: Double = 0) -> Bool {
    guard isTape, samples.count > 1 else { return false }
    let half = width / 2 + slack
    for i in 1..<samples.count {
      let a = samples[i - 1].point
      let b = samples[i].point
      let dx = b.x - a.x
      let dy = b.y - a.y
      let length = hypot(dx, dy)
      guard length > 0 else { continue }
      let along = ((point.x - a.x) * dx + (point.y - a.y) * dy) / length
      let across = abs((point.x - a.x) * dy - (point.y - a.y) * dx) / length
      if across <= half, along >= -slack, along <= length + slack { return true }
      if i < samples.count - 1, b.distance(to: point) <= half { return true }
    }
    return false
  }

  // Most of the stroke lies under one of the strips in `covers`, so it cannot be seen.
  func isHidden(under covers: [Stroke]) -> Bool {
    guard !isTape, !samples.isEmpty, !covers.isEmpty else { return false }
    let box = bounds
    return covers.contains { cover in
      guard cover.bounds.intersects(box) else { return false }
      var under = 0
      for sample in samples where cover.tapeCovers(sample.point) { under += 1 }
      return under * 2 > samples.count
    }
  }
}

extension Page {
  public var tapes: [Stroke] { strokes.filter(\.isTape) }

  // The strip under `point`: the last one, which lies over the others.
  public func tape(at point: Point, tolerance: Double = 0) -> Stroke? {
    strokes.last { $0.tapeCovers(point, slack: tolerance) }
  }

  // Whether a strip reaches into `box`, so that something drawn there may have to go under it.
  public func hasTape(over box: Rect) -> Bool {
    strokes.contains { $0.isTape && $0.bounds.intersects(box) }
  }

  // Peels the strip under `point` back, or covers what it hides again. False when there is none.
  @discardableResult
  public mutating func toggleTape(at point: Point, tolerance: Double = 0) -> Bool {
    guard let index = strokes.lastIndex(where: { $0.tapeCovers(point, slack: tolerance) }) else {
      return false
    }
    strokes[index].tape?.revealed.toggle()
    return true
  }

  public mutating func setTapes(revealed: Bool) {
    for index in strokes.indices where strokes[index].isTape {
      strokes[index].tape?.revealed = revealed
    }
  }

  public mutating func removeTapes() {
    strokes.removeAll(where: \.isTape)
  }
}
