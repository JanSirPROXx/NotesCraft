import Foundation

// The stored form of a stroke's samples: Base64 of one 12-byte little-endian record per sample.
//
//   bytes 0-3   x         Int32, hundredths of a point
//   bytes 4-7   y         Int32, hundredths of a point
//   bytes 8-9   pressure  UInt16, thousandths
//   bytes 10-11 altitude  UInt16, ten-thousandths of a radian
//
// `Sample` snaps to exactly this grid, so packing and unpacking lose nothing.
enum SampleCodec {
  static let record = 12

  static func pack(_ samples: [Sample]) -> String {
    var bytes = [UInt8](repeating: 0, count: samples.count * record)
    bytes.withUnsafeMutableBytes { raw in
      for (i, sample) in samples.enumerated() {
        let base = i * record
        raw.storeBytes(of: scaled(sample.point.x, 100).littleEndian, toByteOffset: base, as: Int32.self)
        raw.storeBytes(
          of: scaled(sample.point.y, 100).littleEndian, toByteOffset: base + 4, as: Int32.self)
        raw.storeBytes(
          of: unsigned(sample.pressure, 1000).littleEndian, toByteOffset: base + 8, as: UInt16.self)
        raw.storeBytes(
          of: unsigned(sample.altitude, 10000).littleEndian, toByteOffset: base + 10,
          as: UInt16.self)
      }
    }
    return Data(bytes).base64EncodedString()
  }

  static func unpack(_ string: String) -> [Sample]? {
    guard let data = Data(base64Encoded: string), data.count.isMultiple(of: record) else {
      return nil
    }
    return data.withUnsafeBytes { raw in
      (0..<(data.count / record)).map { i in
        let base = i * record
        return Sample(
          point: Point(
            Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: base, as: Int32.self)))
              / 100,
            Double(Int32(littleEndian: raw.loadUnaligned(fromByteOffset: base + 4, as: Int32.self)))
              / 100),
          pressure: Double(
            UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: base + 8, as: UInt16.self)))
            / 1000,
          altitude: Double(
            UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: base + 10, as: UInt16.self)))
            / 10000)
      }
    }
  }

  private static func scaled(_ value: Double, _ scale: Double) -> Int32 {
    guard value.isFinite else { return 0 }
    return Int32(max(-2_000_000_000, min(2_000_000_000, (value * scale).rounded())))
  }

  private static func unsigned(_ value: Double, _ scale: Double) -> UInt16 {
    guard value.isFinite else { return 0 }
    return UInt16(max(0, min(65535, (value * scale).rounded())))
  }
}
