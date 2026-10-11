import Foundation

// Editable vector objects. A shape or sticker is stored as a normal `Stroke` whose samples are the
// outline, plus a `ShapeSpec` that remembers how the outline was built. Everything that already
// understands strokes (lasso, erasing, copy, export) keeps working, and the spec lets the editor
// stretch, rotate and recolor the object without degrading it.
public enum ShapeKind: String, Codable, CaseIterable, Sendable {
  case line, arrow, rightAngle, rectangle, roundedRectangle, ellipse, triangle, rightTriangle
  case diamond, pentagon, hexagon
  case star, heart, check, cross, plus, bolt, cloud, speechBubble, moon, sun, blockArrow, flag, drop

  public static let shapes: [ShapeKind] = [
    .line, .arrow, .rightAngle, .rectangle, .roundedRectangle, .ellipse, .triangle,
    .rightTriangle, .diamond, .pentagon, .hexagon,
  ]
  public static let stickers: [ShapeKind] = [
    .star, .heart, .check, .cross, .plus, .bolt, .cloud, .speechBubble, .moon, .sun, .blockArrow,
    .flag, .drop,
  ]
  public var isSticker: Bool { Self.stickers.contains(self) }
  // Open outlines are stroked only; closed outlines may be filled.
  public var isClosed: Bool { ![.line, .arrow, .rightAngle].contains(self) }
  // Lines have no height, so only their length can be stretched.
  public var isLinear: Bool { [.line, .arrow].contains(self) }
  public var title: String {
    switch self {
    case .line: "Line"
    case .arrow: "Arrow"
    case .rightAngle: "Right angle"
    case .rectangle: "Rectangle"
    case .roundedRectangle: "Rounded rectangle"
    case .ellipse: "Ellipse"
    case .triangle: "Triangle"
    case .rightTriangle: "Right triangle"
    case .diamond: "Diamond"
    case .pentagon: "Pentagon"
    case .hexagon: "Hexagon"
    case .star: "Star"
    case .heart: "Heart"
    case .check: "Check mark"
    case .cross: "Cross"
    case .plus: "Plus"
    case .bolt: "Lightning"
    case .cloud: "Cloud"
    case .speechBubble: "Speech bubble"
    case .moon: "Moon"
    case .sun: "Sun"
    case .blockArrow: "Block arrow"
    case .flag: "Flag"
    case .drop: "Drop"
    }
  }
  // Size used when the page is tapped instead of dragged.
  public var defaultSize: Point {
    switch self {
    case .line, .arrow: Point(150, 0)
    case .rightAngle: Point(90, 90)
    case .rectangle, .roundedRectangle, .rightTriangle: Point(150, 100)
    case .ellipse, .triangle, .diamond: Point(130, 110)
    case .speechBubble, .cloud, .blockArrow, .flag: Point(110, 90)
    default: Point(90, 90)
    }
  }
  // Stickers arrive colored; shapes use the current pen color.
  public var stickerColor: InkColor? {
    switch self {
    case .star: InkColor(hex: "#FACC15")
    case .heart: InkColor(hex: "#EF4444")
    case .check: InkColor(hex: "#22C55E")
    case .cross: InkColor(hex: "#EF4444")
    case .plus: InkColor(hex: "#3B82F6")
    case .bolt: InkColor(hex: "#F59E0B")
    case .cloud: InkColor(hex: "#93C5FD")
    case .speechBubble: InkColor(hex: "#E9D5FF")
    case .moon: InkColor(hex: "#FDE68A")
    case .sun: InkColor(hex: "#FB923C")
    case .blockArrow: InkColor(hex: "#3B82F6")
    case .flag: InkColor(hex: "#EF4444")
    case .drop: InkColor(hex: "#38BDF8")
    default: nil
    }
  }
}

public struct ShapeSpec: Codable, Equatable, Sendable {
  public var kind: ShapeKind
  public var center: Point
  public var width: Double
  public var height: Double
  public var rotation: Double
  public init(kind: ShapeKind, center: Point, width: Double, height: Double, rotation: Double = 0) {
    self.kind = kind
    self.center = center
    self.width = width
    self.height = height
    self.rotation = rotation
  }
  public var outline: [Point] { ShapeGeometry.outline(self) }
}

extension InkColor {
  public func darkened(_ amount: Double = 0.35) -> InkColor {
    InkColor(red: red * (1 - amount), green: green * (1 - amount), blue: blue * (1 - amount))
  }
}

