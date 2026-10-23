import Foundation
import Testing

@testable import NoteCraftCore

// Deterministic pseudo-random noise, so a failing run can be reproduced.
private struct Noise {
  var state: UInt64 = 0x9E37_79B9_7F4A_7C15
  mutating func unit() -> Double {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Double(state >> 11) / Double(1 << 53)
  }
  // Roughly Gaussian with the given standard deviation.
  mutating func gaussian(_ sigma: Double) -> Double {
    ((0..<12).reduce(0.0) { total, _ in total + unit() } - 6) * sigma
  }
}

private struct Reading {
  var truth: Point
  var time: TimeInterval
}

private func readings(
  duration: Double, rate: Double, truth: (Double) -> Point
) -> [Reading] {
  (0...Int(duration * rate)).map { i in
    let t = Double(i) / rate
    return Reading(truth: truth(t), time: t)
  }
}

private func run(
  _ input: [Reading], stabilization: Double = 0, scale: Double = 1, noise sigma: Double = 0,
  filtered: Bool = true
) -> [Point] {
  var noise = Noise()
  var smoother = InkSmoother(parameters: .init(stabilization: stabilization), scale: scale)
  return input.map { reading in
    let raw = Point(
      reading.truth.x + noise.gaussian(sigma), reading.truth.y + noise.gaussian(sigma))
    return filtered ? smoother.advance(raw, at: reading.time) : raw
  }
}

// Mean distance of the points from the curve they were meant to follow, whatever the timing: lag
// along the curve is not shape error, and `lagStaysUnderAPointAtAnyWritingSpeed` covers it.
private func shapeError(
  _ points: [Point], of curve: (Double) -> Point, duration: Double, from start: Int = 0
) -> Double {
  let dense = (0...Int(duration * 1000)).map { curve(Double($0) / 1000) }
  let distances = points.dropFirst(start).map { p in dense.map { p.distance(to: $0) }.min()! }
  return distances.reduce(0, +) / Double(distances.count)
}

// Mean size of the second difference: the part of the path that zigzags from sample to sample.
private func roughness(_ points: [Point], from start: Int = 0) -> Double {
  let tail = Array(points.dropFirst(start))
  let sizes = (1..<tail.count - 1).map { i in
    hypot(tail[i + 1].x - 2 * tail[i].x + tail[i - 1].x, tail[i + 1].y - 2 * tail[i].y + tail[i - 1].y)
  }
  return sizes.reduce(0, +) / Double(sizes.count)
}

@Test func theFirstPointOfAStrokeIsNotMoved() {
  var smoother = InkSmoother(parameters: .init(stabilization: 1))
  #expect(smoother.advance(Point(12.5, -3), at: 100) == Point(12.5, -3))
}

@Test func aSlowNoisyStrokeIsSteadied() {
  // 30 pt/s, the pace of fine detail, with half a point of digitiser noise.
  let curve: (Double) -> Point = { t in Point(30 * t, 5 * sin(t * 4)) }
  let input = readings(duration: 3, rate: 240, truth: curve)
  let raw = run(input, stabilization: 0, noise: 0.5, filtered: false)
  let smoothed = run(input, noise: 0.5)
  let before = shapeError(raw, of: curve, duration: 3, from: 20)
  let after = shapeError(smoothed, of: curve, duration: 3, from: 20)
  #expect(after < before * 0.55, "noise went from \(before) to \(after)")
}

@Test(arguments: [50.0, 150, 400, 1200])
func lagStaysUnderAPointAtAnyWritingSpeed(speed: Double) {
  for rate in [60.0, 120, 240] {
    let input = readings(duration: 1, rate: rate) { t in Point(speed * t, 0) }
    let smoothed = run(input)
    let end = try! #require(smoothed.last)
    let lag = speed * input.last!.time - end.x
    #expect(lag >= 0 && lag < 1, "lag \(lag) pt at \(speed) pt/s, \(rate) Hz")
  }
}

@Test func aQuickCornerKeepsItsShape() {
  // Right at 300 pt/s, a brief stop, then straight up at 300 pt/s.
  let input = readings(duration: 1, rate: 240) { t in
    let before = min(t, 0.4)
    let after = max(0, t - 0.43)
    return Point(300 * before, -300 * after)
  }
  let smoothed = run(input)
  let corner = Point(120, 0)
  let closest = smoothed.map { $0.distance(to: corner) }.min() ?? .infinity
  #expect(closest < 1.2, "the stroke cuts the corner by \(closest) pt")
}

