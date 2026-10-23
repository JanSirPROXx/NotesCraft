import Foundation
import Testing

@testable import NoteCraftCore

private func stroke(_ count: Int) -> [Sample] {
  (0..<count).map { i in
    let t = Double(i) / Double(count - 1)
    return Sample(
      point: Point(10 + t * 120, 40 + sin(t * 7) * 25), pressure: 0.3 + 0.6 * abs(sin(t * 4)),
      altitude: 0.6 + 0.8 * abs(cos(t * 3)))
  }
}

@Test func revisingAWidthEqualsWorkingTheWholeStrokeOutAgain() {
  var samples = stroke(120)
  var track = FountainTrack()
  for sample in samples { track.append(sample, base: 3, tip: .standard) }
  #expect(track.widths == FountainInk.widths(for: samples, base: 3, tip: .standard, finished: false))

  // The measured force of sample 80 differs from what was first reported.
  samples[80].pressure = 0.95
  track.revise(from: 80, samples: samples, base: 3, tip: .standard)
  #expect(
    track.widths == FountainInk.widths(for: samples, base: 3, tip: .standard, finished: false))

  // The first sample can be revised too, and so can a run of them.
  samples[0].pressure = 0.1
  samples[1].pressure = 0.2
  track.revise(from: 0, samples: samples, base: 3, tip: .standard)
  #expect(
    track.widths == FountainInk.widths(for: samples, base: 3, tip: .standard, finished: false))
}

@Test func aRevisionOnlyChangesWidthsFromThatSampleOn() {
  var samples = stroke(60)
  var track = FountainTrack()
  for sample in samples { track.append(sample, base: 3, tip: .standard) }
  let before = track.widths
  samples[40].pressure = 1
  track.revise(from: 40, samples: samples, base: 3, tip: .standard)
  #expect(Array(track.widths[..<40]) == Array(before[..<40]))
  #expect(track.widths[40] != before[40])
}

@Test func theNewestStateContinuesTheTrackForPredictedSamples() {
  let samples = stroke(30)
  var track = FountainTrack()
  for sample in samples { track.append(sample, base: 3, tip: .standard) }
  var viaState = track.state
  let extra = Sample(point: Point(140, 60), pressure: 0.5)
  let predicted = FountainInk.advance(&viaState, sample: extra, base: 3, tip: .standard)
  track.append(extra, base: 3, tip: .standard)
  #expect(track.widths.last == predicted)
}

@Test func reviseIgnoresIndexesOutsideTheStroke() {
  let samples = stroke(10)
  var track = FountainTrack()
  for sample in samples { track.append(sample, base: 3, tip: .standard) }
  let before = track.widths
  track.revise(from: 10, samples: samples, base: 3, tip: .standard)
  track.revise(from: -1, samples: samples, base: 3, tip: .standard)
  track.revise(from: 3, samples: Array(samples.dropLast()), base: 3, tip: .standard)
  #expect(track.widths == before)
}
