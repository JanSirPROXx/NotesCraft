import Foundation

public struct Point: Codable, Hashable, Sendable {
  public var x: Double
  public var y: Double
  public init(_ x: Double, _ y: Double) {
    self.x = x
    self.y = y
  }
  public func distance(to other: Point) -> Double { hypot(x - other.x, y - other.y) }
}
public struct Rect: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
  public var originPoint: Point { Point(x, y) }
  public func contains(_ p: Point) -> Bool {
    p.x >= x && p.x <= x + width && p.y >= y && p.y <= y + height
  }
  public func intersects(_ r: Rect) -> Bool {
    x <= r.x + r.width && x + width >= r.x && y <= r.y + r.height && y + height >= r.y
  }
}
public struct InkColor: Codable, Hashable, Sendable {
  public var red: Double
  public var green: Double
  public var blue: Double
  public init(red: Double, green: Double, blue: Double) {
    self.red = red
    self.green = green
    self.blue = blue
  }
  public init?(hex: String) {
    let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard value.count == 6, let bits = UInt32(value, radix: 16) else { return nil }
    self.init(
      red: Double((bits >> 16) & 255) / 255, green: Double((bits >> 8) & 255) / 255,
      blue: Double(bits & 255) / 255)
  }
  public static let ink = InkColor(red: 0.12, green: 0.17, blue: 0.24)
  public static let blue = InkColor(red: 0.14, green: 0.37, blue: 0.83)
  public static let red = InkColor(red: 0.83, green: 0.22, blue: 0.26)
  public static let green = InkColor(red: 0.18, green: 0.55, blue: 0.40)
  public static let yellow = InkColor(red: 0.98, green: 0.80, blue: 0.20)
}
public enum InkTool: String, Codable, CaseIterable, Sendable {
  case pen, eraser, highlighter, shapes, lasso, elements, image, text, readOnly
}
public enum PenStyle: String, Codable, CaseIterable, Sendable {
  case fountain, ballpoint, brush, pencil
}
public enum EraserMode: String, Codable, CaseIterable, Sendable {
  case precision, stroke, entireStroke
}
public enum PaperPattern: String, Codable, CaseIterable, Sendable {
  case blank, ruled, dotted, squared, planner, graph, fineGraph
  public var title: String {
    switch self {
    case .blank: "Blank"
    case .ruled: "Lined"
    case .dotted: "Dotted"
    case .squared: "Large squares"
    case .planner: "Weekly planner"
    case .graph: "Grid · 5 mm"
    case .fineGraph: "Grid · 2.5 mm"
    }
  }
}
public enum PaperSize: String, Codable, CaseIterable, Sendable {
  case a4 = "A4"
  case letter = "Letter"
  public var dimensions: Point { self == .a4 ? Point(595, 842) : Point(612, 792) }
}
public struct Paper: Codable, Equatable, Sendable {
  public var size: PaperSize = .a4
  public var pattern: PaperPattern = .ruled
  public var landscape = false
  // Sheet color; nil is white. Absent in older files.
  public var color: InkColor?
  public init(
    size: PaperSize = .a4, pattern: PaperPattern = .ruled, landscape: Bool = false,
    color: InkColor? = nil
  ) {
    self.size = size
    self.pattern = pattern
    self.landscape = landscape
    self.color = color
  }
  public static let colors: [(name: String, color: InkColor?)] = [
    ("White", nil), ("Cream", InkColor(hex: "#FFF8E7")), ("Yellow", InkColor(hex: "#FEF7C3")),
    ("Blue", InkColor(hex: "#E8F0FE")), ("Mint", InkColor(hex: "#E6F4EA")),
    ("Gray", InkColor(hex: "#ECEFF1")),
  ]
  public var dimensions: Point {
    landscape ? Point(size.dimensions.y, size.dimensions.x) : size.dimensions
  }
}
public struct Sample: Codable, Equatable, Sendable {
  // Assigning (also `sample.point.x += 1`) snaps again, so an edit such as moving a selection
  // can never leave a value that would not survive a save.
  public var point: Point { didSet { point = Point(Self.snap(point.x, 100), Self.snap(point.y, 100)) } }
  public var pressure: Double { didSet { pressure = Self.snap(pressure, 1000) } }
  public var altitude: Double { didSet { altitude = Self.snap(altitude, 10000) } }
  // Samples sit on the grid they are stored at (0.01 pt, 0.001 pressure, 0.0001 rad), so what
  // is saved and read back equals what was in memory. A tip or a screen resolves far less.
  public init(point: Point, pressure: Double = 1, altitude: Double = .pi / 2) {
    self.point = Point(Self.snap(point.x, 100), Self.snap(point.y, 100))
    self.pressure = Self.snap(pressure, 1000)
    self.altitude = Self.snap(altitude, 10000)
  }
  static func snap(_ value: Double, _ scale: Double) -> Double {
    guard value.isFinite, abs(value) < 1e9 else { return value }
    return (value * scale).rounded() / scale
  }
  // A page of handwriting holds hundreds of thousands of samples, so a sample is stored as the
  // flat array `[x, y, pressure, altitude]`: roughly half the bytes and a good deal faster to
  // read and write than the keyed objects older files use. Those are still read.
  private enum LegacyKeys: String, CodingKey { case point, pressure, altitude }
  public init(from decoder: Decoder) throws {
    if var list = try? decoder.unkeyedContainer() {
      point = Point(try list.decode(Double.self), try list.decode(Double.self))
      pressure = try list.decode(Double.self)
      altitude = try list.decode(Double.self)
      return
    }
    let keyed = try decoder.container(keyedBy: LegacyKeys.self)
    point = try keyed.decode(Point.self, forKey: .point)
    pressure = try keyed.decode(Double.self, forKey: .pressure)
    altitude = try keyed.decode(Double.self, forKey: .altitude)
  }
  public func encode(to encoder: Encoder) throws {
    var list = encoder.unkeyedContainer()
    try list.encode(point.x)
    try list.encode(point.y)
    try list.encode(pressure)
    try list.encode(altitude)
  }
}
// Nib behaviour of the fountain pen, stored per stroke so changing the settings later never
// restyles ink that is already on the page. Absent in older files, which keep the default.
public struct PenTip: Codable, Equatable, Hashable, Sendable {
  public var sharpness: Double
  public var pressure: Double
  public var flatness: Double
  public init(sharpness: Double = 0.5, pressure: Double = 0.5, flatness: Double = 0) {
    self.sharpness = min(1, max(0, sharpness))
    self.pressure = min(1, max(0, pressure))
    self.flatness = min(1, max(0, flatness))
  }
  public static let standard = PenTip()
}
public struct Stroke: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var samples: [Sample]
  public var color: InkColor
  public var width: Double
  public var tool: InkTool
  public var style: PenStyle
  public var fillColor: InkColor?
  public var tip: PenTip?
  // Present on shape and sticker objects, which can be reshaped after they are placed.
  public var shape: ShapeSpec?
  // Opacity of `fillColor`; nil keeps the translucent 0.2 used for filled drawn shapes.
  public var fillOpacity: Double?
  public init(
    id: UUID = UUID(), samples: [Sample], color: InkColor = .ink, width: Double = 2,
    tool: InkTool = .pen, style: PenStyle = .ballpoint, tip: PenTip? = nil
  ) {
    self.id = id
    self.samples = samples
    self.color = color
    self.width = width
    self.tool = tool
    self.style = style
    self.tip = tip
  }
  private enum CodingKeys: String, CodingKey {
    case id, samples, color, width, tool, style, fillColor, tip, shape, fillOpacity
  }
  // Parsing numbers is what made a dense notebook slow to open and to autosave (JSON decoding
  // costs ~300 ns per number and a page holds a hundred thousand samples), so a stroke's samples
  // are one Base64 string of packed 12-byte records: see `SampleCodec`. Files that list each
  // sample as `[x, y, pressure, altitude]` or as an object still load.
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    if let packed = try? values.decode(String.self, forKey: .samples) {
      guard let decoded = SampleCodec.unpack(packed) else {
        throw DecodingError.dataCorruptedError(
          forKey: .samples, in: values, debugDescription: "Invalid packed samples.")
      }
      samples = decoded
    } else {
      samples = try values.decode([Sample].self, forKey: .samples)
    }
    color = try values.decode(InkColor.self, forKey: .color)
    width = try values.decode(Double.self, forKey: .width)
    tool = try values.decode(InkTool.self, forKey: .tool)
    style = try values.decode(PenStyle.self, forKey: .style)
    fillColor = try values.decodeIfPresent(InkColor.self, forKey: .fillColor)
    tip = try values.decodeIfPresent(PenTip.self, forKey: .tip)
    shape = try values.decodeIfPresent(ShapeSpec.self, forKey: .shape)
    fillOpacity = try values.decodeIfPresent(Double.self, forKey: .fillOpacity)
  }
  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(SampleCodec.pack(samples), forKey: .samples)
    try values.encode(color, forKey: .color)
    try values.encode(width, forKey: .width)
    try values.encode(tool, forKey: .tool)
    try values.encode(style, forKey: .style)
    try values.encodeIfPresent(fillColor, forKey: .fillColor)
    try values.encodeIfPresent(tip, forKey: .tip)
    try values.encodeIfPresent(shape, forKey: .shape)
    try values.encodeIfPresent(fillOpacity, forKey: .fillOpacity)
  }
  public var bounds: Rect {
    guard let first = samples.first else { return Rect(x: 0, y: 0, width: 0, height: 0) }
    var minX = first.point.x
    var maxX = minX
    var minY = first.point.y
    var maxY = minY
    for s in samples {
      minX = min(minX, s.point.x)
      maxX = max(maxX, s.point.x)
      minY = min(minY, s.point.y)
      maxY = max(maxY, s.point.y)
    }
    return Rect(
      x: minX - width / 2, y: minY - width / 2, width: maxX - minX + width,
      height: maxY - minY + width)
  }
}
public struct TextBox: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var origin: Point
  public var text: String
  public var size: Double = 20
  public var color: InkColor = .ink
  public var fontName: String?
  public var alignment: String?
  public var background: InkColor?
  public var border: Bool?
  public var boxWidth: Double?
  public var rotation: Double?
  public var layoutBounds: Rect {
    let width = max(1, boxWidth ?? 280)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let count = lines.reduce(0.0) { total, line in
      total + max(1, ceil(Double(line.count) * size * 0.55 / width))
    }
    return Rect(x: origin.x, y: origin.y, width: width, height: max(size * 1.5, count * size * 1.5))
  }
  public var bounds: Rect {
    let r = layoutBounds
    let angle = rotation ?? 0
    let width = abs(r.width * cos(angle)) + abs(r.height * sin(angle))
    let height = abs(r.width * sin(angle)) + abs(r.height * cos(angle))
    return Rect(
      x: r.x + (r.width - width) / 2, y: r.y + (r.height - height) / 2,
      width: width, height: height)
  }
  public func contains(_ point: Point) -> Bool {
    let r = layoutBounds
    let center = Point(r.x + r.width / 2, r.y + r.height / 2)
    let x = point.x - center.x
    let y = point.y - center.y
    let angle = -(rotation ?? 0)
    return r.contains(
      Point(
        center.x + x * cos(angle) - y * sin(angle),
        center.y + x * sin(angle) + y * cos(angle)))
  }
  public init(origin: Point, text: String) {
    self.origin = origin
    self.text = text
  }
}
public struct PageAsset: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var filename: String
  public var frame: Rect
  public var rotation: Double = 0
  public var bounds: Rect {
    let width = abs(frame.width * cos(rotation)) + abs(frame.height * sin(rotation))
    let height = abs(frame.width * sin(rotation)) + abs(frame.height * cos(rotation))
    return Rect(
      x: frame.x + (frame.width - width) / 2, y: frame.y + (frame.height - height) / 2,
      width: width, height: height)
  }
  public func contains(_ point: Point) -> Bool {
    let center = Point(frame.x + frame.width / 2, frame.y + frame.height / 2)
    let x = point.x - center.x
    let y = point.y - center.y
    return frame.contains(
      Point(
        center.x + x * cos(rotation) + y * sin(rotation),
        center.y - x * sin(rotation) + y * cos(rotation)))
  }
  public init(filename: String, frame: Rect) {
    self.filename = filename
    self.frame = frame
  }
}
public struct Page: Codable, Equatable, Identifiable, Sendable {
  public var id = UUID()
  public var paper: Paper
  public var strokes: [Stroke] = []
  public var texts: [TextBox] = []
  public var images: [PageAsset] = []
  public var backgroundPDF: String?
  public var backgroundPage: Int?
  public var backgroundSize: Point?
  public var bookmarked = false
  public var dimensions: Point { backgroundSize ?? paper.dimensions }
  public init(paper: Paper = Paper()) { self.paper = paper }
}
public enum NotebookKind: String, Codable, Sendable { case notebook, whiteboard }
public struct Notebook: Codable, Equatable, Sendable {
  public var viewport: ViewTransform?
  public var kind: NotebookKind?
  public var id = UUID()
  public var title: String
  public var pages: [Page]
  public var revision: UInt64 = 0
  public init(title: String = "Untitled notebook", pages: [Page] = [Page()]) {
    self.title = title
    self.pages = pages
  }
}
public struct ViewTransform: Codable, Sendable, Equatable {
  public var scale: Double
  public var offset: Point
  public init(scale: Double, offset: Point) {
    self.scale = max(0.0001, scale)
    self.offset = offset
  }
  public func documentPoint(_ view: Point) -> Point {
    Point((view.x - offset.x) / scale, (view.y - offset.y) / scale)
  }
  public func viewPoint(_ document: Point) -> Point {
    Point(document.x * scale + offset.x, document.y * scale + offset.y)
  }
}

extension Stroke {
  // Pencil ink is drawn in groups with the paper grain multiplied in, so the renderers need to tell
  // it from plain ink. Shapes keep their clean outline whatever pen style was active.
  public var isPencil: Bool { tool == .pen && style == .pencil && shape == nil }
}
