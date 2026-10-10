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
        return Set(SpatialIndex(strokes: strokes, bounds: bounds).query(Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)).filter { $0.samples.contains { contains($0.point, polygon: polygon) } }.map(\.id))
    }
    public static func erase(strokes: [Stroke], at point: Point, radius: Double, mode: EraserMode, highlighterOnly: Bool) -> [Stroke] {
        strokes.flatMap { stroke -> [Stroke] in
            if highlighterOnly && stroke.tool != .highlighter { return [stroke] }
            guard stroke.samples.contains(where: { $0.point.distance(to: point) <= radius + stroke.width / 2 }) else { return [stroke] }
            guard mode == .precision else { return [] }
            var segments: [[Sample]] = [[]]
            for sample in stroke.samples {
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
