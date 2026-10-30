import NoteCraftCore
import SwiftUI

// Shown the first time the calculator pen is picked, and again from its settings: a looping demo of
// what the pen does and two sentences about it. The demo is drawn, not a video, so it stays sharp
// at any size, shows the pen colour the reader chose and adds no asset to the app.
struct CalculatorIntroView: View {
  var color: InkColor
  var onDone: () -> Void

  var body: some View {
    VStack(spacing: 20) {
      CalculatorDemo(color: color.swiftUI)
        .aspectRatio(2, contentMode: .fit).frame(maxWidth: 420)
        .clipShape(RoundedRectangle(cornerRadius: .corner(14)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Animation: 12 × 3 = is written, lights up, and 36 appears next to it.")
      VStack(spacing: 8) {
        // Not on the container: an identifier there would replace those of the views inside it.
        Text("Calculator pen").font(.theme(.title2).bold()).accessibilityIdentifier("calculatorIntroTitle")
        Text(
          "Write a calculation, like 12 × 3 or a fraction, and end it with =. "
            + "The pen lights it up and writes the answer next to it; tap an answer to correct it."
        )
        .font(.theme(.body)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      }
      Button(action: onDone) {
        Text("Got it").font(.theme(.headline)).frame(maxWidth: 240, minHeight: 36)
      }
      .buttonStyle(.borderedProminent).accessibilityIdentifier("calculatorIntroDone")
    }
    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).themedSheet()
  }
}

// "12 × 3 =" is written stroke by stroke, lights up, three dots wait, and 36 is written next to it,
// then the loop starts again. With Reduce Motion it is the finished picture, standing still.
private struct CalculatorDemo: View {
  var color: Color
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let loop = 6.6
  // When each stroke is drawn: (from, to) in seconds.
  private static let timing: [(Double, Double)] = [
    (0.0, 0.35), (0.35, 0.9), (1.0, 1.25), (1.25, 1.5), (1.65, 2.2), (2.4, 2.6), (2.65, 2.85),
  ]

  var body: some View {
    TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
      let t = reduceMotion ? 5.2 : context.date.timeIntervalSinceReferenceDate
        .truncatingRemainder(dividingBy: Self.loop)
      Canvas { c, size in draw(&c, size: size, t: t) }
    }
    .background(Color.white)
  }

  private func draw(_ c: inout GraphicsContext, size: CGSize, t: Double) {
    let w = size.width, h = size.height
    // Faint ruled lines, like the paper in the app.
    for i in 1..<6 {
      var line = Path()
      line.move(to: CGPoint(x: 0, y: h * CGFloat(i) / 6))
      line.addLine(to: CGPoint(x: w, y: h * CGFloat(i) / 6))
      c.stroke(line, with: .color(Color(white: 0.9)), lineWidth: 1)
    }
    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: (0.03 + x * 0.80) * w, y: y * h) }
    let paths = Self.glyphs.map { $0.path(p) }
    let ink = max(2.5, h * 0.022)

    let fade = t > 6.0 ? max(0, 1 - (t - 6.0) / 0.5) : 1.0
    c.opacity = fade

    // The writing.
    var written = Path()
    for (index, path) in paths.enumerated() {
      let (from, to) = Self.timing[index]
      let progress = min(1, max(0, (t - from) / (to - from)))
      guard progress > 0 else { continue }
      let part = path.trimmedPath(from: 0, to: progress)
      written.addPath(part)
    }

    // The glow, from 2.95 s: a halo that swells and settles, and a streak of light sweeping across.
    let glow = Self.bump(t, from: 2.95, peak: 3.3, settle: 3.9, end: 4.3)
    if glow > 0 {
      c.drawLayer { layer in
        layer.addFilter(.blur(radius: h * 0.05))
        layer.stroke(
          written, with: .color(color.opacity(0.75 * glow)),
          style: StrokeStyle(lineWidth: ink * 4, lineCap: .round, lineJoin: .round))
      }
      c.stroke(
        written, with: .color(color.opacity(0.45 * glow)),
        style: StrokeStyle(lineWidth: ink * 2.2, lineCap: .round, lineJoin: .round))
      let sweep = min(1, max(0, (t - 2.95) / 0.8))
      if sweep > 0, sweep < 1 {
        c.drawLayer { layer in
          let band = w * 0.22
          layer.clip(to: Path(CGRect(x: (w + band) * sweep - band, y: 0, width: band, height: h)))
          layer.stroke(
            written, with: .color(.white.opacity(0.9)),
            style: StrokeStyle(lineWidth: ink * 1.1, lineCap: .round, lineJoin: .round))
        }
      }
    }
    c.stroke(written, with: .color(color), style: StrokeStyle(lineWidth: ink, lineCap: .round, lineJoin: .round))

