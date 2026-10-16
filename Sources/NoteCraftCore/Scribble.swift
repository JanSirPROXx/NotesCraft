import Foundation

// Scribble to erase. The pen's path becomes a zone: the path thickened by a radius that follows
// how tightly the scribble was drawn, so a small scrub is precise and a big, loose one reaches
// ink it did not touch exactly. Ink is then judged against that zone:
//   - a stroke with at least 80 % of its length inside the zone goes entirely, also the bit that
//     sticks out (letters, words);
//   - a stroke that is only partly inside but was deliberately scribbled over (long wires,
//     underlines, table borders) loses just the part under the scribble.
extension InkGestures {
  public struct ScratchOutcome: Equatable, Sendable {
    public enum Certainty: Sendable {
      case clear
      // A close call: the scribble could also have been a drawing (a symbol across a wire).
      case doubtful
    }
    public var strokes: [Stroke]
    public var certainty: Certainty
    // The ink that disappears (whole strokes, or the cut-out part of one), for a live preview.
    public var affected: [Stroke]
  }

  // Share of a stroke's length that must lie inside the zone for the whole stroke to go.
  static let scratchCoverage = 0.8
  // Whole-stroke removals below this share count as close calls.
  static let scratchComfortableCoverage = 0.9
  // A scribble that only cuts through long ink needs at least this many reversals, otherwise it
  // is more likely a symbol drawn across a wire than an eraser gesture.
  static let scratchDenseReversals = 5

  private struct Scribble {
    var path: [Point]
    var reversals: Int
  }

  // Require several sharp reversals along a path much longer than its own extent. Thresholds
  // scale with the scribble so a small scrub over one letter counts as readily as a big one;
  // an ordinary loop or a stroke that does not double back must remain ink.
  public static func isScratch(_ points: [Point]) -> Bool { scribble(points) != nil }

  private static func scribble(_ points: [Point]) -> Scribble? {
    guard let first = points.first, points.count >= 6 else { return nil }
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    let width = xs.max()! - xs.min()!
    let height = ys.max()! - ys.min()!
    let diagonal = hypot(width, height)
    guard max(width, height) >= 6 else { return nil }
    let step = min(8, max(2.5, diagonal * 0.1))
    var reduced = [first]
    for point in points.dropFirst() where point.distance(to: reduced.last!) >= step {
      reduced.append(point)
    }
    guard reduced.count >= 6 else { return nil }
    var reversals = 0
    var length = 0.0
    for i in 1..<reduced.count {
      let a = reduced[i - 1]
      let b = reduced[i]
      length += a.distance(to: b)
      if i > 1, cosine(reduced[i - 2], a, b) < -0.65 { reversals += 1 }
    }
    // Two quick passes back and forth (three reversals) are a scribble too, as long as the path
    // clearly doubles over itself; fewer reversals stay ink.
    let ratio = length / max(1, diagonal)
    guard length > 18, (reversals >= 4 && ratio > 3) || (reversals == 3 && ratio > 3.4) else {
      return nil
    }
    return Scribble(path: reduced, reversals: reversals)
  }

  private static func cosine(_ p: Point, _ a: Point, _ b: Point) -> Double {
    let ux = a.x - p.x
    let uy = a.y - p.y
    let vx = b.x - a.x
    let vy = b.y - a.y
    return (ux * vx + uy * vy) / max(1, hypot(ux, uy) * hypot(vx, vy))
  }

  // What a scribble does to the page: the strokes that remain, or nil when the gesture should
  // stay ink (not a scribble, nothing under it, or too ambiguous to take ink away).
  public static func scratchOutcome(_ points: [Point], strokes: [Stroke]) -> ScratchOutcome? {
    guard let scribble = scribble(points), scribble.path.count >= 3 else { return nil }
    let zone = ScratchZone(scribble.path)
    var remaining: [Stroke] = []
    remaining.reserveCapacity(strokes.count)
    var removed = false
    var cut = false
    var closeCall = false
    var affected: [Stroke] = []
    for stroke in strokes {
      switch zone.verdict(for: stroke) {
      case .keep:
        remaining.append(stroke)
      case .remove(let coverage):
        removed = true
        affected.append(stroke)
        closeCall = closeCall || coverage < scratchComfortableCoverage
      case .cut(let pieces, let gone):
        cut = true
        remaining += pieces
        affected += gone
      }
    }
    guard removed || cut else { return nil }
    // Only cutting through long ink with a loose scribble: that is how a symbol drawn across a
    // wire looks, so it stays a drawing. A dense scrub is unmistakable and does cut.
    if !removed && scribble.reversals < scratchDenseReversals { return nil }
    let doubtful = !removed || closeCall || scribble.reversals <= 3
    return ScratchOutcome(
      strokes: remaining, certainty: doubtful ? .doubtful : .clear, affected: affected)
  }

  private enum ScratchVerdict {
    case keep
    case remove(coverage: Double)
    case cut([Stroke], removed: [Stroke])
  }

  private struct ScratchZone {
    struct Segment {
      var a: Point
      var b: Point
      var sweep: Int
      var minX: Double { min(a.x, b.x) }
      var maxX: Double { max(a.x, b.x) }
      var minY: Double { min(a.y, b.y) }
      var maxY: Double { max(a.y, b.y) }
    }
    var segments: [Segment] = []
    var radius = 3.0
    var minX = 0.0
    var maxX = 0.0
    var minY = 0.0
    var maxY = 0.0

