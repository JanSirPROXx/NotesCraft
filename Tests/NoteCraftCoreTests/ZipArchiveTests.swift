import Foundation
import Testing

@testable import NoteCraftCore

// An archive made by another program (Python's zipfile): deflated and stored files, an empty one, and a folder.
private let foreign = Data(
  base64Encoded:
    "UEsDBBQAAAAIADd8WV0GoYQUEgAAAAQBAAAJAAAAcGFjay5qc29uq1ZKyy/KTSxRsjKs5aoemRwAUEsDBBQAAAAIADd8WV0NLq0lFQAAAFgCAAASAAAAY29udGVudC9yZWFkbWUudHh0y0jNyclXKM8vyklRyBhlj7KpxAYAUEsDBBQAAAAIADd8WV0AAAAAAgAAAAAAAAARAAAAY29udGVudC9lbXB0eS50eHQDAFBLAwQUAAAAAAAAACEAAAAAAAAAAAAAAAAADAAAAGNvbnRlbnQvZGlyL1BLAwQUAAAAAAA3fFldc4wFKQABAAAAAQAAEgAAAGNvbnRlbnQvc3RvcmVkLmJpbgABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj9AQUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVpbXF1eX2BhYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5ent8fX5/gIGCg4SFhoeIiYqLjI2Oj5CRkpOUlZaXmJmam5ydnp+goaKjpKWmp6ipqqusra6vsLGys7S1tre4ubq7vL2+v8DBwsPExcbHyMnKy8zNzs/Q0dLT1NXW19jZ2tvc3d7f4OHi4+Tl5ufo6err7O3u7/Dx8vP09fb3+Pn6+/z9/v9QSwECFAMUAAAACAA3fFldBqGEFBIAAAAEAQAACQAAAAAAAAAAAAAAgAEAAAAAcGFjay5qc29uUEsBAhQDFAAAAAgAN3xZXQ0urSUVAAAAWAIAABIAAAAAAAAAAAAAAIABOQAAAGNvbnRlbnQvcmVhZG1lLnR4dFBLAQIUAxQAAAAIADd8WV0AAAAAAgAAAAAAAAARAAAAAAAAAAAAAACAAX4AAABjb250ZW50L2VtcHR5LnR4dFBLAQIUAxQAAAAAAAAAIQAAAAAAAAAAAAAAAAAMAAAAAAAAAAAAAACAAa8AAABjb250ZW50L2Rpci9QSwECFAMUAAAAAAA3fFldc4wFKQABAAAAAQAAEgAAAAAAAAAAAAAAgAHZAAAAY29udGVudC9zdG9yZWQuYmluUEsFBgAAAAAFAAUAMAEAAAkCAAAAAA=="
)!

@Test func anArchiveFromAnotherProgramIsRead() throws {
  let files = try ZipArchive.read(foreign)
  #expect(Set(files.keys) == ["pack.json", "content/readme.txt", "content/empty.txt", "content/stored.bin"])
  #expect(files["pack.json"] == Data(String(repeating: "{\"format\":1}\n", count: 20).utf8))
  #expect(files["content/readme.txt"] == Data(String(repeating: "hello world ", count: 50).utf8))
  #expect(files["content/empty.txt"] == Data())
  #expect(files["content/stored.bin"] == Data(0...255))
}

@Test func whatIsWrittenIsReadBackAndTheSameFilesMakeTheSameBytes() throws {
  var noise = Data()
  var state: UInt64 = 42
  for _ in 0..<4000 {
    state = state &* 6_364_136_223_846_793_005 &+ 1
    noise.append(UInt8(truncatingIfNeeded: state >> 33))
  }
  let files: [String: Data] = [
    "pack.json": Data("{}".utf8), "content/a.txt": Data(String(repeating: "abc", count: 500).utf8),
    "content/noise.bin": noise, "content/empty": Data(),
  ]
  let archive = try ZipArchive.write(files)
  #expect(try ZipArchive.read(archive) == files)
  #expect(try ZipArchive.write(files) == archive, "no dates or order of a dictionary in the bytes")
  #expect(archive.count < files.values.reduce(0) { $0 + $1.count }, "the text was deflated")
}

@Test func somethingThatIsNotAnArchiveIsRefused() {
  #expect(throws: ZipError.notAZip) { try ZipArchive.read(Data(repeating: 7, count: 500)) }
  #expect(throws: ZipError.notAZip) { try ZipArchive.read(Data()) }
  #expect(throws: ZipError.notAZip) { try ZipArchive.read(foreign.prefix(foreign.count - 10)) }
}