@Test func moreStabilizationMeansMoreSteadinessAndMoreLag() {
  let slow = readings(duration: 3, rate: 240) { t in Point(40 * t, 4 * sin(t * 3)) }
  let fast = readings(duration: 1, rate: 240) { t in Point(300 * t, 0) }
  var noiseByLevel: [Double] = []
  var lagByLevel: [Double] = []
  for level in [0.0, 0.5, 1.0] {
    noiseByLevel.append(roughness(run(slow, stabilization: level, noise: 0.5), from: 60))
    let end = run(fast, stabilization: level).last!
    lagByLevel.append(300 - end.x)
  }
  #expect(noiseByLevel[0] > noiseByLevel[1] && noiseByLevel[1] > noiseByLevel[2], "\(noiseByLevel)")
  #expect(lagByLevel[0] < lagByLevel[1] && lagByLevel[1] < lagByLevel[2], "\(lagByLevel)")
  // Even the strongest setting follows the tip within a handful of points.
  #expect(lagByLevel[2] < 8, "\(lagByLevel)")
}

@Test(arguments: [(3.0, 8.0), (6.0, 6.0), (10.0, 5.0), (20.0, 3.0)])
func aSmallQuickCircleKeepsItsSize(radius: Double, frequency: Double) {
  // The loop of a handwritten "o" is a few points wide and drawn several times a second; a filter
  // that shrinks it would make every round letter smaller than it was written.
  let input = readings(duration: 1.5, rate: 240) { t in
    Point(
      100 + radius * cos(2 * .pi * frequency * t), 100 + radius * sin(2 * .pi * frequency * t))
  }
  let smoothed = run(input).enumerated().filter { input[$0.offset].time > 0.5 }.map(\.element)
  let mean = smoothed.map { $0.distance(to: Point(100, 100)) }.reduce(0, +) / Double(smoothed.count)
  #expect(mean / radius > 0.94, "the loop came out at \(mean / radius) of its size")
}

@Test func theResultDoesNotDependOnHowOftenSamplesArrive() {
  // A finger reports at 60 Hz, a Pencil at 240 Hz: the same motion must settle in the same place.
  let motion: (Double) -> Point = { t in Point(200 * t + 20 * sin(t * 5), 40 * sin(t * 2)) }
  let fine = run(readings(duration: 1, rate: 240, truth: motion))
  let coarse = run(readings(duration: 1, rate: 60, truth: motion))
  for i in stride(from: 60, through: 240, by: 4) {
    let difference = fine[i].distance(to: coarse[i / 4])
    #expect(difference < 1, "\(difference) pt apart at sample \(i)")
  }
}

@Test func theFilterIsMeasuredInScreenPointsNotDocumentUnits() {
  // The same motion on screen, described in document units at a different zoom.
  let onScreen = readings(duration: 1, rate: 240) { t in Point(150 * t, 6 * sin(t * 6)) }
  let zoomed = onScreen.map { Reading(truth: Point($0.truth.x / 4, $0.truth.y / 4), time: $0.time) }
  let a = run(onScreen, scale: 1)
  let b = run(zoomed, scale: 4)
  for (p, q) in zip(a, b) {
    #expect(p.distance(to: Point(q.x * 4, q.y * 4)) < 1e-9)
  }
}

@Test func aRepeatedTimestampDoesNotBreakTheFilter() {
  var smoother = InkSmoother(parameters: .init(stabilization: 0.3))
  _ = smoother.advance(Point(0, 0), at: 1)
  let a = smoother.advance(Point(1, 1), at: 1)
  let b = smoother.advance(Point(2, 2), at: 1)
  #expect(a.x.isFinite && b.x.isFinite && b.x >= a.x)
}

@Test func aCopyPredictsWithoutDisturbingTheLiveFilter() {
  var live = InkSmoother(parameters: .init(stabilization: 0))
  _ = live.advance(Point(0, 0), at: 0)
  _ = live.advance(Point(1, 0), at: 1 / 240)
  var prediction = live
  for i in 2...6 { _ = prediction.advance(Point(Double(i), 0), at: Double(i) / 240) }
  var untouched = InkSmoother(parameters: .init(stabilization: 0))
  _ = untouched.advance(Point(0, 0), at: 0)
  _ = untouched.advance(Point(1, 0), at: 1 / 240)
  #expect(live.advance(Point(2, 0), at: 2 / 240) == untouched.advance(Point(2, 0), at: 2 / 240))
}
