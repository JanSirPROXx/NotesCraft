import Compression
import Foundation

// Reads and writes the zip files that packs of the marketplace come in. Only what a pack needs:
// stored and deflated files, no encryption, no zip64, no links. A pack comes from the internet, so
// everything is checked against limits before it is allocated, and a path that could leave the folder
// it is unpacked into is refused.
public enum ZipError: Error, Equatable, LocalizedError {
  case notAZip
  case unsupported(String)
  case unsafePath(String)
  case duplicate(String)
  case tooLarge(String)
  case tooManyEntries
  case corrupt(String)

  public var errorDescription: String? {
    switch self {
    case .notAZip: "This is not a pack file."
    case .unsupported(let what): "The pack uses \(what), which is not supported."
    case .unsafePath(let path): "The pack holds “\(path)”, a path that is not allowed."
    case .duplicate(let path): "The pack holds “\(path)” twice."
    case .tooLarge(let what): "\(what) is too large."
    case .tooManyEntries: "The pack has too many files."
    case .corrupt(let path): "“\(path)” in the pack is damaged."
    }
  }
}

public struct ZipLimits: Equatable, Sendable {
  public var maxEntries = 600
  public var maxEntryBytes = 25 * 1024 * 1024
  public var maxTotalBytes = 60 * 1024 * 1024
  public var maxArchiveBytes = 25 * 1024 * 1024
  public init() {}
  public static let pack = ZipLimits()
}

public enum ZipArchive {
  // MARK: reading

  // All the files of an archive, by path. Folders are not listed.
  public static func read(_ data: Data, limits: ZipLimits = .pack) throws -> [String: Data] {
    guard data.count <= limits.maxArchiveBytes else { throw ZipError.tooLarge("The pack") }
    guard data.count >= 22 else { throw ZipError.notAZip }
    let bytes = [UInt8](data)

    func u16(_ offset: Int) -> Int {
      Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }
    func u32(_ offset: Int) -> Int {
      Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
        | Int(bytes[offset + 3]) << 24
    }

    // The end of central directory record is within the last 64 KB.
    var end = -1
    var offset = bytes.count - 22
    let floor = max(0, bytes.count - 22 - 65_535)
    while offset >= floor {
      if u32(offset) == 0x0605_4b50 {
        end = offset
        break
      }
      offset -= 1
    }
    guard end >= 0 else { throw ZipError.notAZip }
    let entryCount = u16(end + 10)
    let directorySize = u32(end + 12)
    let directoryOffset = u32(end + 16)
    if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
      throw ZipError.unsupported("zip64")
    }
    guard entryCount <= limits.maxEntries else { throw ZipError.tooManyEntries }
    guard directoryOffset + directorySize <= end else { throw ZipError.notAZip }

