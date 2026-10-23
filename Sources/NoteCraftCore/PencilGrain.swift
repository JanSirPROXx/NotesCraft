import Foundation

// The paper tooth a pencil line is multiplied with. One tile of fixed noise, laid out in page
// coordinates, so the grain stays where it is on the paper, and the live GPU ink and the committed
// CoreGraphics ink use exactly the same texels.
public enum PencilGrain {
  public static let size = 256
  // Texels per page point: at the 2x of a retina screen one texel is one pixel.
  public static let texelsPerPoint = 2.0
  // Page points covered by one tile.
  public static var cell: Double { Double(size) / texelsPerPoint }
  // Share of the line that always shows; the rest comes and goes with the grain.
  static let floor = 0.45

  // Row-major, the first row at the top of the page (y down). How much of the line shows at a
  // texel, 0...255. Generated once, from a fixed seed.
  public static let alpha: [UInt8] = make()

  private static func make() -> [UInt8] {
    var state: UInt64 = 0x1234_5678_9ABC_DEF0
    func random() -> Double {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Double(state >> 11) / Double(1 << 53)
    }
    let noise = (0..<size * size).map { _ in random() }
    // A light blur that wraps around the tile, so it repeats without a seam, and gives the grain a
    // little body instead of single pixels.
    var soft = noise
    for y in 0..<size {
      for x in 0..<size {
        var sum = 0.0
        var weight = 0.0
        for dy in -1...1 {
          for dx in -1...1 {
            let w = dx == 0 && dy == 0 ? 5.0 : 1.0
            sum += w * noise[((y + dy + size) % size) * size + (x + dx + size) % size]
            weight += w
          }
        }
        soft[y * size + x] = sum / weight
      }
    }
    // The blur pulls values towards the middle; stretch them back so the tooth has contrast.
    func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
      let t = min(1, max(0, (x - a) / (b - a)))
      return t * t * (3 - 2 * t)
    }
    return soft.map { UInt8((floor + (1 - floor) * smoothstep(0.32, 0.68, $0)) * 255) }
  }
}