extension Stroke {
  // A shape object: outline samples plus the spec that regenerates them.
  public static func shape(
    _ spec: ShapeSpec, color: InkColor, width: Double, fill: InkColor? = nil,
    fillOpacity: Double? = nil
  ) -> Stroke {
    var stroke = Stroke(
      samples: spec.outline.map { Sample(point: $0) }, color: color, width: width, tool: .shapes)
    stroke.shape = spec
    stroke.fillColor = fill
    stroke.fillOpacity = fillOpacity
    return stroke
  }
  // A ready-made sticker: solid fill with a darker outline of the same hue.
  public static func sticker(_ kind: ShapeKind, at center: Point, size: Point? = nil) -> Stroke {
    let size = size ?? kind.defaultSize
    return sticker(ShapeSpec(kind: kind, center: center, width: size.x, height: size.y))
  }
  public static func sticker(_ spec: ShapeSpec) -> Stroke {
    let fill = spec.kind.stickerColor ?? .ink
    return .shape(spec, color: fill.darkened(), width: 2.5, fill: fill, fillOpacity: 1)
  }
  public mutating func reshape(_ spec: ShapeSpec) {
    shape = spec
    samples = spec.outline.map { Sample(point: $0) }
  }
  // Recoloring a solid sticker keeps its outline a shade darker than the fill.
  public mutating func recolor(_ ink: InkColor) {
    if fillOpacity == 1 {
      fillColor = ink
      color = ink.darkened()
    } else {
      color = ink
      if fillColor != nil { fillColor = ink }
    }
  }
}

public enum ShapeGeometry {
  public static func outline(_ spec: ShapeSpec) -> [Point] {
    let w = max(0, spec.width)
    let h = max(0, spec.height)
    var local = localOutline(spec.kind, w: w, h: h)
    if spec.kind.isClosed, let first = local.first, local.last != first { local.append(first) }
    let c = cos(spec.rotation)
    let s = sin(spec.rotation)
    return local.map {
      Point(spec.center.x + $0.x * c - $0.y * s, spec.center.y + $0.x * s + $0.y * c)
    }
  }