    // Three dots wait where the answer will stand.
    if t > 3.05, t < 4.6 {
      let dotSize = h * 0.045
      for i in 0..<3 {
        let phase = (t - 3.05) * 2.2 - Double(i) * 0.4
        let pulse = 0.3 + 0.7 * max(0, sin(phase * .pi))
        let centre = p(0.815 + Double(i) * 0.06, 0.64)
        let r = dotSize * (0.7 + 0.45 * pulse)
        c.fill(
          Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r)),
          with: .color(color.opacity(pulse)))
      }
    }

    // The answer.
    if t > 4.6 {
      let appear = min(1, (t - 4.6) / 0.35)
      var inner = c
      inner.opacity = fade * appear
      let origin = p(0.80, 0.49)
      inner.translateBy(x: origin.x, y: origin.y)
      inner.scaleBy(x: 0.85 + 0.15 * appear, y: 0.85 + 0.15 * appear)
      inner.draw(
        Text("36").font(.custom("Noteworthy-Light", size: h * 0.34)).foregroundColor(color),
        at: .zero, anchor: .leading)
    }
  }

  // 0 before `from`, up to 1 at `peak`, 0.4 at `settle`, 0 at `end`.
  private static func bump(_ t: Double, from: Double, peak: Double, settle: Double, end: Double) -> Double {
    if t <= from || t >= end { return 0 }
    if t < peak { return (t - from) / (peak - from) }
    if t < settle { return 1 - 0.6 * (t - peak) / (settle - peak) }
    return 0.4 * (1 - (t - settle) / (end - settle))
  }

  // The glyphs of "12×3=", each written with one stroke, in unit coordinates.
  private enum Segment {
    case move(Double, Double)
    case line(Double, Double)
    case curve(Double, Double, Double, Double, Double, Double)
  }
  private struct Glyph {
    var segments: [Segment]
    func path(_ p: (Double, Double) -> CGPoint) -> Path {
      var path = Path()
      for segment in segments {
        switch segment {
        case .move(let x, let y): path.move(to: p(x, y))
        case .line(let x, let y): path.addLine(to: p(x, y))
        case .curve(let x, let y, let x1, let y1, let x2, let y2):
          path.addCurve(to: p(x, y), control1: p(x1, y1), control2: p(x2, y2))
        }
      }
      return path
    }
  }
  private static let glyphs: [Glyph] = [
    // 1
    Glyph(segments: [.move(0.135, 0.40), .line(0.165, 0.30), .line(0.165, 0.68)]),
    // 2
    Glyph(segments: [
      .move(0.22, 0.37), .curve(0.31, 0.40, 0.23, 0.29, 0.32, 0.31),
      .curve(0.22, 0.68, 0.30, 0.52, 0.25, 0.60), .line(0.325, 0.68),
    ]),
    // × (two strokes)
    Glyph(segments: [.move(0.385, 0.41), .line(0.455, 0.57)]),
    Glyph(segments: [.move(0.455, 0.41), .line(0.385, 0.57)]),
    // 3
    Glyph(segments: [
      .move(0.525, 0.34), .curve(0.555, 0.49, 0.61, 0.28, 0.60, 0.47),
      .curve(0.515, 0.65, 0.62, 0.50, 0.61, 0.72),
    ]),
    // = (two strokes)
    Glyph(segments: [.move(0.665, 0.43), .line(0.765, 0.43)]),
    Glyph(segments: [.move(0.665, 0.55), .line(0.765, 0.55)]),
  ]
}