    init(_ path: [Point]) {
      minX = path.map(\.x).min()!
      maxX = path.map(\.x).max()!
      minY = path.map(\.y).min()!
      maxY = path.map(\.y).max()!
      // A sweep is a run between two reversals.
      var sweep = 0
      for i in 1..<path.count {
        if i > 1, InkGestures.cosine(path[i - 2], path[i - 1], path[i]) < -0.3 { sweep += 1 }
        segments.append(Segment(a: path[i - 1], b: path[i], sweep: sweep))
      }
      // The gap between neighbouring sweeps, measured across the direction they run in, says how
      // coarse the scribble is. The zone reaches 60 % of a gap to each side so neighbouring
      // sweeps overlap, with a floor so a scrub in place still has some reach.
      var dx = 0.0
      var dy = 0.0
      for segment in segments {
        var vx = segment.b.x - segment.a.x
        var vy = segment.b.y - segment.a.y
        if vx * dx + vy * dy < 0 {
          vx = -vx
          vy = -vy
        }
        dx += vx
        dy += vy
      }
      let norm = hypot(dx, dy)
      var gap = 0.0
      if norm > 0 {
        let across = path.map { ($0.x * -dy + $0.y * dx) / norm }
        let extent = across.max()! - across.min()!
        gap = extent / Double(max(1, sweep))
      }
      radius = min(16, max(3, gap * 0.6))
    }

    func verdict(for stroke: Stroke) -> ScratchVerdict {
      guard stroke.tool != .highlighter, !stroke.samples.isEmpty else { return .keep }
      let box = stroke.bounds
      // A dot or i-point is hard to hit precisely with a small scrub, so it gets a wider reach.
      let isDot = box.width <= stroke.width + 4 && box.height <= stroke.width + 4
      let tolerance = radius + stroke.width / 2 + (isDot ? 2 : 0)
      guard box.x - tolerance <= maxX, box.x + box.width + tolerance >= minX,
        box.y - tolerance <= maxY, box.y + box.height + tolerance >= minY
      else { return .keep }
      let dense = InkGestures.densified(stroke.samples, spacing: max(1, min(2.5, radius / 2)))
      var inside = [Bool](repeating: false, count: dense.count)
      var count = 0
      var lowest = Int.max
      var highest = Int.min
      for (i, sample) in dense.enumerated() {
        let p = sample.point
        for segment in segments
        where segment.maxX + tolerance >= p.x && segment.minX - tolerance <= p.x
          && segment.maxY + tolerance >= p.y && segment.minY - tolerance <= p.y
          && Editing.distance(p, toSegmentFrom: segment.a, to: segment.b) <= tolerance
        {
          if !inside[i] {
            inside[i] = true
            count += 1
          }
          lowest = min(lowest, segment.sweep)
          highest = max(highest, segment.sweep)
        }
      }
      guard count > 0 else { return .keep }
      let coverage = Double(count) / Double(dense.count)
      if coverage >= InkGestures.scratchCoverage { return .remove(coverage: coverage) }
      // Cutting is the more destructive guess, so it needs a deliberate back and forth over the
      // stroke: two sweeps that are not neighbours. A tip that merely grazes it does not count.
      guard highest - lowest >= 2 else { return .keep }
      var runs: [[Sample]] = [[]]
      var gone: [[Sample]] = [[]]
      for (sample, isInside) in zip(dense, inside) {
        if isInside {
          if !runs[runs.count - 1].isEmpty { runs.append([]) }
          gone[gone.count - 1].append(sample)
        } else {
          if !gone[gone.count - 1].isEmpty { gone.append([]) }
          runs[runs.count - 1].append(sample)
        }
      }
      // Slivers left beside the cut are not worth keeping.
      let crumb = max(3, stroke.width * 2)
      let pieces = runs.filter { run in
        zip(run, run.dropFirst()).reduce(0.0) { $0 + $1.0.point.distance(to: $1.1.point) } >= crumb
      }
      guard !pieces.isEmpty else { return .remove(coverage: coverage) }
      func plain(_ samples: [Sample], id: UUID) -> Stroke {
        var piece = stroke
        piece.id = id
        piece.samples = samples
        // Parts of a stroke are plain ink: a shape spec or fill would redraw the whole figure.
        piece.shape = nil
        piece.fillColor = nil
        piece.fillOpacity = nil
        return piece
      }
      return .cut(
        pieces.map { plain($0, id: UUID()) },
        removed: gone.filter { !$0.isEmpty }.map { plain($0, id: stroke.id) })
    }
  }

  // Samples every `spacing` points along the stroke with pressure and tilt interpolated, so
  // coverage is measured by length and a cut can fall between the original samples.
  fileprivate static func densified(_ samples: [Sample], spacing: Double) -> [Sample] {
    guard samples.count > 1, let last = samples.last else { return samples }
    var length = 0.0
    for (a, b) in zip(samples, samples.dropFirst()) { length += a.point.distance(to: b.point) }
    let step = max(spacing, length / 4000)
    var dense: [Sample] = []
    for (a, b) in zip(samples, samples.dropFirst()) {
      let steps = max(1, Int(ceil(a.point.distance(to: b.point) / step)))
      for i in 0..<steps {
        let t = Double(i) / Double(steps)
        dense.append(
          Sample(
            point: Point(
              a.point.x + (b.point.x - a.point.x) * t, a.point.y + (b.point.y - a.point.y) * t),
            pressure: a.pressure + (b.pressure - a.pressure) * t,
            altitude: a.altitude + (b.altitude - a.altitude) * t))
      }
    }
    dense.append(last)
    return dense
  }
}
