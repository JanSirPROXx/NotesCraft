import Foundation
import Testing

@testable import NoteCraftCore

private func line(pressure: Double = 0.5, altitude: Double = .pi / 2, count: Int = 40) -> [Sample] {
  (0..<count).map {
    Sample(point: Point(10 + Double($0) * 2, 50), pressure: pressure, altitude: altitude)
  }
}

@Test func aFingerOrMouseDrawsThePenWidthExactly() {
  // Pressure 1 and an upright pen are what a touch without force reports.
  let widths = PencilInk.widths(for: line(pressure: 1, count: 30), base: 2, finished: false)
  #expect(widths.allSatisfy { abs($0 - 2) < 1e-9 })
}

@Test func pressingHarderDrawsAWiderLine() {
  func settled(_ pressure: Double) -> Double {
    PencilInk.widths(for: line(pressure: pressure), base: 2, finished: false)[30]
  }
  #expect(settled(0.2) < settled(0.5))
  #expect(settled(0.5) < settled(0.9))
}

@Test func layingThePencilOnItsSideDrawsAWiderLine() {
  func settled(_ altitude: Double) -> Double {
    PencilInk.widths(for: line(pressure: 0.99, altitude: altitude), base: 2, finished: false)[30]
  }
  #expect(settled(.pi / 2) < settled(1.0))
  #expect(settled(1.0) < settled(0.4))
  #expect(settled(0.4) > 2 * 1.5, "a flat pencil is at least half as wide again")
}

@Test func forceBuildsUpGraduallyAtTheStartOfAStroke() {
  // The first samples of a touch carry little force; the line must not start thin and swell.
  let widths = PencilInk.widths(
    for: [Sample(point: Point(0, 0), pressure: 0.02)]
      + (1..<20).map { Sample(point: Point(Double($0) * 2, 0), pressure: 0.6) }, base: 2,
    finished: false)
  #expect(widths[0] > 1.2, "\(widths[0])")
}

@Test func theWidthOfASampleOnlyDependsOnWhatCameBefore() {
  let samples = (0..<60).map {
    Sample(
      point: Point(Double($0) * 2, 20 * sin(Double($0) / 7)),
      pressure: 0.3 + 0.6 * abs(sin(Double($0) / 9)), altitude: 0.6 + 0.8 * abs(cos(Double($0) / 11)))
  }
  let full = PencilInk.widths(for: samples, base: 2, finished: false)
  let prefix = PencilInk.widths(for: Array(samples.prefix(35)), base: 2, finished: false)
  #expect(Array(full.prefix(35)) == prefix)
}

@Test func theEndOfAFinishedStrokeTapers() {
  let samples = line(pressure: 0.8)
  let live = PencilInk.widths(for: samples, base: 2, finished: false)
  let done = PencilInk.widths(for: samples, base: 2, finished: true)
  #expect(done[..<30] == live[..<30])
  #expect(done.last! < live.last! * 0.8)
}

@Test func theLineNeverGetsThinnerThanAThirdOfThePen() {
  let widths = PencilInk.widths(for: line(pressure: 0.001, count: 50), base: 3, finished: true)
  #expect(widths.allSatisfy { $0 >= 3 * 0.35 * 0.7 - 1e-9 })
}

@Test func aWidthModelFollowsThePenStyle() {
  #expect(WidthModel(style: .pencil, tip: .standard) == .pencil)
  #expect(WidthModel(style: .fountain, tip: .standard) == .fountain(.standard))
  #expect(WidthModel(style: .ballpoint, tip: .standard) == nil)
  #expect(WidthModel(style: .brush, tip: .standard) == nil)
}

@Test func theGrainTileIsFixedAndCoversMostOfTheLine() {
  let alpha = PencilGrain.alpha
  #expect(alpha.count == PencilGrain.size * PencilGrain.size)
  let floor = Int(PencilGrain.floor * 255)
  #expect(alpha.allSatisfy { Int($0) >= floor - 1 })
  let mean = Double(alpha.reduce(0) { $0 + Int($1) }) / Double(alpha.count) / 255
  #expect(mean > 0.6 && mean < 0.85, "the tooth should take away a fifth to a third, not \(mean)")
  // Locked: the committed ink and the live GPU ink both read this tile, so changing it is a
  // decision, not an accident.
  var checksum = 0
  for byte in alpha { checksum = (checksum &* 31 &+ Int(byte)) & 0xFFFF_FFFF }
  #expect(checksum == lockedChecksum, "the tile changed: \(checksum)")
}

private let lockedChecksum = 3131750515

@Test func theGrainTileRepeatsWithoutASeam() {
  let n = PencilGrain.size
  let alpha = PencilGrain.alpha
  func difference(_ a: Int, _ b: Int) -> Double { abs(Double(alpha[a]) - Double(alpha[b])) }
  var inside = 0.0
  var seam = 0.0
  for row in 0..<n {
    inside += difference(row * n + 100, row * n + 101)
    seam += difference(row * n + n - 1, row * n)
  }
  for column in 0..<n {
    inside += difference(100 * n + column, 101 * n + column)
    seam += difference((n - 1) * n + column, column)
  }
  #expect(abs(seam - inside) / inside < 0.15, "seam \(seam), inside \(inside)")
}
