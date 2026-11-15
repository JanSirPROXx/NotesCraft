import Foundation

// Turns the strokes of one symbol into the 28 x 28 picture the pretrained network reads, the way
// MNIST's pictures are made: the longer side of the writing is fitted into 20 pixels (the aspect
// ratio stays), then the picture is shifted so that its centre of mass is the middle of the 28.
// Strokes are drawn as anti-aliased lines of `strokeWidth` pixels. `scripts/symbols/train_symbols.py`
// has the same algorithm for the training data (`render`); `SymbolNetTests` compares the two on
// fixed strokes, so a change here has to be made there too, and the network trained again.

public enum SymbolRaster {
  public static let size = 28
  public static let box = 20.0
  public static let strokeWidth = 2.2

  // Row by row, 0 for paper and 1 for ink. Nil when there is nothing to compare: no points, or all
  // of them in one spot (a dot is told by its size, not by this network).
  public static func render(_ strokes: [[Point]], width: Double = strokeWidth) -> [Float]? {
    var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
    for stroke in strokes {
      for p in stroke {
        minX = min(minX, p.x); maxX = max(maxX, p.x)
        minY = min(minY, p.y); maxY = max(maxY, p.y)
      }
    }
    let extent = max(maxX - minX, maxY - minY)
    guard extent.isFinite, extent >= 1e-9 else { return nil }
    let scale = box / extent
    let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
    let placed: [[(x: Double, y: Double)]] = strokes.filter { !$0.isEmpty }.map { stroke in
      stroke.map { (x: ($0.x - cx) * scale + 14, y: ($0.y - cy) * scale + 14) }
    }

    let first = coverage(placed, width: width)
    var total = 0.0, sumX = 0.0, sumY = 0.0
    for row in 0..<size {
      for col in 0..<size {
        let v = Double(first[row * size + col])
        total += v
        sumX += v * (Double(col) + 0.5)
        sumY += v * (Double(row) + 0.5)
      }
    }
    guard total > 0 else { return nil }
    let dx = 14 - sumX / total, dy = 14 - sumY / total
    return coverage(placed.map { $0.map { (x: $0.x + dx, y: $0.y + dy) } }, width: width)
  }

  // Each pixel is as inked as it is near to a stroke: full within half the width of it, fading
  // over one pixel.
  private static func coverage(_ strokes: [[(x: Double, y: Double)]], width: Double) -> [Float] {
    var nearest = [Double](repeating: .infinity, count: size * size)
    let reach = width / 2 + 0.5
    func segment(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) {
      let x0 = max(0, Int((min(a.x, b.x) - reach).rounded(.down)))
      let x1 = min(size - 1, Int((max(a.x, b.x) + reach).rounded(.up)))
      let y0 = max(0, Int((min(a.y, b.y) - reach).rounded(.down)))
      let y1 = min(size - 1, Int((max(a.y, b.y) + reach).rounded(.up)))
      guard x0 <= x1, y0 <= y1 else { return }
      let abx = b.x - a.x, aby = b.y - a.y
      let len2 = abx * abx + aby * aby
      for row in y0...y1 {
        let py = Double(row) + 0.5
        for col in x0...x1 {
          let px = Double(col) + 0.5
          var t = len2 > 0 ? ((px - a.x) * abx + (py - a.y) * aby) / len2 : 0
          t = min(1, max(0, t))
          let dx = px - (a.x + t * abx), dy = py - (a.y + t * aby)
          let d = (dx * dx + dy * dy).squareRoot()
          if d < nearest[row * size + col] { nearest[row * size + col] = d }
        }
      }
    }
    for stroke in strokes {
      if stroke.count == 1 {
        segment(stroke[0], stroke[0])
      } else {
        for i in 1..<stroke.count { segment(stroke[i - 1], stroke[i]) }
      }
    }
    return nearest.map { Float(min(1, max(0, width / 2 + 0.5 - $0))) }
  }
}