  // Local coordinates: origin at the center, x right, y down, within ±w/2, ±h/2.
  private static func localOutline(_ kind: ShapeKind, w: Double, h: Double) -> [Point] {
    func box(_ unit: [Point]) -> [Point] { unit.map { Point($0.x * w, $0.y * h) } }
    switch kind {
    case .line:
      return [Point(-w / 2, 0), Point(w / 2, 0)]
    case .arrow:
      let head = min(max(10, w * 0.25), 26)
      return [
        Point(-w / 2, 0), Point(w / 2, 0), Point(w / 2 - head, -head * 0.55), Point(w / 2, 0),
        Point(w / 2 - head, head * 0.55),
      ]
    case .rightAngle:
      let m = min(w, h, 22) * 0.55
      return [
        Point(-w / 2, -h / 2), Point(-w / 2, h / 2), Point(-w / 2 + m, h / 2),
        Point(-w / 2 + m, h / 2 - m), Point(-w / 2, h / 2 - m), Point(-w / 2, h / 2),
        Point(w / 2, h / 2),
      ]
    case .rectangle:
      return [
        Point(-w / 2, -h / 2), Point(w / 2, -h / 2), Point(w / 2, h / 2), Point(-w / 2, h / 2),
      ]
    case .roundedRectangle:
      let r = min(w, h) * 0.2
      var points: [Point] = []
      let corners = [
        (Point(w / 2 - r, -h / 2 + r), -Double.pi / 2), (Point(w / 2 - r, h / 2 - r), 0),
        (Point(-w / 2 + r, h / 2 - r), Double.pi / 2),
        (Point(-w / 2 + r, -h / 2 + r), Double.pi),
      ]
      for (center, start) in corners {
        for step in 0...8 {
          let a = start + Double(step) / 8 * Double.pi / 2
          points.append(Point(center.x + r * cos(a), center.y + r * sin(a)))
        }
      }
      return points
    case .ellipse:
      return (0..<72).map {
        let a = Double($0) / 72 * 2 * Double.pi
        return Point(w / 2 * cos(a), h / 2 * sin(a))
      }
    case .triangle:
      return [Point(0, -h / 2), Point(w / 2, h / 2), Point(-w / 2, h / 2)]
    case .rightTriangle:
      return [Point(-w / 2, -h / 2), Point(-w / 2, h / 2), Point(w / 2, h / 2)]
    case .diamond:
      return [Point(0, -h / 2), Point(w / 2, 0), Point(0, h / 2), Point(-w / 2, 0)]
    case .pentagon:
      return fit(regular(5), w: w, h: h)
    case .hexagon:
      return fit(regular(6, start: 0), w: w, h: h)
    case .star:
      return fit(
        (0..<10).map {
          let a = Double($0) * Double.pi / 5 - Double.pi / 2
          let r = $0 % 2 == 0 ? 1.0 : 0.42
          return Point(r * cos(a), r * sin(a))
        }, w: w, h: h)
    case .heart:
      return fit(
        (0..<64).map {
          let t = Double($0) / 64 * 2 * Double.pi
          let x = 16 * pow(sin(t), 3)
          let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
          return Point(x, -y)
        }, w: w, h: h)
    case .check:
      return fit(
        [
          Point(0.00, 0.56), Point(0.12, 0.44), Point(0.38, 0.68), Point(0.88, 0.12),
          Point(1.00, 0.24), Point(0.38, 0.94),
        ], w: w, h: h)
    case .cross:
      return fit(plusPoints(arm: 0.3).map { Point(($0.x - $0.y) * 0.7071, ($0.x + $0.y) * 0.7071) },
        w: w, h: h)
    case .plus:
      return fit(plusPoints(arm: 0.34), w: w, h: h)
    case .bolt:
      return fit(
        [
          Point(0.62, 0.0), Point(0.12, 0.58), Point(0.46, 0.58), Point(0.34, 1.0),
          Point(0.88, 0.36), Point(0.54, 0.36), Point(0.72, 0.0),
        ], w: w, h: h)
    case .cloud:
      return fit(
        unionOutline([
          (0.26, 0.62, 0.2), (0.44, 0.42, 0.26), (0.7, 0.46, 0.22), (0.82, 0.66, 0.16),
          (0.5, 0.68, 0.24),
        ]), w: w, h: h)
    case .speechBubble:
      let r = 0.12
      func arc(_ cx: Double, _ cy: Double, _ start: Double) -> [Point] {
        (0...6).map {
          let a = start + Double($0) / 6 * Double.pi / 2
          return Point(cx + r * cos(a), cy + r * sin(a))
        }
      }
      let bottom = 0.76
      var points: [Point] = []
      points += arc(1 - r, r, -Double.pi / 2)
      points += arc(1 - r, bottom - r, 0)
      points += [Point(0.46, bottom), Point(0.16, 1.0), Point(0.24, bottom)]
      points += arc(r, bottom - r, Double.pi / 2)
      points += arc(r, r, Double.pi)
      return fit(points, w: w, h: h)
    case .moon:
      return fit(crescent(), w: w, h: h)
    case .sun:
      var points: [Point] = []
      let rays = 12
      for k in 0..<rays {
        let base = Double(k) / Double(rays) * 2 * Double.pi
        let step = 2 * Double.pi / Double(rays)
        points.append(polar(base - step * 0.18, 0.62))
        points.append(polar(base, 1.0))
        points.append(polar(base + step * 0.18, 0.62))
        points.append(polar(base + step * 0.5, 0.58))
      }
      return fit(points, w: w, h: h)
    case .blockArrow:
      return fit(
        [
          Point(0, 0.3), Point(0.58, 0.3), Point(0.58, 0), Point(1, 0.5), Point(0.58, 1),
          Point(0.58, 0.7), Point(0, 0.7),
        ], w: w, h: h)
    case .flag:
      return fit(
        [
          Point(0, 0), Point(0.95, 0.02), Point(0.78, 0.27), Point(0.95, 0.52), Point(0.1, 0.52),
          Point(0.1, 1), Point(0, 1),
        ], w: w, h: h)
    case .drop:
      return fit(
        (0..<64).map {
          let t = Double($0) / 64 * 2 * Double.pi
          return Point(sin(t) * pow(sin(t / 2), 1.2), -cos(t))
        }, w: w, h: h)
    }
  }