    var files: [String: Data] = [:]
    var seen = Set<String>()
    var total = 0
    var cursor = directoryOffset
    for _ in 0..<entryCount {
      guard cursor + 46 <= bytes.count, u32(cursor) == 0x0201_4b50 else { throw ZipError.notAZip }
      let madeBy = u16(cursor + 4) >> 8
      let flags = u16(cursor + 8)
      let method = u16(cursor + 10)
      let crc = UInt32(truncatingIfNeeded: u32(cursor + 16))
      let compressed = u32(cursor + 20)
      let size = u32(cursor + 24)
      let nameLength = u16(cursor + 28)
      let extraLength = u16(cursor + 30)
      let commentLength = u16(cursor + 32)
      let attributes = u32(cursor + 38)
      let localOffset = u32(cursor + 42)
      guard cursor + 46 + nameLength + extraLength + commentLength <= bytes.count else {
        throw ZipError.notAZip
      }
      let nameBytes = bytes[(cursor + 46)..<(cursor + 46 + nameLength)]
      guard let name = String(bytes: nameBytes, encoding: .utf8) else {
        throw ZipError.unsafePath(String(decoding: nameBytes, as: UTF8.self))
      }
      cursor += 46 + nameLength + extraLength + commentLength

      let isFolder = name.hasSuffix("/")
      try validate(path: isFolder ? String(name.dropLast()) : name)
      guard seen.insert(name.lowercased()).inserted else { throw ZipError.duplicate(name) }
      if flags & 1 != 0 { throw ZipError.unsupported("a password") }
      // A link is a unix file whose mode says so.
      if madeBy == 3, (attributes >> 16) & 0xF000 == 0xA000 { throw ZipError.unsafePath(name) }
      if isFolder { continue }
      guard method == 0 || method == 8 else { throw ZipError.unsupported("compression \(method)") }
      if compressed == 0xFFFF_FFFF || size == 0xFFFF_FFFF { throw ZipError.unsupported("zip64") }
      guard size <= limits.maxEntryBytes else { throw ZipError.tooLarge("“\(name)”") }
      total += size
      guard total <= limits.maxTotalBytes else { throw ZipError.tooLarge("The pack") }

      // The data sits after the local header, whose own lengths of name and extra may differ.
      guard localOffset + 30 <= bytes.count, u32(localOffset) == 0x0403_4b50 else {
        throw ZipError.corrupt(name)
      }
      let start = localOffset + 30 + u16(localOffset + 26) + u16(localOffset + 28)
      guard start + compressed <= directoryOffset else { throw ZipError.corrupt(name) }
      let payload = Data(bytes[start..<(start + compressed)])

      let content: Data
      if method == 0 {
        guard compressed == size else { throw ZipError.corrupt(name) }
        content = payload
      } else {
        content = try inflate(payload, size: size, name: name)
      }
      guard crc32(content) == crc else { throw ZipError.corrupt(name) }
      files[name] = content
    }
    return files
  }

  // A path that stays inside the folder it is unpacked into: relative, with plain names.
  public static func validate(path: String) throws {
    guard !path.isEmpty, path.count <= 200, !path.hasPrefix("/"), !path.contains("\\"),
      !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    else { throw ZipError.unsafePath(path) }
    for part in path.split(separator: "/", omittingEmptySubsequences: false) {
      guard !part.isEmpty, part != ".", part != "..", !part.hasPrefix("~") else {
        throw ZipError.unsafePath(path)
      }
    }
  }

  private static func inflate(_ payload: Data, size: Int, name: String) throws -> Data {
    if size == 0 { return Data() }
    // One byte more than the file should have: a stream that has more to give is not the size it
    // says, and is told apart from one that has exactly this much.
    let capacity = size + 1
    var output = [UInt8](repeating: 0, count: capacity)
    let written = payload.withUnsafeBytes { source -> Int in
      guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
      return output.withUnsafeMutableBufferPointer { target in
        compression_decode_buffer(
          target.baseAddress!, capacity, base, payload.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard written == size else { throw ZipError.corrupt(name) }
    return Data(output[0..<size])
  }

  // MARK: writing

  // An archive of the files, in the order of their paths, so the same files always make the same
  // bytes (and the same hash).
  public static func write(_ files: [String: Data]) throws -> Data {
    var out = Data()
    var central = Data()
    var count = 0
    func put16(_ value: Int, to data: inout Data) {
      data.append(UInt8(value & 0xFF))
      data.append(UInt8((value >> 8) & 0xFF))
    }
    func put32(_ value: Int, to data: inout Data) {
      for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> shift) & 0xFF)) }
    }
    for path in files.keys.sorted() {
      try validate(path: path)
      let content = files[path]!
      var method = 0
      var payload = content
      if !content.isEmpty, let deflated = deflate(content), deflated.count < content.count {
        method = 8
        payload = deflated
      }
      let name = Data(path.utf8)
      let crc = Int(crc32(content))
      let offset = out.count
      // Local header.
      put32(0x0403_4b50, to: &out)
      put16(20, to: &out)
      put16(0x0800, to: &out)  // names are UTF-8
      put16(method, to: &out)
      put16(0, to: &out)  // time: 00:00
      put16(0x0021, to: &out)  // date: 1980-01-01
      put32(crc, to: &out)
      put32(payload.count, to: &out)
      put32(content.count, to: &out)
      put16(name.count, to: &out)
      put16(0, to: &out)
      out.append(name)
      out.append(payload)
      // Central directory header.
      put32(0x0201_4b50, to: &central)
      put16(0x031E, to: &central)  // made by unix, version 3.0
      put16(20, to: &central)
      put16(0x0800, to: &central)
      put16(method, to: &central)
      put16(0, to: &central)
      put16(0x0021, to: &central)
      put32(crc, to: &central)
      put32(payload.count, to: &central)
      put32(content.count, to: &central)
      put16(name.count, to: &central)
      put16(0, to: &central)
      put16(0, to: &central)
      put16(0, to: &central)
      put16(0, to: &central)
      put32(0o100644 << 16, to: &central)
      put32(offset, to: &central)
      central.append(name)
      count += 1
    }
    let directoryOffset = out.count
    out.append(central)
    put32(0x0605_4b50, to: &out)
    put16(0, to: &out)
    put16(0, to: &out)
    put16(count, to: &out)
    put16(count, to: &out)
    put32(central.count, to: &out)
    put32(directoryOffset, to: &out)
    put16(0, to: &out)
    return out
  }

  private static func deflate(_ data: Data) -> Data? {
    let capacity = data.count + 1024
    var output = [UInt8](repeating: 0, count: capacity)
    let written = data.withUnsafeBytes { source -> Int in
      guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
      return output.withUnsafeMutableBufferPointer { target in
        compression_encode_buffer(
          target.baseAddress!, capacity, base, data.count, nil, COMPRESSION_ZLIB)
      }
    }
    return written > 0 ? Data(output[0..<written]) : nil
  }

  // MARK: checksum

  private static let table: [UInt32] = (0..<256).map { index in
    var value = UInt32(index)
    for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    return value
  }

  static func crc32(_ data: Data) -> UInt32 {
    var value: UInt32 = 0xFFFF_FFFF
    for byte in data { value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
    return value ^ 0xFFFF_FFFF
  }
}
