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
public enum PenStyle: String, Codable, CaseIterable, Sendable { case fountain, ballpoint, brush }
public enum EraserMode: String, Codable, CaseIterable, Sendable {
  case precision, stroke, entireStroke
}
public enum PaperPattern: String, Codable, CaseIterable, Sendable {
  case blank, ruled, dotted, squared, planner
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
  public init(size: PaperSize = .a4, pattern: PaperPattern = .ruled, landscape: Bool = false) {
    self.size = size
    self.pattern = pattern
    self.landscape = landscape
  }
  public var dimensions: Point {
    landscape ? Point(size.dimensions.y, size.dimensions.x) : size.dimensions
  }
}
public struct Sample: Codable, Equatable, Sendable {
  public var point: Point
  public var pressure: Double
  public var altitude: Double
  public init(point: Point, pressure: Double = 1, altitude: Double = .pi / 2) {
    self.point = point
    self.pressure = pressure
    self.altitude = altitude
  }
}
public struct Stroke: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var samples: [Sample]
  public var color: InkColor
  public var width: Double
  public var tool: InkTool
  public var style: PenStyle
  public var fillColor: InkColor?
  public init(
    id: UUID = UUID(), samples: [Sample], color: InkColor = .ink, width: Double = 2,
    tool: InkTool = .pen, style: PenStyle = .ballpoint
  ) {
    self.id = id
    self.samples = samples
    self.color = color
    self.width = width
    self.tool = tool
    self.style = style
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
  public var bounds: Rect {
    let width = max(1, boxWidth ?? 280)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let count = lines.reduce(0.0) { total, line in
      total + max(1, ceil(Double(line.count) * size * 0.55 / width))
    }
    return Rect(x: origin.x, y: origin.y, width: width, height: max(size * 1.5, count * size * 1.5))
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