@Test func aPathThatCouldLeaveTheFolderIsRefused() throws {
  for bad in ["../x", "/etc/x", "a/../b", "a\\b", "a//b", "./a", "~root/a", ""] {
    #expect(throws: ZipError.unsafePath(bad), "\(bad)") { try ZipArchive.validate(path: bad) }
  }
  try ZipArchive.validate(path: "content/fonts/My Font-Regular.ttf")
  // And one that was changed inside an archive that was valid.
  var archive = try ZipArchive.write(["xx/b.txt": Data("hi".utf8)])
  let from = Data("xx/b.txt".utf8)
  let to = Data("../b.txt".utf8)
  while let range = archive.range(of: from) { archive.replaceSubrange(range, with: to) }
  #expect(throws: ZipError.unsafePath("../b.txt")) { try ZipArchive.read(archive) }
}

@Test func twoFilesWithTheSameNameAreRefused() throws {
  let archive = try ZipArchive.write(["ab.txt": Data("1".utf8), "AB.txt": Data("2".utf8)])
  #expect(throws: ZipError.self) { try ZipArchive.read(archive) }
}

@Test func aLinkIsRefused() throws {
  var archive = try ZipArchive.write(["a.txt": Data("target".utf8)])
  // The attributes of the file in the central directory: a regular file, mode 644 ...
  let regular = Data([0x00, 0x00, 0xA4, 0x81])
  let link = Data([0x00, 0x00, 0xFF, 0xA1])  // ... and a symbolic link, mode 777.
  let range = try #require(archive.range(of: regular))
  archive.replaceSubrange(range, with: link)
  #expect(throws: ZipError.unsafePath("a.txt")) { try ZipArchive.read(archive) }
}

@Test func anEncryptedFileIsRefused() throws {
  var archive = try ZipArchive.write(["a.txt": Data("x".utf8)])
  let central = try #require(archive.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
  archive[central.lowerBound + 8] |= 1
  #expect(throws: ZipError.unsupported("a password")) { try ZipArchive.read(archive) }
}

@Test func limitsAreKeptBeforeAnythingIsUnpacked() throws {
  let archive = try ZipArchive.write([
    "a.txt": Data(repeating: 65, count: 5000), "b.txt": Data(repeating: 66, count: 5000),
  ])
  var one = ZipLimits()
  one.maxEntryBytes = 1000
  #expect(throws: ZipError.tooLarge("“a.txt”")) { try ZipArchive.read(archive, limits: one) }
  var total = ZipLimits()
  total.maxTotalBytes = 7000
  #expect(throws: ZipError.tooLarge("The pack")) { try ZipArchive.read(archive, limits: total) }
  var count = ZipLimits()
  count.maxEntries = 1
  #expect(throws: ZipError.tooManyEntries) { try ZipArchive.read(archive, limits: count) }
  var bytes = ZipLimits()
  bytes.maxArchiveBytes = 10
  #expect(throws: ZipError.tooLarge("The pack")) { try ZipArchive.read(archive, limits: bytes) }
}

@Test func damagedDataIsNoticed() throws {
  var archive = try ZipArchive.write(["a.txt": Data(String(repeating: "damage", count: 100).utf8)])
  // A byte inside the deflated data, past the local header (30 + the name).
  archive[40] ^= 0x55
  #expect(throws: ZipError.corrupt("a.txt")) { try ZipArchive.read(archive) }
  var stored = try ZipArchive.write(["b.bin": Data([1, 2, 3])])
  stored[30 + 5] ^= 0xFF
  #expect(throws: ZipError.corrupt("b.bin")) { try ZipArchive.read(stored) }
}

@Test func aFileThatClaimsLessThanItHoldsIsRefused() throws {
  // The sizes in the central directory say 100 bytes, the stream holds 5000.
  var archive = try ZipArchive.write(["a.txt": Data(repeating: 65, count: 5000)])
  let central = try #require(archive.range(of: Data([0x50, 0x4B, 0x01, 0x02])))
  let sizeAt = central.lowerBound + 24
  archive.replaceSubrange(sizeAt..<(sizeAt + 4), with: Data([100, 0, 0, 0]))
  #expect(throws: ZipError.corrupt("a.txt")) { try ZipArchive.read(archive) }
}
