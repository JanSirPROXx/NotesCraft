import Foundation

// The numbers behind the handle that scrubs through a notebook (a scroll bar that can be grabbed)
// and the zoom label next to it. Everything is along one axis: the scroll axis of the notebook.
public enum Scrubber {
  // Where an offset is within what can be scrolled, 0 at the start and 1 at the end. A notebook
  // that fits has nothing to scrub, which reads as the start.
  public static func fraction(offset: Double, in range: ClosedRange<Double>) -> Double {
    let span = range.upperBound - range.lowerBound
    guard span > 0.5 else { return 0 }
    return min(1, max(0, (offset - range.lowerBound) / span))
  }

  public static func offset(fraction: Double, in range: ClosedRange<Double>) -> Double {
    range.lowerBound + (range.upperBound - range.lowerBound) * min(1, max(0, fraction))
  }

  // How long the handle is on a track: as much of it as the view is of the content, but never
  // too short to grab, nor more than half the track.
  public static func thumbLength(
    visible: Double, content: Double, track: Double, minimum: Double = 44
  ) -> Double {
    guard content > 0, track > 0 else { return min(minimum, max(0, track)) }
    let proportional = track * min(1, visible / content)
    return min(max(minimum, proportional), max(minimum, track / 2))
  }

  // Where the handle starts on the track for a fraction.
  public static func thumbStart(fraction: Double, track: Double, thumb: Double) -> Double {
    max(0, track - thumb) * min(1, max(0, fraction))
  }

  // The fraction for a finger at `position` along the track, which held the handle `grab` points
  // from its start when it took hold: the handle follows the finger instead of jumping under it.
  public static func fraction(position: Double, grab: Double, track: Double, thumb: Double)
    -> Double
  {
    let room = track - thumb
    guard room > 0.5 else { return 0 }
    return min(1, max(0, (position - grab) / room))
  }

  // "125%": the zoom of the notebook, where fit to width is 100%.
  public static func zoomPercent(_ zoom: Double) -> Int {
    Int((zoom * 100).rounded())
  }
}
