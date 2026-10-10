import Foundation

public struct SpatialIndex: Sendable {
    private indirect enum Node: Sendable {
        case leaf(Rect, [Stroke])
        case branch(Rect, [Stroke], [Node])
        var bounds: Rect { switch self { case .leaf(let r, _), .branch(let r, _, _): r } }
        func query(_ area: Rect) -> [Stroke] {
            guard bounds.intersects(area) else { return [] }
            switch self {
            case .leaf(_, let strokes): return strokes.filter { $0.bounds.intersects(area) }
            case .branch(_, let strokes, let children): return strokes.filter { $0.bounds.intersects(area) } + children.flatMap { $0.query(area) }
            }
        }
    }
    private let root: Node
    public init(strokes: [Stroke], bounds: Rect) { root = Self.build(strokes, bounds, depth: 0) }
    private static func build(_ strokes: [Stroke], _ r: Rect, depth: Int) -> Node {
        guard strokes.count > 12, depth < 8 else { return .leaf(r, strokes) }
        let w = r.width / 2, h = r.height / 2
        let regions = [Rect(x: r.x, y: r.y, width: w, height: h), Rect(x: r.x + w, y: r.y, width: w, height: h), Rect(x: r.x, y: r.y + h, width: w, height: h), Rect(x: r.x + w, y: r.y + h, width: w, height: h)]
        var buckets = [[Stroke]](repeating: [], count: 4), shared: [Stroke] = []
        for stroke in strokes {
            let b = stroke.bounds
            if let i = regions.firstIndex(where: { $0.contains(Point(b.x, b.y)) && $0.contains(Point(b.x + b.width, b.y + b.height)) }) { buckets[i].append(stroke) } else { shared.append(stroke) }
        }
        return .branch(r, shared, regions.enumerated().map { build(buckets[$0.offset], $0.element, depth: depth + 1) })
    }
    public func query(_ area: Rect) -> [Stroke] { root.query(area) }
}
public enum Editing {
    public static func distance(_ point: Point, toSegmentFrom a: Point, to b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 0 else { return point.distance(to: a) }
        let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return point.distance(to: Point(a.x + t * dx, a.y + t * dy))
    }
    public static func segmentsIntersect(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        func cross(_ p: Point, _ q: Point, _ r: Point) -> Double { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        if abC * abD < 0 && cdA * cdB < 0 { return true }
        return (abs(abC) < 1e-9 && distance(c, toSegmentFrom: a, to: b) < 1e-9) ||
            (abs(abD) < 1e-9 && distance(d, toSegmentFrom: a, to: b) < 1e-9) ||
            (abs(cdA) < 1e-9 && distance(a, toSegmentFrom: c, to: d) < 1e-9) ||
            (abs(cdB) < 1e-9 && distance(b, toSegmentFrom: c, to: d) < 1e-9)
    }
    public static func strokeIntersects(_ stroke: Stroke, polygon: [Point]) -> Bool {
        guard polygon.count >= 3 else { return false }
        if stroke.samples.contains(where: { contains($0.point, polygon: polygon) }) { return true }
        let edges = zip(polygon, Array(polygon.dropFirst()) + [polygon[0]])
        return zip(stroke.samples, stroke.samples.dropFirst()).contains { a, b in
            edges.contains { segmentsIntersect(a.point, b.point, $0.0, $0.1) }
        }
    }
    public static func contains(_ point: Point, polygon: [Point]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false, j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
    public static func selection(strokes: [Stroke], polygon: [Point], bounds: Rect) -> Set<UUID> {
        guard let p = polygon.first else { return [] }
        let minX = polygon.map(\.x).min() ?? p.x, maxX = polygon.map(\.x).max() ?? p.x
        let minY = polygon.map(\.y).min() ?? p.y, maxY = polygon.map(\.y).max() ?? p.y
        return Set(SpatialIndex(strokes: strokes, bounds: bounds).query(Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)).filter { strokeIntersects($0, polygon: polygon) }.map(\.id))
    }
    public static func erase(strokes: [Stroke], at point: Point, radius: Double, mode: EraserMode, highlighterOnly: Bool) -> [Stroke] {
        strokes.flatMap { stroke -> [Stroke] in
            if highlighterOnly && stroke.tool != .highlighter { return [stroke] }
            let threshold = radius + stroke.width / 2
            let hit = stroke.samples.contains { $0.point.distance(to: point) <= threshold } || zip(stroke.samples, stroke.samples.dropFirst()).contains { distance(point, toSegmentFrom: $0.0.point, to: $0.1.point) <= threshold }
            guard hit else { return [stroke] }
            guard mode == .precision else { return [] }
            var segments: [[Sample]] = [[]]
            var dense: [Sample] = []
            for (a, b) in zip(stroke.samples, stroke.samples.dropFirst()) {
                let steps = min(4096, max(1, Int(ceil(a.point.distance(to: b.point) / max(1, radius / 2)))))
                for i in 0..<steps {
                    let t = Double(i) / Double(steps)
                    dense.append(Sample(point: Point(a.point.x + (b.point.x - a.point.x) * t, a.point.y + (b.point.y - a.point.y) * t), pressure: a.pressure + (b.pressure - a.pressure) * t, altitude: a.altitude + (b.altitude - a.altitude) * t))
                }
            }
            if let last = stroke.samples.last { dense.append(last) }
            for sample in dense {
                if sample.point.distance(to: point) <= radius + stroke.width / 2 { if !segments[segments.count - 1].isEmpty { segments.append([]) } }
                else { segments[segments.count - 1].append(sample) }
            }
            return segments.filter { !$0.isEmpty }.map { var copy = stroke; copy.id = UUID(); copy.samples = $0; return copy }
        }
    }
    public static func shape(from stroke: Stroke) -> Stroke {
        guard let first = stroke.samples.first, let last = stroke.samples.last, stroke.samples.count > 2 else { return stroke }
        var result = stroke
        if first.point.distance(to: last.point) > 25 { result.samples = [first, last]; return result }
        let b = stroke.bounds, center = Point(b.x + b.width / 2, b.y + b.height / 2)
        let corners = [Point(b.x, b.y), Point(b.x + b.width, b.y), Point(b.x + b.width, b.y + b.height), Point(b.x, b.y + b.height), Point(b.x, b.y)]
        let cornerHits = corners.prefix(4).filter { c in stroke.samples.contains { $0.point.distance(to: c) < max(b.width, b.height) * 0.15 } }.count
        result.samples = cornerHits >= 3 ? corners.map { Sample(point: $0) } : (0...64).map { i in let t = Double(i) / 64 * 2 * .pi; return Sample(point: Point(center.x + b.width / 2 * cos(t), center.y + b.height / 2 * sin(t))) }
        return result
    }
}
