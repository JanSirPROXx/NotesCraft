import Foundation

// The pretrained network of the calculator pen: a small convolutional net (two 3 x 3 convolutions
// with pooling, two dense layers, about 106,000 numbers) that reads the 28 x 28 picture of one
// symbol and says how likely each of the 16 symbols is, and a 17th class, "not a symbol", for two
// symbols that were cut as one, a scribble, a slash. It is run here in plain Swift, so it works the
// same on the iPad and in `swift test`, needs no framework and takes a millisecond or two.
//
// Where the numbers come from: `scripts/symbols/train_symbols.py` trains it on MNIST and on digits
// written with a pen (pendigits, 44 writers), with operators and the "not a symbol" class drawn as
// strokes, and writes `SymbolNetWeights.swift`. docs/CALCULATOR.md has the sources and licences.

public final class SymbolNet: Sendable {
  public static let symbols = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "-", "*", "÷", "(", ")"]
  public static let rejectClass = symbols.count
  public static let classCount = symbols.count + 1

  private let conv1w: [Float], conv1b: [Float]
  private let conv2w: [Float], conv2b: [Float]
  private let fc1w: [Float], fc1b: [Float]
  private let fc2w: [Float], fc2b: [Float]

  private static let shapes = [16 * 9, 16, 32 * 16 * 9, 32, 64 * 1568, 64, classCount * 64, classCount]

  // `weights` is what the training script writes: float16, little endian, layer after layer.
  public init?(weights: Data) {
    guard weights.count == Self.shapes.reduce(0, +) * 2 else { return nil }
    var layers: [[Float]] = []
    var offset = 0
    weights.withUnsafeBytes { raw in
      for count in Self.shapes {
        var layer = [Float](repeating: 0, count: count)
        for i in 0..<count {
          let low = UInt16(raw[offset + 2 * i]), high = UInt16(raw[offset + 2 * i + 1])
          layer[i] = Self.float(fromHalf: low | high << 8)
        }
        layers.append(layer)
        offset += count * 2
      }
    }
    (conv1w, conv1b, conv2w, conv2b, fc1w, fc1b, fc2w, fc2b) =
      (layers[0], layers[1], layers[2], layers[3], layers[4], layers[5], layers[6], layers[7])
  }

  // The network that is part of the app.
  public static let bundled: SymbolNet = {
    guard
      let data = Data(base64Encoded: bundledWeights, options: .ignoreUnknownCharacters),
      let net = SymbolNet(weights: data)
    else { fatalError("SymbolNetWeights.swift does not hold the weights of this network") }
    return net
  }()

  // IEEE half precision to single; Float16 itself is not there on Intel Macs.
  static func float(fromHalf h: UInt16) -> Float {
    let sign = UInt32(h & 0x8000) << 16
    let exponent = Int((h >> 10) & 0x1F)
    var mantissa = UInt32(h & 0x3FF)
    if exponent == 0 {
      if mantissa == 0 { return Float(bitPattern: sign) }
      var e = -14
      while mantissa & 0x400 == 0 {
        mantissa <<= 1
        e -= 1
      }
      mantissa &= 0x3FF
      return Float(bitPattern: sign | UInt32(e + 127) << 23 | mantissa << 13)
    }
    if exponent == 31 { return Float(bitPattern: sign | 0x7F80_0000 | mantissa << 13) }
    return Float(bitPattern: sign | UInt32(exponent - 15 + 127) << 23 | mantissa << 13)
  }

  // How likely each class is for the picture `SymbolRaster.render` made, summing to 1.
  public func probabilities(_ picture: [Float]) -> [Float] {
    precondition(picture.count == 28 * 28)
    let a = Self.convolve(picture, channels: 1, size: 28, weights: conv1w, bias: conv1b, outputs: 16)
    let p1 = Self.pool(a, channels: 16, size: 28)
    let b = Self.convolve(p1, channels: 16, size: 14, weights: conv2w, bias: conv2b, outputs: 32)
    let p2 = Self.pool(b, channels: 32, size: 14)
    let hidden = Self.dense(p2, weights: fc1w, bias: fc1b, outputs: 64, relu: true)
    var logits = Self.dense(hidden, weights: fc2w, bias: fc2b, outputs: Self.classCount, relu: false)
    let top = logits.max() ?? 0
    var sum: Float = 0
    for i in logits.indices {
      logits[i] = exp(logits[i] - top)
      sum += logits[i]
    }
    return logits.map { $0 / sum }
  }

  // 3 x 3, padding 1, then ReLU. Planes are `size` x `size`, one after the other.
  private static func convolve(
    _ input: [Float], channels: Int, size: Int, weights: [Float], bias: [Float], outputs: Int
  ) -> [Float] {
    let stride = size + 2
    var padded = [Float](repeating: 0, count: channels * stride * stride)
    for c in 0..<channels {
      for y in 0..<size {
        for x in 0..<size { padded[(c * stride + y + 1) * stride + x + 1] = input[(c * size + y) * size + x] }
      }
    }
    var out = [Float](repeating: 0, count: outputs * size * size)
    out.withUnsafeMutableBufferPointer { out in
      padded.withUnsafeBufferPointer { padded in
        weights.withUnsafeBufferPointer { weights in
          for o in 0..<outputs {
            let plane = o * size * size
            for i in 0..<size * size { out[plane + i] = bias[o] }
            for c in 0..<channels {
              for ky in 0..<3 {
                for kx in 0..<3 {
                  let w = weights[((o * channels + c) * 3 + ky) * 3 + kx]
                  for y in 0..<size {
                    let source = (c * stride + y + ky) * stride + kx
                    let target = plane + y * size
                    for x in 0..<size { out[target + x] += w * padded[source + x] }
                  }
                }
              }
            }
            for i in 0..<size * size { out[plane + i] = max(0, out[plane + i]) }
          }
        }
      }
    }
    return out
  }

  private static func pool(_ input: [Float], channels: Int, size: Int) -> [Float] {
    let half = size / 2
    var out = [Float](repeating: 0, count: channels * half * half)
    for c in 0..<channels {
      for y in 0..<half {
        for x in 0..<half {
          let i = (c * size + 2 * y) * size + 2 * x
          out[(c * half + y) * half + x] = max(max(input[i], input[i + 1]), max(input[i + size], input[i + size + 1]))
        }
      }
    }
    return out
  }

  private static func dense(_ input: [Float], weights: [Float], bias: [Float], outputs: Int, relu: Bool) -> [Float] {
    let count = input.count
    var out = bias
    weights.withUnsafeBufferPointer { weights in
      input.withUnsafeBufferPointer { input in
        for o in 0..<outputs {
          var sum: Float = 0
          let row = o * count
          for i in 0..<count { sum += weights[row + i] * input[i] }
          out[o] += sum
          if relu { out[o] = max(0, out[o]) }
        }
      }
    }
    return out
  }
}
