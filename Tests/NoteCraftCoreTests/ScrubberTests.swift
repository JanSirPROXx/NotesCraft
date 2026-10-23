import Foundation
import Testing

@testable import NoteCraftCore

@Test func theFractionIsWhereTheOffsetIsInWhatCanBeScrolled() {
  let range = -20.0...980.0
  #expect(Scrubber.fraction(offset: -20, in: range) == 0)
  #expect(Scrubber.fraction(offset: 980, in: range) == 1)
  #expect(abs(Scrubber.fraction(offset: 480, in: range) - 0.5) < 1e-9)
  // Bouncing past either end is not outside the track.
  #expect(Scrubber.fraction(offset: -300, in: range) == 0)
  #expect(Scrubber.fraction(offset: 5000, in: range) == 1)
}

@Test func aNotebookThatFitsHasNothingToScrub() {
  #expect(Scrubber.fraction(offset: 0, in: 0...0) == 0)
  #expect(Scrubber.fraction(offset: 3, in: 0...0.2) == 0)
}

@Test func anOffsetAndItsFractionAreInverses() {
  let range = 0.0...12_000
  for f in [0.0, 0.1, 0.37, 0.5, 0.99, 1] {
    let offset = Scrubber.offset(fraction: f, in: range)
    #expect(abs(Scrubber.fraction(offset: offset, in: range) - f) < 1e-9)
  }
  #expect(Scrubber.offset(fraction: 2, in: range) == 12_000)
  #expect(Scrubber.offset(fraction: -1, in: range) == 0)
}

@Test func theHandleIsAsLongAsTheViewIsOfTheContentWithinLimits() {
  // 12 screens of content on an 800 point track: a twelfth, but long enough to grab.
  #expect(abs(Scrubber.thumbLength(visible: 1000, content: 12_000, track: 800) - 66.6667) < 0.001)
  #expect(Scrubber.thumbLength(visible: 1000, content: 300_000, track: 800) == 44)
  // Never more than half the track, however little there is to scroll.
  #expect(Scrubber.thumbLength(visible: 1000, content: 1100, track: 800) == 400)
  #expect(Scrubber.thumbLength(visible: 1000, content: 0, track: 800) == 44)
}

@Test func theHandleStaysOnTheTrack() {
  #expect(Scrubber.thumbStart(fraction: 0, track: 800, thumb: 60) == 0)
  #expect(Scrubber.thumbStart(fraction: 1, track: 800, thumb: 60) == 740)
  #expect(Scrubber.thumbStart(fraction: 0.5, track: 800, thumb: 60) == 370)
  #expect(Scrubber.thumbStart(fraction: 3, track: 800, thumb: 60) == 740)
}

@Test func theHandleFollowsTheFingerThatGrabbedIt() {
  // Taken hold of 20 points from its start, the finger at 420 puts the handle's start at 400.
  let f = Scrubber.fraction(position: 420, grab: 20, track: 800, thumb: 60)
  #expect(abs(Scrubber.thumbStart(fraction: f, track: 800, thumb: 60) - 400) < 1e-9)
  #expect(Scrubber.fraction(position: -50, grab: 20, track: 800, thumb: 60) == 0)
  #expect(Scrubber.fraction(position: 5000, grab: 20, track: 800, thumb: 60) == 1)
  #expect(Scrubber.fraction(position: 100, grab: 0, track: 60, thumb: 60) == 0)
}

@Test func theZoomIsShownAsAWholePercent() {
  #expect(Scrubber.zoomPercent(1) == 100)
  #expect(Scrubber.zoomPercent(1.254) == 125)
  #expect(Scrubber.zoomPercent(0.5) == 50)
  #expect(Scrubber.zoomPercent(5.996) == 600)
}