  private static func polar(_ angle: Double, _ radius: Double) -> Point {
    Point(radius * cos(angle), radius * sin(angle))
  }
  private static func regular(_ sides: Int, start: Double = -Double.pi / 2) -> [Point] {
    (0..<sides).map { polar(start + Double($0) / Double(sides) * 2 * Double.pi, 1) }
  }
  private static func plusPoints(arm a: Double) -> [Point] {
    [
      Point(-a / 2, -0.5), Point(a / 2, -0.5), Point(a / 2, -a / 2), Point(0.5, -a / 2),
      Point(0.5, a / 2), Point(a / 2, a / 2), Point(a / 2, 0.5), Point(-a / 2, 0.5),
      Point(-a / 2, a / 2), Point(-0.5, a / 2), Point(-0.5, -a / 2), Point(-a / 2, -a / 2),
    ]
  }
  // Scale an outline of arbitrary extent to fill the ±w/2, ±h/2 box.
  private static func fit(_ points: [Point], w: Double, h: Double) -> [Point] {
    guard let first = points.first else { return [] }
    var minX = first.x
    var maxX = first.x
    var minY = first.y
    var maxY = first.y
    for p in points {
      minX = min(minX, p.x)
      maxX = max(maxX, p.x)
      minY = min(minY, p.y)
      maxY = max(maxY, p.y)
    }
    let sx = maxX > minX ? w / (maxX - minX) : 0
    let sy = maxY > minY ? h / (maxY - minY) : 0
    return points.map {
      Point(($0.x - (minX + maxX) / 2) * sx, ($0.y - (minY + maxY) / 2) * sy)
    }
  }
  // Boundary of a union of circles, ordered around their centroid.
  private static func unionOutline(_ circles: [(Double, Double, Double)]) -> [Point] {
    var points: [Point] = []
    for (cx, cy, r) in circles {
      for step in 0..<90 {
        let a = Double(step) / 90 * 2 * Double.pi
        let p = Point(cx + r * cos(a), cy + r * sin(a))
        let inside = circles.contains { other in
          (other.0 != cx || other.1 != cy) && hypot(p.x - other.0, p.y - other.1) < other.2 - 0.002
        }
        if !inside { points.append(p) }
      }
    }
    let mx = circles.reduce(0) { $0 + $1.0 } / Double(circles.count)
    let my = circles.reduce(0) { $0 + $1.1 } / Double(circles.count)
    return points.sorted { atan2($0.y - my, $0.x - mx) < atan2($1.y - my, $1.x - mx) }
  }
  private static func crescent() -> [Point] {
    let outer = (x: 0.5, y: 0.5, r: 0.5)
    let inner = (x: 0.74, y: 0.4, r: 0.4)
    let count = 160
    func circle(_ c: (x: Double, y: Double, r: Double)) -> [Point] {
      (0..<count).map {
        let a = Double($0) / Double(count) * 2 * Double.pi
        return Point(c.x + c.r * cos(a), c.y + c.r * sin(a))
      }
    }
    // The longest cyclic run of points that satisfy `keep`, in sampling order.
    func run(_ points: [Point], keep: (Point) -> Bool) -> [Point] {
      let flags = points.map(keep)
      guard let begin = flags.indices.first(where: { flags[$0] && !flags[($0 + count - 1) % count] })
      else { return [] }
      var result: [Point] = []
      var index = begin
      while flags[index % count], result.count < count {
        result.append(points[index % count])
        index += 1
      }
      return result
    }
    let cut = run(circle(outer)) { hypot($0.x - inner.x, $0.y - inner.y) >= inner.r }
    let hole = run(circle(inner)) { hypot($0.x - outer.x, $0.y - outer.y) < outer.r }
    guard let end = cut.last, let hs = hole.first, let he = hole.last else { return cut }
    return cut + (end.distance(to: hs) <= end.distance(to: he) ? hole : hole.reversed())
  }
}

extension ShapeSpec {
  // The shape for a tap (default size, centered) or a drag from `a` to `b` (corner to corner,
  // or end to end for lines and arrows).
  public static func dragged(_ kind: ShapeKind, from a: Point, to b: Point) -> ShapeSpec {
    let distance = a.distance(to: b)
    if distance < 10 {
      let size = kind.defaultSize
      return ShapeSpec(kind: kind, center: a, width: size.x, height: size.y)
    }
    let middle = Point((a.x + b.x) / 2, (a.y + b.y) / 2)
    if kind.isLinear {
      return ShapeSpec(
        kind: kind, center: middle, width: distance, height: 0,
        rotation: ShapeRecognizer.snapAngle(atan2(b.y - a.y, b.x - a.x)))
    }
    return ShapeSpec(
      kind: kind, center: middle, width: max(12, abs(b.x - a.x)), height: max(12, abs(b.y - a.y)))
  }
}
